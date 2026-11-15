import XCTest
import CryptoKit
@testable import StarWave

private final class RotationKeyStore: ChatKeyStoring {
    var ring: ChatKeyRing?
    var failSave = false
    var failCompletion = false
    func load() throws -> ChatKeyRing? { ring }
    func save(_ ring: ChatKeyRing) throws {
        if failSave || (failCompletion && ring.pendingRotation == nil) {
            throw ChatFailure.invalid("Synthetic keyring save failure")
        }
        self.ring = ring
    }
}

private final class RotationProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest, RotationProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
            }
            handler(request, self)
        }
    }
    override func stopLoading() {}
    func respond(_ data: JSONValue) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(JSONValue.object(["ok": .bool(true), "data": data])))
        client?.urlProtocolDidFinishLoading(self)
    }
    func timeout() { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
    static func body(_ request: URLRequest) throws -> JSONValue {
        if let data = request.httpBody { return try JSONDecoder().decode(JSONValue.self, from: data) }
        guard let stream = request.httpBodyStream else { return .null }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

@MainActor
private struct RotationFixture {
    let directory: URL
    let session: SessionStore
    let vault: RotationKeyStore
    let chat: ChatController
    let c: ChatConnection
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-rotation-" + UUID().uuidString)
        session = SessionStore(keychainService: "chat-rotation-" + UUID().uuidString)
        session.save(AuthTokens(json: .chatObject(["access_token": "synthetic", "username": "alice"]))!)
        let keys = RotationKeyStore(); vault = keys
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RotationProtocol.self]
        chat = ChatController(sessionStore: session, mainAPI: APIClient(sessionStore: session, session: URLSession(configuration: config)),
                              defaults: UserDefaults(suiteName: UUID().uuidString)!, keyVaultFactory: { _ in keys },
                              transportFactory: { ChatTransport(relay: $0, configuration: config) })
        try chat.changeRelay("https://" + UUID().uuidString.lowercased() + ".test", profile: UserProfile(json: .object(["id": .number(1), "username": .string("alice")])))
        chat.setEnabled(true); chat.foreground = true
        var ring = try ChatKeyRing.create(); ring.revision = "1"; try keys.save(ring)
        let store = try ChatLocalStore(namespace: chat.namespace!, key: ring.storeKey, directory: directory)
        c = ChatConnection(ticket: chat.ticket, namespace: chat.namespace!, subject: "account:1", username: "alice", token: "synthetic-chat", expiresAt: Int64.max,
                           transport: ChatTransport(relay: try ChatValidation.relay(chat.relayText), configuration: config), store: store, ring: ring)
        chat.localStore = store; chat.connection = c; chat.connected = true
    }
    func clean() {
        chat.suspend(); session.clear(); RotationProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
    }
    func bundle(keys: [ChatPrivateKey], revision: String) -> JSONValue {
        .object(["subject": .string(c.subject), "keyset_revision": .string(revision), "devices": .array([
            .object(["device_id": .string(c.ring.deviceID), "key_revision": .string(revision), "keys": .array(keys.map { $0.published.json })])
        ])])
    }
    func reconcile() async throws -> ChatKeyRing {
        // Reconciliation also runs before a connection is installed during connect.
        try await chat.localOnlyWrite { _, valid in
            try await chat.reconcileDeviceKeys(ring: c.ring, transport: c.transport, token: c.token,
                                               username: c.username, namespace: c.namespace, valid: valid)
        }
    }
}

