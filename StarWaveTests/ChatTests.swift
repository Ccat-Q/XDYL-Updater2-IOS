import XCTest
import CryptoKit
@testable import StarWave

final class ChatTests: XCTestCase {
    func testRelayValidationAndStableNamespaces() throws {
        for value in ["http://chat.example", "https://user:secret@chat.example", "https://chat.example/path", "https://chat.example?token=x", "https://chat.example:8443", "https://chat.example/#fragment"] {
            XCTAssertThrowsError(try ChatValidation.relay(value))
        }
        let relay = try ChatValidation.relay("https://chat.example")
        XCTAssertNotEqual(ChatCrypto.namespace(relay: relay, subject: "account:1"), ChatCrypto.namespace(relay: relay, subject: "account:2"))
        let other = try ChatValidation.relay("https://other.example")
        XCTAssertNotEqual(ChatCrypto.namespace(relay: relay, subject: "account:1"), ChatCrypto.namespace(relay: other, subject: "account:1"))
        XCTAssertThrowsError(try ChatValidation.username("../admin"))
        XCTAssertThrowsError(try ChatValidation.plaintext(String(repeating: "🌊", count: 4097)))
        XCTAssertNil(UserProfile(json: .object(["nickname": .string("42")])).stableID)
        XCTAssertEqual(UserProfile(json: .object(["id": .number(42), "username": .string("cat")])).stableID, "42")
    }
    func testFixedX25519VectorMatchesWorkerAndAndroid() throws {
        let aPrivate = Data(base64Encoded: "MC4CAQAwBQYDK2VuBCIEIPDMshTULxp2zagA/AsmE8EPY/mvpyhlryhCxAM9o0tQ")!.suffix(32)
        let bPrivate = Data(base64Encoded: "MC4CAQAwBQYDK2VuBCIEIMjhX+TZ4V3ejlQkwY2kDPYo76pjz522EbKxi3jwhBtD")!.suffix(32)
        try vector(algorithm: "X25519", a: Data(aPrivate), b: Data(bPrivate), aSPKI: "MCowBQYDK2VuAyEAxfLEXWe7Yo1l2M2NilqS23jQKh/ckd+WKXCORQ6R+hw=", bSPKI: "MCowBQYDK2VuAyEA0GCm+deP+CAPTKrdixaLWGiA8wmxwx/BWEGlxuqf6yE=", v2: "PeSxLgdJFoNkakVlkJHPTyaR64KdJSLeVhKNlexGLOEDruJdNQ2924ZcXA==", v1: "AAECAwQFBgcICQoL:+pwcLZcFFgAdp5uBa0Ic1mKnEfIeOxbPQQZRIt3D3K/UeCdIzZlngzJGUg==")
    }
    func testFixedP256VectorMatchesWorkerAndAndroid() throws {
        let aDER = Data(base64Encoded: "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgfofrptw1iXoupfNOEfyyhwInKhEzTJkJ1jGCFni/+HihRANCAASRfW3NdWaoH+dgS/W1h9eaPSahBobb0O8A3MwMY2lhNvozFQFtZnx995idUOi4RWnbMy9LrPuCmvovn5amF3eh")!
        let bDER = Data(base64Encoded: "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgI4mww9Vf1y2Mgyzo1tPFl9t2Lbm4WDXnVOkoH1JpTSuhRANCAATRCFNTo6mTmLeWsavi8SRPP8aTRkc3kbBiN4E87ozdGxcpniaBz6OfgImyLILu0yjxiAfZhFugQiWAJUdNp0dm")!
        try vector(algorithm: "P256", a: P256.KeyAgreement.PrivateKey(derRepresentation: aDER).rawRepresentation, b: P256.KeyAgreement.PrivateKey(derRepresentation: bDER).rawRepresentation,
                   aSPKI: "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEkX1tzXVmqB/nYEv1tYfXmj0moQaG29DvANzMDGNpYTb6MxUBbWZ8ffeYnVDouEVp2zMvS6z7gpr6L5+Wphd3oQ==", bSPKI: "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE0QhTU6Opk5i3lrGr4vEkTz/Gk0ZHN5GwYjeBPO6M3RsXKZ4mgc+jn4CJsiyC7tMo8YgH2YRboEIlgCVHTadHZg==",
                   v2: "JfKzTq8xYf54oHFw++cdNltDIvXevyp18hkzEV7TJ+vdbhyaprb1+ZNVaQ==", v1: "AAECAwQFBgcICQoL:UUTm74/MJVet+UcYxnmtmji7xGANQf9vAL55N10gXNtyI67wqMgaaRMq8Q==")
    }
    private func vector(algorithm: String, a: Data, b: Data, aSPKI: String, bSPKI: String, v2: String, v1: String) throws {
        let aID = "00000000-0000-4000-8000-000000000004", bID = "00000000-0000-4000-8000-000000000005"
        let sender = ChatPrivateKey(keyID: aID, algorithm: algorithm, privateData: a, publicKey: aSPKI)
        let receiver = ChatPrivateKey(keyID: bID, algorithm: algorithm, privateData: b, publicKey: bSPKI)
        var fields = ["sender_subject": "account:1", "sender_device_id": "00000000-0000-4000-8000-000000000001", "recipient_subject": "account:2", "client_msg_id": "00000000-0000-4000-8000-000000000003", "target_subject": "account:2", "target_device_id": "00000000-0000-4000-8000-000000000002", "algorithm": algorithm, "sender_key_id": aID, "recipient_key_id": bID]
        let meta = JSONValue.chatObject(fields), nonce = Data((0..<12).map(UInt8.init)), text = "互通向量 🌊 / nu-chat"
        let encrypted = try ChatCrypto.encrypt(text, key: sender, remote: bSPKI, metadata: meta, nonce: nonce)
        XCTAssertEqual(encrypted.0, "AAECAwQFBgcICQoL"); XCTAssertEqual(encrypted.1, v2)
        XCTAssertEqual(try ChatCrypto.decrypt(key: receiver, remote: aSPKI, metadata: meta, nonce: encrypted.0, ciphertext: encrypted.1), text)
        XCTAssertEqual(try ChatCrypto.encryptLegacy(text, key: sender, remote: bSPKI, nonce: nonce), v1)
        XCTAssertEqual(try ChatCrypto.decryptLegacy(v1, key: receiver, remote: aSPKI), text)
        fields["recipient_subject"] = "account:attacker"
        XCTAssertThrowsError(try ChatCrypto.decrypt(key: receiver, remote: aSPKI, metadata: .chatObject(fields), nonce: encrypted.0, ciphertext: encrypted.1))
    }
    func testEncryptedStorePageAndCursorRollbackAndReceiptScopes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ChatLocalStore(namespace: "isolated", key: Data(repeating: 9, count: 32), directory: directory)
        let message = ChatMessage(id: UUID().uuidString, clientID: UUID().uuidString, conversationID: UUID().uuidString, sequence: "1", sender: "account:1", recipient: "account:2", text: "SECRET_NOT_ON_DISK", problem: nil, acceptedAt: 1, status: "accepted", raw: nil, peerSubject: "account:2")
        try await store.commit(events: [.chatObject(["event_seq": "1", "type": "message"])], messages: [message], cursor: "cursor-A")
        do { try await store.commit(events: [.chatObject(["event_seq": "invalid"])], messages: [], cursor: "cursor-B"); XCTFail() } catch {}
        let cursor = try await store.get(String.self, kind: "state", id: "cursor")
        let loaded = try await store.all(ChatMessage.self, kind: "message")
        XCTAssertEqual(cursor, "cursor-A"); XCTAssertEqual(loaded.first?.text, message.text)
        for file in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("isolated"), includingPropertiesForKeys: nil) {
            XCTAssertNil(try Data(contentsOf: file).range(of: Data("SECRET_NOT_ON_DISK".utf8)))
        }
        try await store.clearLocalHistory()
        let retained = try await store.get(String.self, kind: "state", id: "cursor"), remaining = try await store.all(ChatMessage.self, kind: "message")
        XCTAssertEqual(retained, "cursor-A"); XCTAssertTrue(remaining.isEmpty)
    }
    func testHistoryCryptoAuthenticatesAccountPackOrderAndPairing() throws {
        let root = Data(repeating: 5, count: 32).base64EncodedString(), salt = Data(repeating: 8, count: 32)
        let key = try ChatHistoryCrypto.cipher(root: root, salt: salt, owner: "account:1", pack: "pack", kind: "backup")
        let aad = try ChatHistoryCrypto.aad(owner: "account:1", pack: "pack", kind: "backup", index: 0)
        let bytes = try ChatHistoryCrypto.seal(Data("archive".utf8), key: key, aad: aad)
        XCTAssertEqual(try ChatHistoryCrypto.open(bytes, key: key, aad: aad), Data("archive".utf8))
        XCTAssertThrowsError(try ChatHistoryCrypto.open(bytes, key: key, aad: ChatHistoryCrypto.aad(owner: "account:1", pack: "pack", kind: "backup", index: 1)))
        let a = try ChatCrypto.newKeys()[0], b = try ChatCrypto.newKeys()[0]
        let pairing = ChatPairing(version: 1, relay: "https://chat.example", owner: "account:1", packID: "pack", targetDevice: "target", targetPublicKey: b.publicKey, secret: root, expiresAt: 10)
        let proof = try ChatHistoryCrypto.proof(pairing, sourceDevice: "source", sourcePublicKey: a.publicKey)
        let first = try ChatHistoryCrypto.transferRoot(pairing, key: a, peerPublicKey: b.publicKey, sourceDevice: "source", sourcePublicKey: a.publicKey, proof: proof)
        let second = try ChatHistoryCrypto.transferRoot(pairing, key: b, peerPublicKey: a.publicKey, sourceDevice: "source", sourcePublicKey: a.publicKey, proof: proof)
        XCTAssertEqual(first, second)
        XCTAssertThrowsError(try ChatHistoryCrypto.transferRoot(pairing, key: b, peerPublicKey: a.publicKey, sourceDevice: "attacker", sourcePublicKey: a.publicKey, proof: proof))
    }
    @MainActor func testLogoutAndHostChangeImmediatelyHideChatState() throws {
        let session = SessionStore(keychainService: "chat-tests-\(UUID().uuidString)"); defer { session.clear() }
        let suite = UserDefaults(suiteName: "chat-tests-\(UUID().uuidString)")!
        let chat = ChatController(sessionStore: session, mainAPI: APIClient(sessionStore: session), defaults: suite)
        chat.identify(UserProfile(json: .object(["id": .number(1), "username": .string("alice")])))
        chat.setEnabled(true); let original = chat.namespace
        try chat.changeRelay("https://other.example", profile: UserProfile(json: .object(["id": .number(1), "username": .string("alice")])))
        XCTAssertNotEqual(chat.namespace, original); XCTAssertFalse(chat.enabled)
        chat.resetIdentity(); XCTAssertTrue(chat.messages.isEmpty); XCTAssertEqual(chat.unreadCount, 0); XCTAssertNil(chat.connection)
    }
    func testTransportNeverForwardsMainTokenToAnotherEndpointOrRedirect() async throws {
        let transport = ChatTransport(relay: try ChatValidation.relay("https://chat.example")); defer { transport.cancel() }
        do { _ = try await transport.json("/chat/v2/messages", token: "synthetic-main", method: "POST", body: .object([:]), mainCredential: true); XCTFail() } catch {}
        let task = URLSession.shared.dataTask(with: URL(string: "https://chat.example/chat/v2/session")!)
        let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://elsewhere.example"])!
        transport.urlSession(.shared, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://elsewhere.example")!)) { request in XCTAssertNil(request) }
        task.cancel()
    }
}
