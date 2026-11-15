import XCTest
import CryptoKit
@testable import StarWave

private final class DiagnosticTestVault: ChatKeyStoring {
    var ring: ChatKeyRing?
    var loads = 0
    var saves = 0
    var shouldFail = false
    func load() throws -> ChatKeyRing? { loads += 1; if shouldFail { throw ChatFailure.invalid("RAW_VAULT_ERROR_SENTINEL") }; return ring }
    func save(_ ring: ChatKeyRing) throws { saves += 1; self.ring = ring }
}
private final class DiagnosticNetworkCount { var transports = 0; var requests = 0 }
private func diagnosticConfiguration() -> URLSessionConfiguration {
    let value = URLSessionConfiguration.ephemeral
    value.protocolClasses = [DiagnosticTestProtocol.self]
    return value
}
private final class DiagnosticTestProtocol: URLProtocol {
    @MainActor static var handler: (@MainActor (URLRequest, DiagnosticTestProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            guard let handler = Self.handler else { self.client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
            handler(self.request, self)
        }
    }
    override func stopLoading() {}
    func respond(_ data: JSONValue = .object([:]), status: Int = 200, errorCode: String = "SYNTHETIC_ERROR") {
        let value: JSONValue = status == 200 ? .object(["ok": .bool(true), "data": data]) : .object(["ok": .bool(false), "error": .chatObject(["code": errorCode])])
        let bytes = try! JSONEncoder().encode(value)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
}
@MainActor
private struct DiagnosticFixture {
    let directory: URL
    let suite: UserDefaults
    let suiteName: String
    let session: SessionStore
    let vault: DiagnosticTestVault
    let network: DiagnosticNetworkCount
    let chat: ChatController
    let c: ChatConnection
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-test-" + UUID().uuidString, isDirectory: true)
        suiteName = "diagnostic-test-" + UUID().uuidString
        suite = UserDefaults(suiteName: suiteName)!
        session = SessionStore(keychainService: suiteName)
        session.save(AuthTokens(json: .chatObject(["access_token": "SYNTHETIC_DIAGNOSTIC_MAIN_TOKEN", "username": "alice"]))!)
        let keys = DiagnosticTestVault(), count = DiagnosticNetworkCount()
        vault = keys; network = count
        let api = APIClient(sessionStore: session, session: URLSession(configuration: diagnosticConfiguration()))
        chat = ChatController(sessionStore: session, mainAPI: api, defaults: suite, keyVaultFactory: { _ in keys }, transportFactory: { url in
            count.transports += 1
            return ChatTransport(relay: url, configuration: diagnosticConfiguration())
        })
        try chat.changeRelay("https://" + UUID().uuidString.lowercased() + ".test", profile: UserProfile(json: .object(["id": .number(1), "username": .string("alice")])))
        chat.setEnabled(true); chat.foreground = true
        var ring = try ChatKeyRing.create(); ring.revision = "1"; try keys.save(ring)
        let store = try ChatLocalStore(namespace: chat.namespace!, key: ring.storeKey, directory: directory)
        let transport = ChatTransport(relay: try ChatValidation.relay(chat.relayText), configuration: diagnosticConfiguration())
        c = ChatConnection(ticket: chat.ticket, namespace: chat.namespace!, subject: "account:1", username: "alice", token: "SYNTHETIC_DIAGNOSTIC_CHAT_TOKEN", expiresAt: Int64.max, transport: transport, store: store, ring: ring)
        chat.connection = c; chat.localStore = store; chat.connected = true; chat.currentDeviceID = ring.deviceID
        chat.features = ["legacy_android_interop"]
        chat.bindDiagnosticTransport(transport)
        chat.diagnostics.clear()
    }
    func clean() {
        chat.suspend(); c.transport.cancel(); session.clear(); DiagnosticTestProtocol.handler = nil
        suite.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
    func peer(_ key: ChatPrivateKey, legacy: Bool = true) {
        var peer = ChatPeer(subject: "account:2", username: "bob")
        peer.trustVersion = 1; peer.fingerprint = "SYNTHETIC_PINNED_FINGERPRINT"
        peer.trustedKeys = [(legacy ? ChatCrypto.legacyID(key.algorithm, key.publicKey) : key.keyID): key.publicKey]
        chat.peers = [peer]
    }
    func legacyEvent(sender: ChatPrivateKey, plaintext: String = "RAW_PLAINTEXT_SENTINEL") throws -> JSONValue {
        let key = try XCTUnwrap(c.ring.keys.first { $0.algorithm == sender.algorithm })
        let cipher = try ChatCrypto.encryptLegacy(plaintext, key: sender, remote: key.publicKey)
        return .object(["type": .string("message"), "event_seq": .string("1"), "message_id": .string(UUID().uuidString.lowercased()), "client_msg_id": .string(UUID().uuidString.lowercased()), "conversation_id": .string(UUID().uuidString.lowercased()), "conversation_seq": .string("1"), "sender_subject": .string("account:2"), "sender_device_id": .string("legacy:bob"), "recipient_subject": .string(c.subject), "accepted_at_ms": .number(1), "raw_history_secret": .string("RAW_HISTORY_SENTINEL"), "envelope": .object(["protocol": .string("nu-chat-v1"), "algorithm": .string(key.algorithm), "own_key_id": .string(key.keyID), "sender_public_key": .string(sender.publicKey), "recipient_public_key": .string(key.publicKey), "cipher": .string(cipher)])])
    }
    func ownSenderEvent(untrustedSender: ChatPrivateKey) throws -> JSONValue {
        let own = try XCTUnwrap(c.ring.keys.first { $0.algorithm == untrustedSender.algorithm })
        let client = UUID().uuidString.lowercased()
        let metadata = JSONValue.chatObject(["sender_subject": c.subject, "sender_device_id": c.ring.deviceID,
            "recipient_subject": "account:2", "client_msg_id": client, "target_subject": c.subject,
            "target_device_id": c.ring.deviceID, "algorithm": own.algorithm,
            "sender_key_id": untrustedSender.keyID, "recipient_key_id": own.keyID])
        let cipher = try ChatCrypto.encrypt("RAW_OWN_SENDER_SENTINEL", key: untrustedSender, remote: own.publicKey, metadata: metadata)
        var envelope = metadata.objectValue
        envelope["sender_public_key"] = .string(untrustedSender.publicKey)
        envelope["nonce"] = .string(cipher.0); envelope["ciphertext"] = .string(cipher.1)
        return .object(["type": .string("message"), "event_seq": .string("1"), "message_id": .string(UUID().uuidString.lowercased()),
            "client_msg_id": .string(client), "conversation_id": .string(UUID().uuidString.lowercased()), "conversation_seq": .string("1"),
            "sender_subject": .string(c.subject), "sender_device_id": .string(c.ring.deviceID), "recipient_subject": .string("account:2"),
            "accepted_at_ms": .number(1), "envelope": .object(envelope)])
    }
    func mutateEnvelope(_ event: JSONValue, _ operation: (inout [String: JSONValue]) -> Void) -> JSONValue {
        var value = event.objectValue, envelope = event["envelope"]!.objectValue
        operation(&envelope); value["envelope"] = .object(envelope); return .object(value)
    }
    func bundle() -> JSONValue {
        .object(["subject": .string(c.subject), "keyset_revision": .string("1"), "devices": .array([.object(["device_id": .string(c.ring.deviceID), "key_revision": .string("1"), "keys": .array(c.ring.keys.map { $0.published.json })])])])
    }
}

final class ChatDiagnosticIntegrationTests: XCTestCase {
    @MainActor private func drainCallbacks() async {
        for _ in 0..<20 { await Task.yield() }
    }
    @MainActor func testSnapshotIsSynchronousWithoutNetworkKeyCreationOrStoreMutation() throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        f.chat.connection = nil; f.chat.localStore = nil; f.vault.ring = nil
        let saves = f.vault.saves, loads = f.vault.loads
        f.chat.captureDiagnosticSnapshot()
        XCTAssertEqual(f.vault.saves, saves)
        XCTAssertEqual(f.vault.loads, loads + 1)
        XCTAssertNil(f.vault.ring); XCTAssertNil(f.chat.localStore); XCTAssertNil(f.chat.connection)
        XCTAssertEqual(f.network.transports, 0)
        XCTAssertFalse(f.chat.diagnostics.snapshot.isEmpty)
    }
    @MainActor func testSnapshotPublishesOnlyHashesPairStatusAndFixedCounts() throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        f.vault.ring?.revision = "RAW_REVISION_SECRET=https://example.invalid"
        f.chat.captureDiagnosticSnapshot()
        let text = f.chat.diagnostics.exportText()
        XCTAssertFalse(text.contains("RAW_REVISION_SECRET"))
        XCTAssertFalse(text.contains(f.c.ring.deviceID))
        XCTAssertFalse(text.contains(f.chat.relayText))
        for key in f.c.ring.keys {
            XCTAssertFalse(text.contains(key.keyID)); XCTAssertFalse(text.contains(key.publicKey))
            XCTAssertFalse(text.contains(key.privateData.base64EncodedString()))
        }
        XCTAssertTrue(f.chat.diagnostics.entries.contains { $0.event == .keyPairChecked && $0.fields.contains { $0.label == "本机公私钥配对" && $0.value == "是" } })
    }
    @MainActor func testSnapshotVaultErrorNeverExportsArbitraryErrorText() throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        f.vault.shouldFail = true
        f.chat.captureDiagnosticSnapshot()
        XCTAssertTrue(f.chat.diagnostics.entries.contains { $0.reason == .storageFailure })
        XCTAssertFalse(f.chat.diagnostics.exportText().contains("RAW_VAULT_ERROR_SENTINEL"))
    }
    @MainActor func testIdentityChangeClearsAndRejectsAlreadyQueuedHTTPCallback() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let callback = try XCTUnwrap(f.c.transport.diagnosticHandler)
        f.chat.captureDiagnosticSnapshot()
        callback(.init(route: .messages, outcome: .failed, status: 503, elapsedMilliseconds: 7, reason: .remoteRejected))
        f.chat.identify(UserProfile(json: .object(["id": .number(2), "username": .string("bob")])))
        await drainCallbacks()
        XCTAssertTrue(f.chat.diagnostics.entries.isEmpty)
        XCTAssertTrue(f.chat.diagnostics.snapshot.isEmpty)
    }
    @MainActor func testLateDecodeFromOldConnectionCannotEnterNewAccountDiagnostics() throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let remote = try XCTUnwrap(ChatCrypto.newKeys().first { $0.algorithm == "P256" })
        let event = try f.legacyEvent(sender: remote)
        f.chat.identify(UserProfile(json: .object(["id": .number(2), "username": .string("bob")])))
        _ = try f.chat.decodeMessage(event, c: f.c)
        XCTAssertTrue(f.chat.diagnostics.entries.isEmpty)
        XCTAssertFalse(f.chat.diagnostics.exportText().contains("RAW_HISTORY_SENTINEL"))
    }

    @MainActor func testStaleSyncCannotEnterNewAccountDiagnostics() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        f.chat.identify(UserProfile(json: .object(["id": .number(2), "username": .string("bob")])))
        do { try await f.chat.sync(f.c); XCTFail("Expected stale connection rejection") } catch {}
        XCTAssertNil(f.chat.syncTask)
        XCTAssertTrue(f.chat.diagnostics.entries.isEmpty)
    }

    @MainActor func testRelayChangeClearsAndRejectsLateHTTPCallback() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let callback = try XCTUnwrap(f.c.transport.diagnosticHandler)
        f.chat.captureDiagnosticSnapshot()
        try f.chat.changeRelay("https://different.test", profile: nil)
        callback(.init(route: .session, outcome: .failed, status: 401, elapsedMilliseconds: 1, reason: .unauthorized))
        await drainCallbacks()
        XCTAssertTrue(f.chat.diagnostics.entries.isEmpty); XCTAssertTrue(f.chat.diagnostics.snapshot.isEmpty)
    }
    @MainActor func testDisableClearsDiagnosticsAndRejectsLateHTTPCallback() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let callback = try XCTUnwrap(f.c.transport.diagnosticHandler)
        f.chat.captureDiagnosticSnapshot(); f.chat.setEnabled(false)
        callback(.init(route: .keys, outcome: .succeeded, status: 200, elapsedMilliseconds: 5, reason: nil))
        await drainCallbacks()
        XCTAssertTrue(f.chat.diagnostics.entries.isEmpty); XCTAssertTrue(f.chat.diagnostics.snapshot.isEmpty)
    }
    @MainActor func testSuspendPreservesRecordsButInvalidatesTransportCallback() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        f.chat.diagnostics.record(.connected)
        let callback = try XCTUnwrap(f.c.transport.diagnosticHandler)
        f.chat.suspend()
        let count = f.chat.diagnostics.entries.count
        callback(.init(route: .sync, outcome: .succeeded, status: 200, elapsedMilliseconds: 5, reason: nil))
        await drainCallbacks()
        XCTAssertEqual(f.chat.diagnostics.entries.count, count)
        XCTAssertTrue(f.chat.diagnostics.entries.contains { $0.event == .connected })
    }
    @MainActor func testTransportHandlerDoesNotRetainControllerOrDiagnostics() throws {
        let suiteName = "diagnostic-retain-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        let session = SessionStore(keychainService: suiteName)
        defer { session.clear(); defaults.removePersistentDomain(forName: suiteName) }
        let api = APIClient(sessionStore: session, session: URLSession(configuration: diagnosticConfiguration()))
        let transport = ChatTransport(relay: URL(string: "https://retain-test.invalid")!, configuration: diagnosticConfiguration())
        defer { transport.cancel() }
        var controller: ChatController? = ChatController(sessionStore: session, mainAPI: api, defaults: defaults)
        weak var weakController = controller
        weak var weakDiagnostics = controller?.diagnostics
        controller?.bindDiagnosticTransport(transport)
        controller = nil
        XCTAssertNil(weakController); XCTAssertNil(weakDiagnostics)
    }

    @MainActor func testForgedOwnSenderIsNotTrustOnFirstUseOrAEADFailure() throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let remote = try XCTUnwrap(ChatCrypto.newKeys().first { $0.algorithm == "P256" })
        let message = try f.chat.decodeMessage(f.ownSenderEvent(untrustedSender: remote), c: f.c)
        XCTAssertNil(message.text)
        XCTAssertTrue(message.problem?.contains("OWN_SENDER_UNVERIFIED") == true)
        XCTAssertEqual(f.chat.diagnostics.entries.last?.reason, .ownSenderUnverified)
        XCTAssertFalse(f.chat.diagnostics.entries.contains { $0.reason == .aeadAuthenticationFailed })
        XCTAssertFalse(f.chat.diagnostics.exportText().contains("RAW_OWN_SENDER_SENTINEL"))
    }

    @MainActor func testPausingDiagnosticsDoesNotChangeConnectionOrCryptoResult() throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let remote = try XCTUnwrap(ChatCrypto.newKeys().first { $0.algorithm == "P256" })
        f.peer(remote); let event = try f.legacyEvent(sender: remote)
        f.chat.diagnostics.isRecording = false
        let message = try f.chat.decodeMessage(event, c: f.c)
        XCTAssertEqual(message.text, "RAW_PLAINTEXT_SENTINEL")
        XCTAssertTrue(f.chat.diagnostics.entries.isEmpty)
        XCTAssertTrue(f.chat.connection?.transport === f.c.transport)
    }
    @MainActor func testUntrustedPeerIsNotReportedAsGCMFailure() throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let remote = try XCTUnwrap(ChatCrypto.newKeys().first { $0.algorithm == "P256" })
        let message = try f.chat.decodeMessage(f.legacyEvent(sender: remote), c: f.c)
        XCTAssertTrue(message.problem?.contains("PEER_UNTRUSTED") == true)
        XCTAssertEqual(f.chat.diagnostics.entries.last?.reason, .peerUntrusted)
        XCTAssertFalse(f.chat.diagnostics.entries.contains { $0.reason == .aeadAuthenticationFailed })
    }
    @MainActor func testMissingOwnKeyHasDistinctSafeReasonAndHashedReference() throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let remote = try XCTUnwrap(ChatCrypto.newKeys().first { $0.algorithm == "P256" })
        f.peer(remote)
        let event = f.mutateEnvelope(try f.legacyEvent(sender: remote)) { $0["own_key_id"] = .string("RAW_MISSING_KEY_SECRET") }
        let message = try f.chat.decodeMessage(event, c: f.c)
        XCTAssertTrue(message.problem?.contains("OWN_KEY_MISSING") == true)
        XCTAssertEqual(f.chat.diagnostics.entries.last?.reason, .ownKeyMissing)
        XCTAssertFalse(f.chat.diagnostics.exportText().contains("RAW_MISSING_KEY_SECRET"))
    }
    @MainActor func testCipherFormatFailureIsNotReportedAsAEADFailure() throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let remote = try XCTUnwrap(ChatCrypto.newKeys().first { $0.algorithm == "P256" }); f.peer(remote)
        let event = f.mutateEnvelope(try f.legacyEvent(sender: remote)) { $0["cipher"] = .string("RAW_INVALID_CIPHER_SENTINEL") }
        let message = try f.chat.decodeMessage(event, c: f.c)
        XCTAssertTrue(message.problem?.contains("CIPHER_FORMAT_INVALID") == true)
        XCTAssertEqual(f.chat.diagnostics.entries.last?.reason, .cipherFormatInvalid)
        XCTAssertFalse(f.chat.diagnostics.entries.contains { $0.reason == .aeadAuthenticationFailed })
        XCTAssertFalse(f.chat.diagnostics.exportText().contains("RAW_INVALID_CIPHER_SENTINEL"))
    }
    @MainActor func testActualGCMAuthenticationFailureIsTracedWithoutRawHistory() throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let remote = try XCTUnwrap(ChatCrypto.newKeys().first { $0.algorithm == "P256" }); f.peer(remote)
        let event = f.mutateEnvelope(try f.legacyEvent(sender: remote)) { envelope in
            let parts = envelope["cipher"]!.stringValue!.split(separator: ":")
            var sealed = Data(base64Encoded: String(parts[1]))!; sealed[sealed.count - 1] ^= 1
            envelope["cipher"] = .string(String(parts[0]) + ":" + sealed.base64EncodedString())
        }
        let message = try f.chat.decodeMessage(event, c: f.c)
        XCTAssertTrue(message.problem?.contains("AEAD_AUTH_FAILED") == true)
        XCTAssertEqual(f.chat.diagnostics.entries.last?.reason, .aeadAuthenticationFailed)
        XCTAssertTrue(f.chat.diagnostics.entries.contains { $0.event == .decryptStage && $0.reason == .aeadAuthenticationFailed && $0.fields.contains { $0.value == ChatDiagnosticStage.authenticatedCipher.rawValue } })
        let text = f.chat.diagnostics.exportText()
        for raw in ["RAW_PLAINTEXT_SENTINEL", "RAW_HISTORY_SENTINEL", event["envelope"]!["cipher"]!.stringValue!, remote.publicKey, remote.privateData.base64EncodedString()] { XCTAssertFalse(text.contains(raw)) }
    }
    @MainActor func testTargetPublicKeyMismatchStopsBeforeCrypto() throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let remote = try XCTUnwrap(ChatCrypto.newKeys().first { $0.algorithm == "P256" }); f.peer(remote)
        let event = f.mutateEnvelope(try f.legacyEvent(sender: remote)) { $0["recipient_public_key"] = .string(remote.publicKey) }
        let message = try f.chat.decodeMessage(event, c: f.c)
        XCTAssertTrue(message.problem?.contains("TARGET_MISMATCH") == true)
        XCTAssertFalse(f.chat.diagnostics.entries.contains { $0.reason == .aeadAuthenticationFailed })
    }
    @MainActor func testLegacyWireP256TargetingX25519HasExplicitAlgorithmMismatch() throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let remote = try XCTUnwrap(ChatCrypto.newKeys().first { $0.algorithm == "P256" }); f.peer(remote)
        let wrongTarget = try XCTUnwrap(f.c.ring.keys.first { $0.algorithm == "X25519" })
        let event = f.mutateEnvelope(try f.legacyEvent(sender: remote)) {
            $0["own_key_id"] = .string(wrongTarget.keyID)
            $0["recipient_public_key"] = .string(wrongTarget.publicKey)
            $0["algorithm"] = .string("P256")
        }
        let message = try f.chat.decodeMessage(event, c: f.c)
        XCTAssertTrue(message.problem?.contains("ALGORITHM_MISMATCH") == true)
        let failure = try XCTUnwrap(f.chat.diagnostics.entries.last)
        XCTAssertEqual(failure.reason, .algorithmMismatch)
        XCTAssertTrue(failure.fields.contains { $0.label == "信封算法" && $0.value == "P256" })
        XCTAssertTrue(failure.fields.contains { $0.label == "本机算法" && $0.value == "X25519" })
        XCTAssertFalse(f.chat.diagnostics.entries.contains { $0.reason == .aeadAuthenticationFailed })
        XCTAssertFalse(f.chat.diagnostics.entries.contains { $0.event == .decryptStage && $0.fields.contains { $0.value == ChatDiagnosticStage.authenticatedCipher.rawValue } })
    }

    @MainActor func testMissingEnvelopeRetainsProblemCardWithSchemaCode() throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let remote = try XCTUnwrap(ChatCrypto.newKeys().first { $0.algorithm == "P256" })
        var event = try f.legacyEvent(sender: remote).objectValue; event["envelope"] = nil
        let message = try f.chat.decodeMessage(.object(event), c: f.c)
        XCTAssertNil(message.text)
        XCTAssertTrue(message.problem?.contains("SCHEMA_UNSUPPORTED") == true)
    }
    @MainActor func testHTTPServerCodeAndMaliciousPathNeverReachDiagnostics() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let sentinel = "RAW_SERVER_CODE_AND_PATH_SENTINEL"
        DiagnosticTestProtocol.handler = { _, stub in stub.respond(status: 503, errorCode: sentinel) }
        do { _ = try await f.c.transport.json("/chat/v2/users/" + sentinel + "/keys", token: f.c.token); XCTFail("Expected rejection") } catch {}
        await drainCallbacks()
        XCTAssertTrue(f.chat.diagnostics.entries.contains { $0.event == .requestFailed && $0.reason == .remoteRejected })
        XCTAssertFalse(f.chat.diagnostics.exportText().contains(sentinel))
        XCTAssertFalse(f.chat.diagnostics.exportText().contains(f.c.token))
    }
    @MainActor func testConnectionRecordsAllVerifiedPhasesAndFixedTimingFields() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        f.chat.connection = nil
        DiagnosticTestProtocol.handler = { request, stub in
            let path = request.url!.path
            if path.hasSuffix("/user/profile") { stub.respond(.object(["id": .number(1), "username": .string("alice")])) }
            else if path == "/chat/v2/capabilities" { stub.respond(.object(["protocol": .string("nu-chat-v2"), "version": .number(2), "features": .array(["cursor_sync", "idempotent_send", "device_keys", "conversations"].map(JSONValue.string))])) }
            else if path == "/chat/v2/session" { stub.respond(.chatObject(["subject": f.c.subject, "username": "alice", "chat_token": "SYNTHETIC_RENEWED_CHAT_TOKEN", "expires_at_ms": "9999999999999"])) }
            else if path == "/chat/v2/users/alice/keys" { stub.respond(f.bundle()) }
            else { XCTFail("Unexpected synthetic route"); stub.respond(status: 503) }
        }
        _ = try await f.chat.connect(); await drainCallbacks()
        let events = Set(f.chat.diagnostics.entries.map { $0.event.rawValue })
        for event in [ChatDiagnosticEvent.connectStarted, .capabilitiesVerified, .identityVerified, .sessionExchanged, .deviceKeysVerified, .connected] { XCTAssertTrue(events.contains(event.rawValue), event.rawValue) }
        XCTAssertFalse(f.chat.diagnostics.exportText().contains("SYNTHETIC_RENEWED_CHAT_TOKEN"))
    }
    @MainActor func testSyncCommitAndAckHaveSeparateSafeStages() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        DiagnosticTestProtocol.handler = { request, stub in
            switch request.url!.path {
            case "/chat/v2/sync": stub.respond(.object(["events": .array([]), "next_cursor": .string("RAW_CURSOR_SECRET"), "has_more": .bool(false)]))
            case "/chat/v2/sync/ack": stub.respond()
            case "/chat/v2/conversations": stub.respond(.object(["conversations": .array([]), "unread_total": .number(0), "has_more": .bool(false)]))
            default: XCTFail("Unexpected synthetic route"); stub.respond(status: 503)
            }
        }
        try await f.chat.sync(f.c); await drainCallbacks()
        XCTAssertTrue(f.chat.diagnostics.entries.contains { $0.event == .syncCommitted })
        XCTAssertTrue(f.chat.diagnostics.entries.contains { $0.event == .syncAcknowledged })
        XCTAssertFalse(f.chat.diagnostics.exportText().contains("RAW_CURSOR_SECRET"))
    }
    @MainActor func testRealLegacySendConnectsEncryptionTraceAndNeverExportsPendingBody() async throws {
        let f = try DiagnosticFixture(); defer { f.clean() }
        let remote = try XCTUnwrap(ChatCrypto.newKeys().first { $0.algorithm == "P256" })
        DiagnosticTestProtocol.handler = { request, stub in
            switch request.url!.path {
            case "/chat/v2/users/bob/protocols": stub.respond(.object(["subject": .string("account:2"), "username": .string("bob"), "protocols": .array([.string("nu-chat-v1")]), "legacy_public_keys": .array([.chatObject(["algorithm": "P256", "public_key": remote.publicKey])])]))
            case "/chat/v2/devices/" + f.c.ring.deviceID + "/legacy": stub.respond(.object(["enabled": .bool(true), "device_id": .string(f.c.ring.deviceID)]))
            case "/chat/v2/legacy/messages": stub.respond(.chatObject(["seq": "1"]))
            case "/chat/v2/sync": stub.respond(.object(["events": .array([]), "next_cursor": .string("safe-cursor"), "has_more": .bool(false)]))
            case "/chat/v2/sync/ack": stub.respond()
            case "/chat/v2/conversations": stub.respond(.object(["conversations": .array([]), "unread_total": .number(0), "has_more": .bool(false)]))
            default: XCTFail("Unexpected synthetic route"); stub.respond(status: 503)
            }
        }
        let inspected = try await f.chat.inspectPeer("bob")
        XCTAssertTrue(inspected.legacy["P256"] == remote.publicKey)
        XCTAssertTrue(inspected.publicKeys[ChatCrypto.legacyID("P256", remote.publicKey)] == remote.publicKey)
        XCTAssertNil(inspected.native)
        try await f.chat.trust(inspected, mode: .legacy)
        let peer = try XCTUnwrap(f.chat.peers.first)
        f.chat.diagnostics.clear()
        try await f.chat.send("RAW_SEND_PLAINTEXT_SENTINEL", to: peer)
        XCTAssertTrue(f.chat.diagnostics.entries.contains { $0.event == .encryptSucceeded })
        XCTAssertTrue(f.chat.diagnostics.entries.contains { $0.event == .encryptStage && $0.fields.contains { $0.value == ChatDiagnosticStage.keyDerivation.rawValue } })
        let pending = try XCTUnwrap(f.chat.pending.first)
        let cipher = try pending.body.chatString("cipher")
        let text = f.chat.diagnostics.exportText()
        XCTAssertFalse(text.contains("RAW_SEND_PLAINTEXT_SENTINEL")); XCTAssertFalse(text.contains(cipher))
    }
}
