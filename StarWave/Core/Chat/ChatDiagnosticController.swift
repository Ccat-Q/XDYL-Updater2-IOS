import Foundation

/// The transport emits this value only. Requests, payloads, credentials, error
/// descriptions and server-provided error codes cannot cross this boundary.
struct ChatDiagnosticHTTPEvent: Sendable {
    let route: ChatDiagnosticRoute
    let outcome: ChatDiagnosticOutcome
    let status: Int?
    let elapsedMilliseconds: Int
    let reason: ChatDiagnosticReason?
}

enum ChatDiagnosticSafety {
    static func reason(for error: Error) -> ChatDiagnosticReason {
        if error is CancellationError { return .cancelled }
        if let url = error as? URLError { return url.code == .cancelled ? .cancelled : .transportFailure }
        guard let failure = error as? ChatFailure else { return .unknown }
        switch failure {
        case .storage: return .storageFailure
        case .keyChanged: return .peerUntrusted
        case .invalid: return .invalidResponse
        case .service(let status, _, _):
            if status == 401 || status == 403 { return .unauthorized }
            return status == 429 ? .rateLimited : .remoteRejected
        }
    }
    static func elapsed(since start: Date) -> Int {
        let value = Date().timeIntervalSince(start) * 1000
        guard value.isFinite else { return 0 }
        return Int(min(1_000_000_000, max(0, value)))
    }
    static func stage(_ value: ChatCryptoStage) -> ChatDiagnosticStage {
        switch value {
        case .cipherFormat: return .cipherFormat
        case .keyAgreement: return .keyAgreement
        case .keyDerivation: return .keyDerivation
        case .authenticatedCipher: return .authenticatedCipher
        case .plaintextValidation: return .plaintextValidation
        }
    }
    static func outcome(_ value: ChatCryptoOutcome) -> ChatDiagnosticOutcome {
        switch value { case .started: return .started; case .succeeded: return .succeeded; case .failed: return .failed }
    }
    static func reason(_ value: ChatCryptoFailure) -> ChatDiagnosticReason {
        switch value {
        case .cipherFormatInvalid: return .cipherFormatInvalid
        case .peerKeyInvalid: return .peerKeyInvalid
        case .ownKeyInvalid: return .ownKeyInvalid
        case .keyAgreementFailed: return .keyAgreementFailed
        case .aeadAuthenticationFailed: return .aeadAuthenticationFailed
        case .plaintextInvalid: return .plaintextInvalid
        case .cryptoFailed: return .cryptoFailed
        }
    }
}

extension ChatController {
    /// Synchronous, read-only inspection. Do not call connect/localStorage here:
    /// both may create a keyring or change durable account state.
    func captureDiagnosticSnapshot() {
        var details: [ChatDiagnosticDetail] = [.state(!enabled ? .disabled : connected ? .connected : .disconnected), .hasSession(connection != nil)]
        if let relay = try? ChatValidation.relay(relayText) { details.append(.relay(relay)) }
        if enabled, sessionStore.isAuthenticated, subject != nil, let ns = namespace {
            do {
                if let ring = try keyVaultFactory(ns).load() {
                    let pairs = ring.keys.prefix(20).map { ChatCrypto.publicPairMatches($0) }
                    let pair: Bool? = pairs.contains(where: { $0 == false }) ? false : (!pairs.isEmpty && pairs.allSatisfy { $0 == true } ? true : nil)
                    details += [.deviceID(ring.deviceID), .revision(ring.revision), .activeKeyCount(ring.keys.count), .archivedKeyCount(ring.archiveKeys.count), .pendingRotation(ring.pendingRotation != nil), .pairMatches(pair)]
                    for key in ring.keys.prefix(20) {
                        diagnostics.record(.keyPairChecked, details: [.algorithm(.init(key.algorithm)), .ownKeyID(key.keyID), .ownPublicKey(key.publicKey), .pairMatches(ChatCrypto.publicPairMatches(key))])
                    }
                } else { details += [.activeKeyCount(0), .archivedKeyCount(0), .pendingRotation(false), .pairMatches(nil)] }
            } catch {
                diagnostics.record(.snapshot, outcome: .failed, reason: .storageFailure)
            }
        }
        diagnostics.updateSnapshot(details)
        diagnostics.record(.snapshot, details: details)
    }

    func diagnosticGeneration(for connection: ChatConnection) -> UUID {
        do { try current(connection); return diagnostics.generation }
        catch { return UUID() } // An invalid connection must never match the live scope.
    }

    func bindDiagnosticTransport(_ transport: ChatTransport) {
        let diagnostics = self.diagnostics, generation = diagnostics.generation
        transport.diagnosticHandler = { [weak diagnostics] value in
            Task { @MainActor [weak diagnostics] in
                guard let diagnostics else { return }
                var details: [ChatDiagnosticDetail] = [.route(value.route), .elapsedMilliseconds(value.elapsedMilliseconds)]
                if let status = value.status { details.append(.httpStatus(status)) }
                let event: ChatDiagnosticEvent = value.outcome == .started ? .requestStarted : value.outcome == .succeeded ? .requestCompleted : .requestFailed
                diagnostics.record(event, outcome: value.outcome, reason: value.reason, details: details, generation: generation)
            }
        }
    }

    func recordCryptoTrace(_ value: ChatCryptoTrace, outgoing: Bool, details: [ChatDiagnosticDetail], generation: UUID) {
        diagnostics.record(outgoing ? .encryptStage : .decryptStage, outcome: ChatDiagnosticSafety.outcome(value.outcome), reason: value.failure.map(ChatDiagnosticSafety.reason), details: details + [.stage(ChatDiagnosticSafety.stage(value.stage))], generation: generation)
    }

    func diagnosticEncrypt<T>(messageID: String, wireProtocol wire: ChatDiagnosticProtocol, key: ChatPrivateKey, remote: String,
                              _ operation: (@escaping (ChatCryptoTrace) -> Void) throws -> T) throws -> T {
        let generation = diagnostics.generation, start = Date()
        let pair = ChatCrypto.publicPairMatches(key)
        let details: [ChatDiagnosticDetail] = [.messageID(messageID), .wireProtocol(wire), .algorithm(.init(key.algorithm)), .direction(.outgoing), .ownKeyID(key.keyID), .ownPublicKey(key.publicKey), .peerPublicKey(remote), .pairMatches(pair)]
        diagnostics.record(.encryptStarted, outcome: .started, details: details, generation: generation)
        var failure: ChatDiagnosticReason?
        do {
            let result = try operation { [weak self] value in
                if value.outcome == .failed { failure = value.failure.map(ChatDiagnosticSafety.reason) ?? .cryptoFailed }
                self?.recordCryptoTrace(value, outgoing: true, details: details, generation: generation)
            }
            diagnostics.record(.encryptSucceeded, outcome: .succeeded, details: details + [.elapsedMilliseconds(ChatDiagnosticSafety.elapsed(since: start))], generation: generation)
            return result
        } catch {
            diagnostics.record(.encryptFailed, outcome: .failed, reason: failure ?? (pair == false ? .ownKeyPairMismatch : .cryptoFailed), details: details + [.elapsedMilliseconds(ChatDiagnosticSafety.elapsed(since: start))], generation: generation)
            throw error
        }
    }
}