final class ChatKeyRotationTests: XCTestCase {
    func testOldKeyringDecodesWithoutRotationAndArchivesStayDecryptable() throws {
        var old = try ChatKeyRing.create(); old.revision = "7"
        let data = try JSONEncoder().encode(old)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "pendingRotation")
        let decoded = try JSONDecoder().decode(ChatKeyRing.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.pendingRotation)
        let staged = try decoded.stagingRotation()
        let durable = try JSONDecoder().decode(ChatKeyRing.self, from: JSONEncoder().encode(staged))
        XCTAssertEqual(durable.deviceID, old.deviceID); XCTAssertEqual(durable.storeKey, old.storeKey)
        XCTAssertEqual(durable.keys.map(\.keyID), old.keys.map(\.keyID))
        XCTAssertThrowsError(try durable.stagingRotation())
        XCTAssertThrowsError(try durable.completingRotation(revision: "9"))
        let completed = try durable.completingRotation(revision: "8")
        XCTAssertNil(completed.pendingRotation); XCTAssertEqual(completed.revision, "8")
        XCTAssertEqual(completed.deviceID, old.deviceID); XCTAssertEqual(completed.storeKey, old.storeKey)
        XCTAssertEqual(Set(completed.archiveKeys.map(\.keyID)), Set(old.keys.map(\.keyID)))
        XCTAssertTrue(Set(completed.keys.map(\.keyID)).isDisjoint(with: Set(old.keys.map(\.keyID))))
        let remote = try ChatCrypto.newKeys()
        for oldKey in old.keys {
            let sender = try XCTUnwrap(remote.first { $0.algorithm == oldKey.algorithm })
            let cipher = try ChatCrypto.encryptLegacy("Historical text", key: sender, remote: oldKey.publicKey)
            let archived = try completed.key(oldKey.keyID)
            XCTAssertEqual(try ChatCrypto.decryptLegacy(cipher, key: archived, remote: sender.publicKey), "Historical text")
        }
    }

    func testRestorePreservesPendingCandidateAndRejectsItsKeyIDCollision() throws {
        var ring = try ChatKeyRing.create(); ring.revision = "1"
        let staged = try ring.stagingRotation(), historical = try ChatCrypto.newKeys()
        let merged = try staged.mergingHistory(historical)
        XCTAssertEqual(merged.pendingRotation?.keys.map(\.keyID), staged.pendingRotation?.keys.map(\.keyID))
        let completed = try merged.completingRotation(revision: "2")
        XCTAssertEqual(Set(completed.archiveKeys.map(\.keyID)), Set((historical + ring.keys).map(\.keyID)))
        let pending = try XCTUnwrap(staged.pendingRotation?.keys.first)
        let other = try XCTUnwrap(historical.first { $0.algorithm == pending.algorithm })
        let collision = ChatPrivateKey(keyID: pending.keyID, algorithm: other.algorithm, privateData: other.privateData, publicKey: other.publicKey)
        XCTAssertThrowsError(try staged.mergingHistory([collision]))
    }

    func testLegacyPrimaryIsBlockedEvenWhenDisabled() throws {
        for enabled in [true, false] {
            XCTAssertThrowsError(try ChatKeyRing.requireRotationAllowed(.object(["device_id": .string("self"), "enabled": .bool(enabled)]), deviceID: "self"))
        }
        XCTAssertNoThrow(try ChatKeyRing.requireRotationAllowed(.object(["device_id": .null, "enabled": .bool(false)]), deviceID: "self"))
        XCTAssertThrowsError(try ChatKeyRing.requireRotationAllowed(.object([:]), deviceID: "self"))
        XCTAssertThrowsError(try ChatKeyRing.requireRotationAllowed(.object(["enabled": .bool(false)]), deviceID: "self"))
        XCTAssertThrowsError(try ChatKeyRing.requireRotationAllowed(.object(["enabled": .bool(true), "device_id": .null]), deviceID: "self"))
    }

    @MainActor func testSaveFailurePreventsPublication() async throws {
        let f = try RotationFixture(); defer { f.clean() }
        var posts = 0
        RotationProtocol.handler = { request, stub in
            if request.httpMethod == "POST" { posts += 1; XCTFail("Published before durable save") }
            stub.respond(.object(["device_id": .null, "enabled": .bool(false)]))
        }
        f.vault.failSave = true
        do { try await f.chat.rotateDeviceKeys(); XCTFail("Expected secure store failure") } catch {}
        XCTAssertEqual(posts, 0); XCTAssertNil(f.vault.ring?.pendingRotation)
        XCTAssertEqual(f.vault.ring?.keys.map(\.keyID), f.c.ring.keys.map(\.keyID))
    }

    @MainActor func testAmbiguousAcceptanceRecoversWithoutPublishingAnotherCandidate() async throws {
        let f = try RotationFixture(); defer { f.clean() }
        var posts = 0
        RotationProtocol.handler = { request, stub in
            if request.url!.path.hasSuffix("/legacy") { stub.respond(.object(["device_id": .null, "enabled": .bool(false)])) }
            else if request.httpMethod == "GET" {
                if posts > 0, let candidate = f.vault.ring?.pendingRotation {
                    stub.respond(f.bundle(keys: candidate.keys, revision: "2"))
                } else { stub.respond(f.bundle(keys: f.c.ring.keys, revision: "1")) }
            }
            else {
                posts += 1
                XCTAssertNotNil(f.vault.ring?.pendingRotation, "Candidate must be durable at publication")
                XCTAssertEqual(try? RotationProtocol.body(request).chatString("expected_revision"), "1")
                stub.timeout() // Server acceptance is deliberately ambiguous to the client.
            }
        }
        do { try await f.chat.rotateDeviceKeys(); XCTFail("Expected timeout") } catch {}
        let saved = try XCTUnwrap(f.vault.ring), candidate = try XCTUnwrap(saved.pendingRotation)
        XCTAssertEqual(posts, 1); XCTAssertNil(f.chat.connection)
        // A new transport models the next process/connection after acceptance.
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RotationProtocol.self]
        let transport = ChatTransport(relay: f.c.transport.relay, configuration: config)
        RotationProtocol.handler = { request, stub in
            XCTAssertEqual(request.httpMethod, "GET", "Accepted candidates must not be replaced or republished")
            stub.respond(f.bundle(keys: candidate.keys, revision: "2"))
        }
        let recovered = try await f.chat.localOnlyWrite { _, valid in
            try await f.chat.reconcileDeviceKeys(ring: saved, transport: transport, token: f.c.token,
                                                username: f.c.username, namespace: f.c.namespace, valid: valid)
        }
        XCTAssertNil(recovered.pendingRotation); XCTAssertEqual(recovered.revision, "2")
        XCTAssertEqual(recovered.keys.map(\.keyID), candidate.keys.map(\.keyID))
        XCTAssertEqual(Set(recovered.archiveKeys.map(\.keyID)), Set(f.c.ring.keys.map(\.keyID)))
    }

    @MainActor func testUnacceptedCandidateReplaysExactCASAndCompletionSaveCanRetry() async throws {
        let f = try RotationFixture(); defer { f.clean() }
        let staged = try f.c.ring.stagingRotation(); try f.vault.save(staged)
        let candidate = try XCTUnwrap(staged.pendingRotation)
        f.vault.failCompletion = true
        var posts = 0
        RotationProtocol.handler = { request, stub in
            if request.url!.path.hasSuffix("/legacy") { stub.respond(.object(["device_id": .null, "enabled": .bool(false)])) }
            else if request.httpMethod == "GET" {
                if posts > 0, let candidate = f.vault.ring?.pendingRotation {
                    stub.respond(f.bundle(keys: candidate.keys, revision: "2"))
                } else { stub.respond(f.bundle(keys: f.c.ring.keys, revision: "1")) }
            }
            else {
                posts += 1
                XCTAssertEqual(try? ChatCrypto.canonical(RotationProtocol.body(request)), try? ChatCrypto.canonical(candidate.request))
                stub.respond(.chatObject(["device_id": f.c.ring.deviceID, "key_revision": "2"]))
            }
        }
        do { _ = try await f.reconcile(); XCTFail("Expected completion save failure") } catch {}
        XCTAssertEqual(posts, 1); XCTAssertNotNil(f.vault.ring?.pendingRotation)
        f.vault.failCompletion = false
        RotationProtocol.handler = { request, stub in
            XCTAssertEqual(request.httpMethod, "GET")
            stub.respond(f.bundle(keys: candidate.keys, revision: "2"))
        }
        let recovered = try await f.reconcile()
        XCTAssertNil(recovered.pendingRotation); XCTAssertEqual(recovered.revision, "2")
    }

    @MainActor func testConcurrentRotationsPublishOnlyOneCandidate() async throws {
        let f = try RotationFixture(); defer { f.clean() }
        var posts = 0
        RotationProtocol.handler = { request, stub in
            if request.url!.path.hasSuffix("/legacy") { stub.respond(.object(["device_id": .null, "enabled": .bool(false)])) }
            else if request.httpMethod == "GET" {
                if posts > 0, let candidate = f.vault.ring?.pendingRotation {
                    stub.respond(f.bundle(keys: candidate.keys, revision: "2"))
                } else { stub.respond(f.bundle(keys: f.c.ring.keys, revision: "1")) }
            }
            else {
                posts += 1
                stub.respond(.chatObject(["device_id": f.c.ring.deviceID, "key_revision": "2"]))
            }
        }
        let first = Task { @MainActor in
            do { try await f.chat.rotateDeviceKeys(); return true } catch { return false }
        }
        let second = Task { @MainActor in
            do { try await f.chat.rotateDeviceKeys(); return true } catch { return false }
        }
        let firstSucceeded = await first.value, secondSucceeded = await second.value
        let successes = [firstSucceeded, secondSucceeded].filter { $0 }.count
        XCTAssertEqual(successes, 1); XCTAssertEqual(posts, 1)
        XCTAssertNil(f.vault.ring?.pendingRotation); XCTAssertEqual(f.vault.ring?.revision, "2")
        XCTAssertEqual(f.vault.ring?.archiveKeys.count, 2)
    }

    @MainActor func testLegacyPrimaryRotationDoesNotStageOrPublish() async throws {
        let f = try RotationFixture(); defer { f.clean() }
        RotationProtocol.handler = { request, stub in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(request.url!.path.hasSuffix("/legacy"))
            stub.respond(.object(["device_id": .string(f.c.ring.deviceID), "enabled": .bool(false)]))
        }
        do { try await f.chat.rotateDeviceKeys(); XCTFail("Expected legacy primary block") } catch {}
        XCTAssertNil(f.vault.ring?.pendingRotation); XCTAssertEqual(f.vault.ring?.revision, "1")
        XCTAssertNotNil(f.chat.connection)
    }

    @MainActor func testHistoricalCASSuccessMustConfirmCurrentPublishedKeys() async throws {
        let f = try RotationFixture(); defer { f.clean() }
        let staged = try f.c.ring.stagingRotation(); try f.vault.save(staged)
        let foreign = try ChatCrypto.newKeys()
        var reads = 0, posts = 0
        RotationProtocol.handler = { request, stub in
            if request.url!.path.hasSuffix("/legacy") {
                stub.respond(.object(["device_id": .null, "enabled": .bool(false)]))
            } else if request.httpMethod == "GET" {
                reads += 1
                stub.respond(reads == 1 ? f.bundle(keys: f.c.ring.keys, revision: "1") : f.bundle(keys: foreign, revision: "3"))
            } else {
                posts += 1
                // Backend idempotency can replay an earlier successful CAS
                // even after another holder has advanced the device again.
                stub.respond(.chatObject(["device_id": f.c.ring.deviceID, "key_revision": "2"]))
            }
        }
        do { _ = try await f.reconcile(); XCTFail("A historical result is not proof of current public keys") } catch {}
        XCTAssertEqual(posts, 1); XCTAssertEqual(reads, 2)
        XCTAssertEqual(f.vault.ring?.revision, "1")
        XCTAssertEqual(f.vault.ring?.pendingRotation?.keys.map(\.keyID), staged.pendingRotation?.keys.map(\.keyID))
    }

    @MainActor func testInitialRegistrationConfirmsPublicKeysBeforeSavingRevision() async throws {
        let f = try RotationFixture(); defer { f.clean() }
        var initial = f.c.ring; initial.revision = "0"; try f.vault.save(initial)
        var reads = 0, posts = 0
        RotationProtocol.handler = { request, stub in
            if request.httpMethod == "GET" {
                reads += 1
                if reads == 1 {
                    stub.respond(.object(["subject": .string(f.c.subject), "keyset_revision": .string("0"), "devices": .array([])]))
                } else { stub.respond(f.bundle(keys: initial.keys, revision: "1")) }
            } else {
                posts += 1
                XCTAssertEqual(try? RotationProtocol.body(request).chatString("expected_revision"), "0")
                stub.respond(.chatObject(["device_id": initial.deviceID, "key_revision": "1"]))
            }
        }
        let registered = try await f.reconcile()
        XCTAssertEqual(posts, 1); XCTAssertEqual(reads, 2)
        XCTAssertEqual(registered.revision, "1"); XCTAssertEqual(registered.keys.map(\.keyID), initial.keys.map(\.keyID))
    }

    @MainActor func testUnexpectedServerKeysDoNotDiscardDurableIntent() async throws {
        let f = try RotationFixture(); defer { f.clean() }
        let staged = try f.c.ring.stagingRotation(); try f.vault.save(staged)
        let foreign = try ChatCrypto.newKeys()
        RotationProtocol.handler = { request, stub in
            XCTAssertEqual(request.httpMethod, "GET")
            stub.respond(f.bundle(keys: foreign, revision: "2"))
        }
        do { _ = try await f.reconcile(); XCTFail("Expected key mismatch") } catch {}
        XCTAssertEqual(f.vault.ring?.pendingRotation?.keys.map(\.keyID), staged.pendingRotation?.keys.map(\.keyID))
        XCTAssertEqual(f.vault.ring?.keys.map(\.keyID), f.c.ring.keys.map(\.keyID))
    }
}
