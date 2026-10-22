import XCTest
import CryptoKit
import SQLite3
import Security
import SwiftUI
import UIKit
@testable import StarWave

private func reviewConfiguration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ChatReviewProtocol.self]
    return config
}

private final class ChatReviewProtocol: URLProtocol {
    @MainActor static var handler: (@MainActor (URLRequest, ChatReviewProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            guard let handler = Self.handler else { self.client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
            handler(self.request, self)
        }
    }
    override func stopLoading() {}
    func respond(_ data: JSONValue = .object([:]), status: Int = 200) {
        bytes(try! JSONEncoder().encode(status == 200 ? JSONValue.object(["ok": .bool(true), "data": data]) : .object(["ok": .bool(false), "error": .chatObject(["code": "TEMPORARY_FAILURE"])])), status: status)
    }
    func bytes(_ bytes: Data, status: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["X-Chunk-SHA256": ChatCrypto.digest(bytes)])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    func failCancelled() { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
    static func body(_ request: URLRequest) throws -> JSONValue {
        if let data = request.httpBody { return try JSONDecoder().decode(JSONValue.self, from: data) }
        guard let stream = request.httpBodyStream else { return .null }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

@MainActor
private struct ChatReviewFixture {
    let directory: URL
    let session: SessionStore
    let chat: ChatController
    let c: ChatConnection
    let vault: ReviewKeyStore
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-review-" + UUID().uuidString, isDirectory: true)
        session = SessionStore(keychainService: "chat-review-" + UUID().uuidString)
        session.save(AuthTokens(json: .chatObject(["access_token": "synthetic", "username": "alice"]))!)
        let keys = ReviewKeyStore(); vault = keys
        let config = reviewConfiguration()
        let api = APIClient(sessionStore: session, session: URLSession(configuration: config))
        chat = ChatController(sessionStore: session, mainAPI: api, defaults: UserDefaults(suiteName: UUID().uuidString)!,
            keyVaultFactory: { _ in keys },
            transportFactory: { ChatTransport(relay: $0, configuration: reviewConfiguration()) })
        try chat.changeRelay("https://" + UUID().uuidString.lowercased() + ".test", profile: UserProfile(json: .object(["id": .number(1), "username": .string("alice")])))
        chat.setEnabled(true); chat.foreground = true
        var ring = try ChatKeyRing.create(); ring.revision = "1"
        try keys.save(ring)
        let store = try ChatLocalStore(namespace: chat.namespace!, key: ring.storeKey, directory: directory)
        let relay = try ChatValidation.relay(chat.relayText)
        c = ChatConnection(ticket: chat.ticket, namespace: chat.namespace!, subject: "account:1", username: "alice", token: "chat-synthetic", expiresAt: Int64.max,
            transport: ChatTransport(relay: relay, configuration: config), store: store, ring: ring)
        chat.connection = c; chat.localStore = store; chat.connected = true; chat.currentDeviceID = ring.deviceID
        chat.features = ["encrypted_backups", "device_history_transfer", "legacy_android_interop"]
    }
    func clean() {
        chat.suspend(); session.clear(); ChatReviewProtocol.handler = nil
        try? FileManager.default.removeItem(at: directory)
    }
    func message(sequence: String = "1", incoming: Bool = false) -> ChatMessage {
        ChatMessage(id: UUID().uuidString.lowercased(), clientID: UUID().uuidString.lowercased(), conversationID: "00000000-0000-4000-8000-000000000001", sequence: sequence,
            sender: incoming ? "account:2" : c.subject, recipient: incoming ? c.subject : "account:2", text: "合成测试正文", problem: nil, acceptedAt: 1,
            status: incoming ? "incoming" : "accepted", raw: nil, peerSubject: "account:2")
    }
    func emptySync(_ stub: ChatReviewProtocol) { stub.respond(.object(["events": .array([]), "next_cursor": .string("next"), "has_more": .bool(false)])) }
    func conversations(_ stub: ChatReviewProtocol) { stub.respond(.object(["conversations": .array([]), "unread_total": .number(0), "has_more": .bool(false)])) }
    func bundle(_ owner: String, device: String, keys: [ChatPrivateKey]) -> JSONValue {
        .object(["subject": .string(owner), "keyset_revision": .string("1"), "devices": .array([.object(["device_id": .string(device), "key_revision": .string("1"), "keys": .array(keys.map { $0.published.json })])])])
    }
    func nativeEvent(senderKey: ChatPrivateKey, targetKey: ChatPrivateKey, targetDevice: String? = nil, incoming: Bool = true, claimedSenderKeyID: String? = nil) throws -> JSONValue {
        let message = message(incoming: incoming)
        let device = incoming ? UUID().uuidString.lowercased() : c.ring.deviceID
        let metadata = JSONValue.chatObject(["sender_subject": message.sender, "sender_device_id": device,
            "recipient_subject": message.recipient, "client_msg_id": message.clientID, "target_subject": c.subject,
            "target_device_id": targetDevice ?? c.ring.deviceID, "algorithm": senderKey.algorithm,
            "sender_key_id": claimedSenderKeyID ?? senderKey.keyID, "recipient_key_id": targetKey.keyID])
        let cipher = try ChatCrypto.encrypt("可信历史正文", key: senderKey, remote: targetKey.publicKey, metadata: metadata)
        var envelope = metadata.objectValue
        envelope["sender_public_key"] = .string(senderKey.publicKey)
        envelope["nonce"] = .string(cipher.0); envelope["ciphertext"] = .string(cipher.1)
        return .object(["type": .string("message"), "event_seq": .string("1"), "message_id": .string(message.id),
            "client_msg_id": .string(message.clientID), "conversation_id": .string(message.conversationID), "conversation_seq": .string("1"),
            "sender_subject": .string(message.sender), "sender_device_id": .string(device), "recipient_subject": .string(message.recipient),
            "accepted_at_ms": .number(1), "envelope": .object(envelope)])
    }
    func inspection(_ key: ChatPrivateKey) -> ChatPeerInspection {
        ChatPeerInspection(subject: "account:2", username: "bob", protocols: ["nu-chat-v2"], native: nil, legacy: [:],
            fingerprint: ChatCrypto.digest(Data(key.publicKey.utf8)), publicKeys: [key.keyID: key.publicKey])
    }
    func conversation() throws -> ChatConversation {
        try ChatConversation(.chatObject(["conversation_id": "00000000-0000-4000-8000-000000000001", "peer_subject": "account:2", "peer_username": "bob", "last_seq": "1", "revision": "1"]))
    }
    func sealedArchive(id: String, messages: [ChatMessage], keys: [ChatPrivateKey], root: String) throws -> (JSONValue, Data) {
        let salt = Data(repeating: 8, count: 32)
        let key = try ChatHistoryCrypto.cipher(root: root, salt: salt, owner: c.subject, pack: id, kind: "backup")
        let archive = ChatHistoryArchive(format: "nu-chat-records/1", owner: c.subject, relay: c.transport.relay.absoluteString, messages: messages, peers: [], privateKeys: keys)
        let chunk = try ChatHistoryCrypto.seal(JSONEncoder().encode(archive), key: key, aad: ChatHistoryCrypto.aad(owner: c.subject, pack: id, kind: "backup", index: 0))
        let manifest = JSONValue.object(["format": .string("nu-chat-records/1"), "chunks": .array([.object(["index": .number(0), "digest": .string(ChatCrypto.digest(chunk))])])])
        let sealed = try ChatHistoryCrypto.seal(ChatCrypto.canonical(manifest), key: key, aad: ChatHistoryCrypto.aad(owner: c.subject, pack: id, kind: "backup", index: nil))
        let wrapper = JSONValue.chatObject(["format": "nu-chat-history/1", "salt": salt.base64EncodedString(), "sealed_manifest": sealed.base64EncodedString()])
        return (.chatObject(["state": "ready", "revision": "1", "manifest": String(data: try ChatCrypto.canonical(wrapper), encoding: .utf8)!]), chunk)
    }
}

/// Logic tests do not silently relax Keychain access control to work around an
/// unsigned simulator host. Production still uses the strict OS-backed vault.
private final class ReviewKeyStore: ChatKeyStoring {
    var ring: ChatKeyRing?
    var failSave = false
    func load() throws -> ChatKeyRing? { ring }
    func save(_ value: ChatKeyRing) throws {
        if failSave { throw ChatFailure.invalid("Synthetic secure-store write failure") }
        ring = value
    }
}

final class ChatReviewTests: XCTestCase {
    @MainActor func testTrustRevalidatesArchivedHistoryWithoutRelaxingNetworkTargets() async throws {
        let f = try ChatReviewFixture(); defer { f.clean() }
        let oldRing = try ChatKeyRing.create(), remote = try ChatCrypto.newKeys()[0]
        try await f.chat.trust(f.inspection(remote))
        let raw = try f.nativeEvent(senderKey: remote, targetKey: oldRing.keys[0], targetDevice: oldRing.deviceID)
        var oldConnection = f.c; oldConnection.ring = oldRing
        var history = try f.chat.decodeMessage(raw, c: oldConnection)
        XCTAssertEqual(history.text, "可信历史正文")
        // Old nu-chat-records/1 packages did not include local provenance.
        history.validatedTargetDeviceID = nil
        try await f.c.store.put(history, kind: "message", id: history.id)
        f.chat.messages = [] // Revalidation must cover unloaded database rows.
        var live = f.c; live.ring = try live.ring.mergingHistory(oldRing.keys)
        try f.vault.save(live.ring); f.chat.connection = live
        XCTAssertNil(try f.chat.decodeMessage(raw, c: live).text, "A network envelope for old device A must not be accepted by B")
        try await f.chat.trust(f.inspection(remote), note: "重新核对")
        let restored = try await f.c.store.get(ChatMessage.self, kind: "message", id: history.id)
        XCTAssertEqual(restored?.text, "可信历史正文"); XCTAssertEqual(restored?.raw, raw)
        XCTAssertEqual(restored?.validatedTargetDeviceID, oldRing.deviceID)
        XCTAssertEqual(f.chat.messages.first?.text, restored?.text)
        // A failed network decode becoming a local row is not historical trust.
        let untrustedRaw = try f.nativeEvent(senderKey: remote, targetKey: oldRing.keys[0], targetDevice: oldRing.deviceID)
        let untrusted = try f.chat.decodeMessage(untrustedRaw, c: live)
        XCTAssertNil(untrusted.text); XCTAssertNil(untrusted.validatedTargetDeviceID)
        try await f.c.store.put(untrusted, kind: "message", id: untrusted.id)
        try await f.chat.trust(f.inspection(remote))
        let stillUntrusted = try await f.c.store.get(ChatMessage.self, kind: "message", id: untrusted.id)
        XCTAssertNil(stillUntrusted?.text)
        // Preserve recipient provenance across a temporary remote-key failure.
        f.chat.peers = []
        let rechecked = try f.chat.decodeMessage(raw, c: live, storedRecord: try XCTUnwrap(restored))
        XCTAssertNil(rechecked.text); XCTAssertEqual(rechecked.validatedTargetDeviceID, oldRing.deviceID)
        try await f.c.store.put(rechecked, kind: "message", id: rechecked.id)
        try await f.chat.trust(f.inspection(remote))
        let recovered = try await f.c.store.get(ChatMessage.self, kind: "message", id: history.id)
        XCTAssertEqual(recovered?.text, "可信历史正文")
        ChatReviewProtocol.handler = { _, stub in stub.respond(.object(["messages": .array([raw]), "has_more": .bool(false)])) }
        _ = try await f.chat.loadOlder(f.conversation(), before: "2")
        let afterPaging = try await f.c.store.get(ChatMessage.self, kind: "message", id: history.id)
        XCTAssertEqual(afterPaging?.text, recovered?.text); XCTAssertEqual(afterPaging?.raw, recovered?.raw)
        XCTAssertEqual(afterPaging?.validatedTargetDeviceID, oldRing.deviceID, "A network page must not overwrite an already-readable local archived envelope")
    }

    @MainActor func testTrustPreservesReadAndReceivedInMemoryAndDatabase() async throws {
        let f = try ChatReviewFixture(); defer { f.clean() }
        let peer = try ChatCrypto.newKeys()[0]
        var originals: [ChatMessage] = []
        for status in ["read", "received"] {
            let raw = try f.nativeEvent(senderKey: f.c.ring.keys[0], targetKey: f.c.ring.keys[0], incoming: false)
            var message = try f.chat.decodeMessage(raw, c: f.c); message.status = status
            try await f.c.store.put(message, kind: "message", id: message.id); originals.append(message)
        }
        f.chat.messages = originals
        try await f.chat.trust(f.inspection(peer), mode: .legacy, note: "新备注")
        for original in originals {
            let stored = try await f.c.store.get(ChatMessage.self, kind: "message", id: original.id)
            XCTAssertEqual(stored?.status, original.status); XCTAssertEqual(stored?.text, original.text)
            XCTAssertEqual(f.chat.messages.first(where: { $0.id == original.id })?.status, original.status)
        }
    }

    @MainActor func testDelayedHistoryPageCannotBypassHideRecallOrClearFilters() async throws {
        for kind in ["message_hidden", "message_recalled", "history_cleared"] {
            let f = try ChatReviewFixture(); defer { f.clean() }
            let peer = try ChatCrypto.newKeys()[0]; try await f.chat.trust(f.inspection(peer))
            let raw = try f.nativeEvent(senderKey: peer, targetKey: f.c.ring.keys[0]), conv = try f.conversation()
            let id = try raw.chatString("message_id")
            let deletion = kind == "history_cleared"
                ? JSONValue.chatObject(["event_seq": "2", "type": kind, "conversation_id": conv.id, "through_seq": "1"])
                : .chatObject(["event_seq": "2", "type": kind, "message_id": id])
            var page: ChatReviewProtocol?
            ChatReviewProtocol.handler = { request, stub in
                if request.url!.path.hasSuffix("/messages") { page = stub }
                else if request.url!.path == "/chat/v2/sync" { stub.respond(.object(["events": .array([deletion]), "next_cursor": .string("deleted"), "has_more": .bool(false)])) }
                else if request.url!.path == "/chat/v2/conversations" { f.conversations(stub) }
                else { stub.respond() }
            }
            let paging = Task { try await f.chat.loadOlder(conv, before: "2") }
            for _ in 0..<200 where page == nil { try await Task.sleep(nanoseconds: 5_000_000) }
            let held = try XCTUnwrap(page)
            try await f.chat.sync(f.c) // ACK deletion while the old page is in flight.
            held.respond(.object(["messages": .array([raw]), "has_more": .bool(false)]))
            _ = try await paging.value
            let stored = try await f.c.store.get(ChatMessage.self, kind: "message", id: id)
            XCTAssertNil(stored?.text); XCTAssertNil(stored?.raw)
            XCTAssertTrue(["hidden", "recalled"].contains(stored?.status ?? ""))
            XCTAssertNil(f.chat.messages.first(where: { $0.id == id })?.text)
            let cursor = try await f.c.store.get(String.self, kind: "state", id: "cursor")
            XCTAssertEqual(cursor, "deleted", "History pagination must not reset the acknowledged sync cursor")
        }
    }

    @MainActor func testOwnMessagesRequireKnownMatchingSenderKeys() throws {
        let f = try ChatReviewFixture(); defer { f.clean() }
        let attacker = try ChatCrypto.newKeys()[0], target = f.c.ring.keys[0]
        for claimedID in [attacker.keyID, target.keyID] {
            let raw = try f.nativeEvent(senderKey: attacker, targetKey: target, incoming: false, claimedSenderKeyID: claimedID)
            let envelope = try XCTUnwrap(raw["envelope"])
            // This is mathematically valid ciphertext, not a corrupt payload.
            XCTAssertEqual(try ChatCrypto.decrypt(key: target, remote: attacker.publicKey, metadata: envelope,
                nonce: envelope.chatString("nonce"), ciphertext: envelope.chatString("ciphertext")), "可信历史正文")
            let decoded = try f.chat.decodeMessage(raw, c: f.c)
            XCTAssertNil(decoded.text); XCTAssertNotNil(decoded.problem)
        }
        let local = try f.nativeEvent(senderKey: target, targetKey: target, incoming: false)
        XCTAssertEqual(try f.chat.decodeMessage(local, c: f.c).text, "可信历史正文")
        var live = f.c; live.ring = try live.ring.mergingHistory([attacker])
        let archived = try f.nativeEvent(senderKey: attacker, targetKey: target, incoming: false)
        XCTAssertEqual(try f.chat.decodeMessage(archived, c: live).text, "可信历史正文", "Validated archived private keys are a known identity source")
    }

    @MainActor func testLegacyAcceptanceSurvivesUnavailableAndSamePageDeletion() async throws {
        for unavailable in [false, true] { for kind in ["message_hidden", "message_recalled", "history_cleared"] {
            let f = try ChatReviewFixture(); defer { f.clean() }
            let key = f.c.ring.keys[0], remote = try ChatCrypto.newKeys()[0]
            var peer = ChatPeer(subject: "account:2", username: "bob"); peer.trustVersion = 1; peer.fingerprint = "synthetic"
            peer.trustedKeys[ChatCrypto.legacyID(key.algorithm, remote.publicKey)] = remote.publicKey; f.chat.peers = [peer]
            var placeholder = f.message(sequence: "0"); placeholder.id = "pending:" + placeholder.clientID; placeholder.status = "accepted_waiting_sync"
            let cipher = try ChatCrypto.encryptLegacy("原始待发", key: key, remote: remote.publicKey)
            let pending = ChatPendingSend(id: placeholder.clientID, peerSubject: placeholder.peerSubject, path: "/chat/v2/legacy/messages",
                body: .chatObject(["client_msg_id": placeholder.clientID, "cipher": cipher, "sender_key_id": key.keyID]), message: placeholder)
            var other = placeholder; other.clientID = UUID().uuidString.lowercased(); other.id = "pending:" + other.clientID; other.status = "pending"
            let unrelated = ChatPendingSend(id: other.clientID, peerSubject: other.peerSubject, path: pending.path,
                body: .chatObject(["client_msg_id": other.clientID, "cipher": "other", "sender_key_id": key.keyID]), message: other)
            try await f.c.store.savePending(pending); try await f.c.store.savePending(unrelated)
            f.chat.messages = [placeholder, other]; f.chat.pending = [pending, unrelated]
            let id = UUID().uuidString.lowercased()
            var fields = JSONValue.chatObject(["event_seq": "1", "type": "message", "message_id": id,
                "client_msg_id": "v2:" + f.c.ring.deviceID + ":" + pending.id, "conversation_id": placeholder.conversationID,
                "conversation_seq": "1", "sender_subject": f.c.subject, "sender_device_id": f.c.ring.deviceID,
                "recipient_subject": placeholder.recipient, "accepted_at_ms": "1"]).objectValue
            if unavailable { fields["unavailable"] = .string(kind == "message_recalled" ? "recalled" : "hidden") }
            else { fields["envelope"] = .chatObject(["protocol": "nu-chat-v1", "algorithm": key.algorithm,
                "cipher": cipher, "own_key_id": key.keyID, "recipient_public_key": remote.publicKey]) }
            let deletion = kind == "history_cleared"
                ? JSONValue.chatObject(["event_seq": "2", "type": kind, "conversation_id": placeholder.conversationID, "through_seq": "1"])
                : .chatObject(["event_seq": "2", "type": kind, "message_id": id])
            ChatReviewProtocol.handler = { request, stub in
                if request.url!.path == "/chat/v2/sync" { stub.respond(.object(["events": .array([.object(fields), deletion]), "next_cursor": .string("filtered-accept"), "has_more": .bool(false)])) }
                else if request.url!.path == "/chat/v2/conversations" { f.conversations(stub) }
                else { stub.respond() }
            }
            try await f.chat.sync(f.c)
            let outbox = try await f.c.store.all(ChatPendingSend.self, kind: "pending")
            XCTAssertEqual(outbox.map(\.id), [unrelated.id]); XCTAssertEqual(f.chat.pending.map(\.id), [unrelated.id])
            let stored = try await f.c.store.get(ChatMessage.self, kind: "message", id: id)
            XCTAssertNil(stored?.text); XCTAssertNil(stored?.raw)
            XCTAssertFalse(f.chat.messages.contains(where: { $0.id == placeholder.id }))
            XCTAssertTrue(f.chat.messages.contains(where: { $0.id == unrelated.message.id }))
        } }
    }

    @MainActor func testUnavailableLegacyAcceptanceRejectsUnrelatedEvidence() throws {
        let f = try ChatReviewFixture(); defer { f.clean() }
        var placeholder = f.message(sequence: "0"); placeholder.id = "pending:" + placeholder.clientID; placeholder.status = "pending"
        let body = JSONValue.chatObject(["client_msg_id": placeholder.clientID, "sender_key_id": f.c.ring.keys[0].keyID, "cipher": "durable-cipher"])
        let pending = ChatPendingSend(id: placeholder.clientID, peerSubject: placeholder.peerSubject, path: "/chat/v2/legacy/messages", body: body, message: placeholder)
        var accepted = placeholder; accepted.id = UUID().uuidString.lowercased(); accepted.sequence = "1"; accepted.status = "hidden"
        accepted.clientID = "v2:" + f.c.ring.deviceID + ":" + pending.id
        accepted.raw = .chatObject(["client_msg_id": accepted.clientID, "sender_device_id": f.c.ring.deviceID, "unavailable": "hidden"])
        XCTAssertTrue(pending.isAccepted(by: accepted, deviceID: f.c.ring.deviceID))
        XCTAssertFalse(pending.isAccepted(by: accepted)); XCTAssertFalse(pending.isAccepted(by: accepted, deviceID: UUID().uuidString))
        var wrong = accepted; wrong.sequence = "0"; XCTAssertFalse(pending.isAccepted(by: wrong, deviceID: f.c.ring.deviceID))
        wrong = accepted; wrong.sender = "account:other"; XCTAssertFalse(pending.isAccepted(by: wrong, deviceID: f.c.ring.deviceID))
        wrong = accepted; wrong.recipient = "account:other"; XCTAssertFalse(pending.isAccepted(by: wrong, deviceID: f.c.ring.deviceID))
        wrong = accepted; wrong.raw = .chatObject(["sender_device_id": f.c.ring.deviceID, "unavailable": "expired"])
        XCTAssertFalse(pending.isAccepted(by: wrong, deviceID: f.c.ring.deviceID))
        let noRequest = ChatPendingSend(id: pending.id, peerSubject: pending.peerSubject, path: pending.path, body: .object([:]), message: placeholder)
        XCTAssertFalse(noRequest.isAccepted(by: accepted, deviceID: f.c.ring.deviceID))
        let native = ChatPendingSend(id: pending.id, peerSubject: pending.peerSubject, path: "/chat/v2/messages", body: body, message: placeholder)
        XCTAssertFalse(native.isAccepted(by: accepted, deviceID: f.c.ring.deviceID))
    }

    @MainActor func testLocalCleanupAndPendingDiscardNeedNoConnection() async throws {
        let f = try ChatReviewFixture(); defer { f.clean() }
        let message = f.message(); try await f.c.store.put(message, kind: "message", id: message.id)
        try await f.c.store.put("offline-cursor", kind: "state", id: "cursor")
        let filter = JSONValue.chatObject(["event_seq": "1", "type": "message_hidden", "message_id": UUID().uuidString.lowercased()])
        try await f.c.store.commit(events: [filter], messages: [], cursor: nil, owner: f.c.subject)
        let peer = ChatPeer(subject: "account:2", username: "bob"); try await f.c.store.put(peer, kind: "peer", id: peer.id)
        try await f.c.store.put("draft", kind: "draft", id: peer.id)
        var queued = f.message(sequence: "0"); queued.id = "pending:" + queued.clientID; queued.status = "pending"
        let pending = ChatPendingSend(id: queued.clientID, peerSubject: queued.peerSubject, path: "/chat/v2/messages", body: .object([:]), message: queued)
        try await f.c.store.savePending(pending); f.chat.pending = [pending]; f.chat.messages = [message, queued]
        f.chat.suspend()
        var requests = 0
        ChatReviewProtocol.handler = { _, stub in requests += 1; stub.respond(status: 503) }
        try await f.chat.discardPending(pending)
        let removed = try await f.c.store.get(ChatPendingSend.self, kind: "pending", id: pending.id)
        XCTAssertNil(removed); XCTAssertTrue(f.chat.pending.isEmpty)
        try await f.c.store.savePending(pending)
        try await f.chat.clearLocal()
        XCTAssertEqual(requests, 0); XCTAssertTrue(f.chat.messages.isEmpty); XCTAssertTrue(f.chat.pending.isEmpty)
        for kind in ["message", "event", "pending", "draft", "preparedHistory", "historyChunk", "transferTarget", "backupKeySaved"] {
            let records = try await f.c.store.all(JSONValue.self, kind: kind); XCTAssertTrue(records.isEmpty, kind)
        }
        let cursor = try await f.c.store.get(String.self, kind: "state", id: "cursor")
        let filters = try await f.c.store.all(JSONValue.self, kind: "historyFilter")
        let retainedPeer = try await f.c.store.get(ChatPeer.self, kind: "peer", id: peer.id)
        XCTAssertEqual(cursor, "offline-cursor"); XCTAssertEqual(filters.count, 1); XCTAssertEqual(retainedPeer, peer)
        XCTAssertEqual(try f.vault.load()?.keys.map(\.publicKey), f.c.ring.keys.map(\.publicKey))
        XCTAssertEqual(try f.vault.load()?.deviceID, f.c.ring.deviceID)
        f.chat.resetIdentity()
        do { try await f.chat.clearLocal(); XCTFail("No account-scoped cleanup after logout") } catch {}
        XCTAssertEqual(requests, 0)
    }

    @MainActor func testClearLocalRejectsDelayedPageWithoutCreatingNewRequests() async throws {
        let f = try ChatReviewFixture(); defer { f.clean() }
        let peer = try ChatCrypto.newKeys()[0]; try await f.chat.trust(f.inspection(peer))
        let raw = try f.nativeEvent(senderKey: peer, targetKey: f.c.ring.keys[0]), conv = try f.conversation()
        var page: ChatReviewProtocol?, requests = 0
        ChatReviewProtocol.handler = { _, stub in requests += 1; page = stub }
        let paging = Task { try await f.chat.loadOlder(conv, before: "2") }
        for _ in 0..<200 where page == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        // Release old IO immediately before cleanup. Its callback must not get
        // permission to write merely because the HTTP response succeeded.
        try XCTUnwrap(page).respond(.object(["messages": .array([raw]), "has_more": .bool(false)]))
        try await f.chat.clearLocal()
        do { _ = try await paging.value; XCTFail("Old lifecycle page must be rejected") } catch {}
        let messages = try await f.c.store.all(ChatMessage.self, kind: "message")
        XCTAssertTrue(messages.isEmpty); XCTAssertTrue(f.chat.messages.isEmpty); XCTAssertEqual(requests, 1)
        XCTAssertThrowsError(try f.chat.current(f.c))
    }

    @MainActor func testOldReadAndClearNeverConsumePendingOrAcceptedWaitingSync() async throws {
        let f = try ChatReviewFixture(); defer { f.clean() }
        var pending = f.message(sequence: "0"); pending.id = "pending:" + pending.clientID; pending.status = "pending"
        let item = ChatPendingSend(id: pending.clientID, peerSubject: pending.peerSubject, path: "/chat/v2/messages", body: .chatObject(["client_msg_id": pending.clientID]), message: pending)
        try await f.c.store.savePending(item); f.chat.messages = [pending]; f.chat.pending = [item]
        let events: [JSONValue] = [
            .chatObject(["type": "read", "event_seq": "1", "conversation_id": pending.conversationID, "reader_subject": "account:2", "up_to_conversation_seq": "20"]),
            .chatObject(["type": "history_cleared", "event_seq": "2", "conversation_id": pending.conversationID, "through_seq": "20"])
        ]
        ChatReviewProtocol.handler = { request, stub in
            if request.url!.path == "/chat/v2/sync" { stub.respond(.object(["events": .array(events), "next_cursor": .string("read-clear"), "has_more": .bool(false)])) }
            else if request.url!.path == "/chat/v2/conversations" { f.conversations(stub) }
            else { stub.respond() }
        }
        try await f.chat.sync(f.c)
        XCTAssertEqual(f.chat.messages.first?.status, "pending"); XCTAssertEqual(f.chat.pending.count, 1)
        let loaded = try await f.c.store.get(ChatPendingSend.self, kind: "pending", id: item.id)
        XCTAssertEqual(loaded?.body, item.body); XCTAssertEqual(loaded?.message.text, pending.text)
        var waiting = item; waiting.message.status = "accepted_waiting_sync"
        try await f.c.store.savePending(waiting)
        try await f.c.store.commit(events: events, messages: [], cursor: "next", owner: f.c.subject)
        let retained = try await f.c.store.get(ChatPendingSend.self, kind: "pending", id: item.id)
        XCTAssertEqual(retained?.message.status, "accepted_waiting_sync")
    }

    @MainActor func testCurrentFingerprintNeverTrustsForgedHistoricalKey() async throws {
        let f = try ChatReviewFixture(); defer { f.clean() }
        let real = try ChatCrypto.newKeys()[0], attacker = try ChatCrypto.newKeys()[0], target = f.c.ring.keys[0]
        let device = UUID().uuidString.lowercased(), client = UUID().uuidString.lowercased()
        let metadata = JSONValue.chatObject(["sender_subject": "account:2", "sender_device_id": device, "recipient_subject": f.c.subject, "client_msg_id": client,
            "target_subject": f.c.subject, "target_device_id": f.c.ring.deviceID, "algorithm": attacker.algorithm, "sender_key_id": attacker.keyID, "recipient_key_id": target.keyID])
        let cipher = try ChatCrypto.encrypt("伪造历史", key: attacker, remote: target.publicKey, metadata: metadata)
        var fields = metadata.objectValue
        fields["sender_public_key"] = .string(attacker.publicKey); fields["nonce"] = .string(cipher.0); fields["ciphertext"] = .string(cipher.1)
        var event = f.message(incoming: true)
        let raw = JSONValue.object(["message_id": .string(event.id), "client_msg_id": .string(client), "conversation_id": .string(event.conversationID), "conversation_seq": .string("1"), "sender_subject": .string("account:2"), "recipient_subject": .string(f.c.subject), "sender_device_id": .string(device), "accepted_at_ms": .number(1), "envelope": .object(fields)])
        event = try f.chat.decodeMessage(raw, c: f.c)
        event.text = "旧版本曾错误信任的缓存"; event.problem = nil
        try await f.c.store.put(event, kind: "message", id: event.id); f.chat.messages = [event]
        let keys = [real.keyID: real.publicKey]
        let fingerprint = ChatCrypto.digest(try ChatCrypto.canonical(.object(keys.mapValues(JSONValue.string))))
        let inspection = ChatPeerInspection(subject: "account:2", username: "bob", protocols: ["nu-chat-v2"], native: nil, legacy: [:], fingerprint: fingerprint, publicKeys: keys)
        try await f.chat.trust(inspection)
        XCTAssertEqual(f.chat.peers.first?.fingerprint, fingerprint)
        XCTAssertNil(f.chat.peers.first?.trustedKeys[attacker.keyID]); XCTAssertNil(f.chat.messages.first?.text)
        XCTAssertNotNil(f.chat.messages.first?.problem)
        // Keys explicitly checked in a prior safe version remain trusted.
        let next = try ChatCrypto.newKeys()[0]
        try await f.chat.trust(ChatPeerInspection(subject: "account:2", username: "bob", protocols: ["nu-chat-v2"], native: nil, legacy: [:], fingerprint: "next", publicKeys: [next.keyID: next.publicKey]))
        XCTAssertEqual(f.chat.peers.first?.trustedKeys[real.keyID], real.publicKey)
    }

    @MainActor func testLegacyAssociationIsDeviceScopedAndRemovesOnlyProvenDuplicate() async throws {
        let f = try ChatReviewFixture(); defer { f.clean() }
        for algorithm in ["X25519", "P256"] {
            let key = f.c.ring.keys.first { $0.algorithm == algorithm }!
            var accepted = f.message(), placeholder = accepted
            placeholder.id = "pending:" + accepted.clientID; placeholder.sequence = "0"; placeholder.status = "pending"
            let cipher = "synthetic-" + algorithm
            let item = ChatPendingSend(id: accepted.clientID, peerSubject: accepted.peerSubject, path: "/chat/v2/legacy/messages", body: .chatObject(["cipher": cipher, "sender_key_id": key.keyID]), message: placeholder)
            try await f.c.store.savePending(item)
            accepted.clientID = "v2:" + f.c.ring.deviceID + ":" + item.id
            accepted.raw = .object(["sender_device_id": .string(f.c.ring.deviceID), "envelope": .chatObject(["protocol": "nu-chat-v1", "cipher": cipher, "own_key_id": key.keyID])])
            let wire = accepted.raw
            var foreign = accepted; foreign.sender = "account:foreign"; foreign.associateLegacySend(owner: f.c.subject, deviceID: f.c.ring.deviceID)
            XCTAssertNotEqual(foreign.clientID, item.id)
            var anotherDevice = accepted; anotherDevice.associateLegacySend(owner: f.c.subject, deviceID: UUID().uuidString)
            XCTAssertNotEqual(anotherDevice.clientID, item.id)
            var native = accepted; native.raw = .object(["sender_device_id": .string(f.c.ring.deviceID), "envelope": .chatObject(["algorithm": algorithm])])
            native.associateLegacySend(owner: f.c.subject, deviceID: f.c.ring.deviceID); XCTAssertNotEqual(native.clientID, item.id)
            accepted.associateLegacySend(owner: f.c.subject, deviceID: f.c.ring.deviceID)
            XCTAssertEqual(accepted.clientID, item.id); XCTAssertEqual(accepted.raw, wire)
            var mismatch = accepted; mismatch.raw = .object(["envelope": .chatObject(["protocol": "nu-chat-v1", "cipher": "different", "own_key_id": key.keyID])])
            XCTAssertFalse(item.isAccepted(by: mismatch))
            try await f.c.store.put(accepted, kind: "message", id: accepted.id) // historical double-bubble state
            try await f.c.store.commit(events: [], messages: [accepted], cursor: nil)
            let pending = try await f.c.store.get(ChatPendingSend.self, kind: "pending", id: item.id)
            let old = try await f.c.store.get(ChatMessage.self, kind: "message", id: placeholder.id)
            XCTAssertNil(pending); XCTAssertNil(old)
        }
    }

    @MainActor func testOfflineDraftSurvivesSuspendAndCannotCrossNamespace() async throws {
        let f = try ChatReviewFixture(); defer { f.clean() }
        let ns = f.c.namespace
        f.chat.suspend()
        await f.chat.saveDraft("离线新草稿🌊", peer: "account:2", namespace: ns)
        let loaded = await f.chat.draft(for: "account:2")
        XCTAssertEqual(loaded, "离线新草稿🌊")
        await f.chat.saveDraft("迟到的其他来源草稿", peer: "account:2", namespace: "another-namespace")
        let retained = await f.chat.draft(for: "account:2")
        XCTAssertEqual(retained, loaded)
        f.chat.resetIdentity(); await f.chat.saveDraft("退出后不能写", peer: "account:2", namespace: ns)
        let stored = try await f.c.store.get(String.self, kind: "draft", id: "account:2")
        XCTAssertEqual(stored, loaded)
    }

    @MainActor func testMonitorSurvivesTransportCancellationAndRestoresSendStateAfter503() async throws {
        let f = try ChatReviewFixture(); defer { f.clean() }
        var polls = 0
        ChatReviewProtocol.handler = { request, stub in
            if request.url!.path == "/chat/v2/sync" {
                polls += 1
                if polls == 1 { stub.failCancelled() }
                else if polls == 2 { stub.respond(status: 503) }
                else { f.emptySync(stub) }
            } else if request.url!.path == "/chat/v2/conversations" { f.conversations(stub) }
            else { stub.respond() }
        }
        let task = Task { await f.chat.monitor(pollIntervalNanoseconds: 1_000_000) }
        defer { task.cancel() }
        for _ in 0..<200 where polls < 3 || !f.chat.connected { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertGreaterThanOrEqual(polls, 3); XCTAssertTrue(f.chat.connected); XCTAssertTrue(f.chat.foreground)
        task.cancel(); await task.value
    }

    @MainActor func testAcceptedSendDoesNotFailWhenFollowupSyncIs503() async throws {
        let f = try ChatReviewFixture(); defer { f.clean() }
        let recipient = try ChatKeyRing.create(), serverMessage = UUID().uuidString.lowercased()
        var posts: [JSONValue] = [], queued = 0, reject = true
        ChatReviewProtocol.handler = { request, stub in
            let path = request.url!.path
            if path.hasSuffix("/protocols") { stub.respond(.object(["subject": .string("account:2"), "protocols": .array([.string("nu-chat-v2")]), "legacy_public_keys": .array([])])) }
            else if path == "/chat/v2/users/bob/keys" { stub.respond(f.bundle("account:2", device: recipient.deviceID, keys: recipient.keys)) }
            else if path == "/chat/v2/users/alice/keys" { stub.respond(f.bundle(f.c.subject, device: f.c.ring.deviceID, keys: f.c.ring.keys)) }
            else if path == "/chat/v2/messages" {
                let body = try! ChatReviewProtocol.body(request); posts.append(body)
                if reject { stub.respond(status: 503) }
                else { stub.respond(.object(["message_id": .string(serverMessage), "conversation_id": .string("00000000-0000-4000-8000-000000000001"), "conversation_seq": .string("1"), "accepted_at_ms": .number(1)])) }
            } else if path == "/chat/v2/sync" { stub.respond(status: 503) }
            else { XCTFail("Unexpected synthetic route \(path)"); stub.respond(status: 404) }
        }
        let inspection = try await f.chat.inspectPeer("bob"); try await f.chat.trust(inspection)
        do { try await f.chat.send("只发一次", to: f.chat.peers[0]) { queued += 1 }; XCTFail() } catch {}
        XCTAssertEqual(f.chat.pending.count, 1); XCTAssertEqual(queued, 1)
        let original = try XCTUnwrap(f.chat.pending.first)
        reject = false
        try await f.chat.retry(original)
        XCTAssertEqual(posts.count, 2); XCTAssertEqual(posts.first, posts.last); XCTAssertEqual(queued, 1)
        XCTAssertEqual(f.chat.messages.filter { $0.id == serverMessage }.count, 1)
        XCTAssertTrue(f.chat.pending.isEmpty); XCTAssertNotNil(f.chat.error)
    }

    @MainActor func testFailedFinalRestoreFilterLeavesNoPartialRecordsAndDeletesRemainDurable() async throws {
        let f = try ChatReviewFixture(); defer { f.clean() }
        let id = UUID().uuidString.lowercased(), root = Data(repeating: 3, count: 32).base64EncodedString(), message = f.message(incoming: true)
        let (pack, chunk) = try f.sealedArchive(id: id, messages: [message], keys: [], root: root)
        var reads = 0
        ChatReviewProtocol.handler = { request, stub in
            if request.url!.path.hasSuffix("/filters") { reads += 1; if reads == 2 { stub.respond(status: 503) } else { stub.respond(.object(["revision": .string("1"), "filters": .array([]), "has_more": .bool(false)])) } }
            else if request.url!.path.hasSuffix("/chunks/0") { stub.bytes(chunk) }
            else { stub.respond(pack) }
        }
        do { try await f.chat.restoreBackup(id: id, recoveryKey: root); XCTFail("Final filters must succeed before persistence") } catch {}
        let absent = try await f.c.store.all(ChatMessage.self, kind: "message")
        XCTAssertTrue(absent.isEmpty)
        let deletion = JSONValue.chatObject(["type": "message_hidden", "event_seq": "1", "message_id": message.id])
        try await f.c.store.commit(events: [deletion], messages: [], cursor: "after-delete", owner: f.c.subject)
        try await f.c.store.mergeRestored([message], filters: [])
        let stillAbsent = try await f.c.store.get(ChatMessage.self, kind: "message", id: message.id)
        XCTAssertNil(stillAbsent)
        // A row not loaded in the UI must still be hidden before ACK.
        var other = f.message(incoming: true); other.id = UUID().uuidString.lowercased()
        try await f.c.store.put(other, kind: "message", id: other.id)
        try await f.c.store.commit(events: [.chatObject(["type": "message_hidden", "event_seq": "2", "message_id": other.id])], messages: [], cursor: "after-other", owner: f.c.subject)
        let hidden = try await f.c.store.get(ChatMessage.self, kind: "message", id: other.id)
        XCTAssertNil(hidden?.text); XCTAssertEqual(hidden?.status, "hidden")
    }

    @MainActor func testParallelRestoresMergeLatestHistoricalKeyRing() async throws {
        let f = try ChatReviewFixture(); defer { f.clean() }
        let a = try ChatCrypto.newKeys()[0], b = try ChatCrypto.newKeys()[0], aID = UUID().uuidString.lowercased(), bID = UUID().uuidString.lowercased()
        let root = Data(repeating: 4, count: 32).base64EncodedString()
        let first = try f.sealedArchive(id: aID, messages: [], keys: [a], root: root), second = try f.sealedArchive(id: bID, messages: [], keys: [b], root: root)
        ChatReviewProtocol.handler = { request, stub in
            let path = request.url!.path
            if path.hasSuffix("/filters") { stub.respond(.object(["revision": .string("1"), "filters": .array([]), "has_more": .bool(false)])) }
            else { let pair = path.contains(aID) ? first : second; if path.hasSuffix("/chunks/0") { stub.bytes(pair.1) } else { stub.respond(pair.0) } }
        }
        async let one: Void = f.chat.restoreBackup(id: aID, recoveryKey: root)
        async let two: Void = f.chat.restoreBackup(id: bID, recoveryKey: root)
        _ = try await (one, two)
        let ring = try XCTUnwrap(f.vault.load())
        XCTAssertEqual(try ring.key(a.keyID).publicKey, a.publicKey); XCTAssertEqual(try ring.key(b.keyID).publicKey, b.publicKey)
        XCTAssertEqual(ring.deviceID, f.c.ring.deviceID); XCTAssertEqual(Set(ring.keys.map(\.keyID)), Set(f.c.ring.keys.map(\.keyID)))
    }

    @MainActor func testBackupUploadAndResumeBothRequirePerPackConfirmation() async throws {
        let f = try ChatReviewFixture(); defer { f.clean() }
        let pack = ChatPreparedPack(id: UUID().uuidString.lowercased(), kind: "backup", root: "synthetic-root", recoveryKeyID: UUID().uuidString,
            manifest: "synthetic-manifest", digests: [], bytes: 0, sourcePublicKey: nil, approvalProof: nil)
        try await f.c.store.put(pack, kind: "preparedHistory", id: pack.id)
        var requests = 0
        ChatReviewProtocol.handler = { _, stub in requests += 1; stub.respond(.chatObject(["state": "ready", "manifest": pack.manifest])) }
        do { try await f.chat.uploadBackup(pack); XCTFail() } catch {}
        do { try await f.chat.resumePrepared(pack); XCTFail() } catch {}
        XCTAssertEqual(requests, 0)
        try await f.chat.confirmBackupKeySaved(pack.id)
        try await f.chat.resumePrepared(pack); XCTAssertEqual(requests, 2)
        let other = ChatPreparedPack(id: UUID().uuidString, kind: "backup", root: pack.root, recoveryKeyID: pack.recoveryKeyID, manifest: pack.manifest, digests: [], bytes: 0, sourcePublicKey: nil, approvalProof: nil)
        do { try await f.chat.uploadBackup(other); XCTFail() } catch {}
        XCTAssertEqual(requests, 2)
    }

    @MainActor func testEmptySyncDoesNotResealHistoricalRows() async throws {
        let f = try ChatReviewFixture(); defer { f.clean() }
        let message = f.message(); try await f.c.store.put(message, kind: "message", id: message.id); f.chat.messages = [message]
        let path = f.directory.appendingPathComponent(f.c.namespace).appendingPathComponent("history.sqlite").path
        func raw() throws -> Data {
            var db: OpaquePointer?, stmt: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw ChatFailure.storage }
            defer { sqlite3_close(db) }
            guard sqlite3_prepare_v2(db, "SELECT value FROM records WHERE kind='message'", -1, &stmt, nil) == SQLITE_OK else { throw ChatFailure.storage }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw ChatFailure.storage }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
        }
        let before = try raw()
        ChatReviewProtocol.handler = { request, stub in
            if request.url!.path == "/chat/v2/sync" { f.emptySync(stub) }
            else if request.url!.path == "/chat/v2/conversations" { f.conversations(stub) }
            else { stub.respond() }
        }
        try await f.chat.sync(f.c); try await f.chat.sync(f.c)
        XCTAssertEqual(try raw(), before); XCTAssertEqual(f.chat.messages, [message])
    }

    @MainActor func testVisibleReadCanResumeWithoutAnyLayoutChange() throws {
        let f = try ChatReviewFixture(); defer { f.clean() }
        let message = f.message(incoming: true), frames = [message.id: CGRect(x: 0, y: 10, width: 100, height: 44)]
        let viewport = CGSize(width: 320, height: 200)
        XCTAssertNil(ChatVisibleRead.latest([message], frames: frames, viewport: viewport, owner: f.c.subject, after: 0, enabled: false))
        XCTAssertEqual(ChatVisibleRead.latest([message], frames: frames, viewport: viewport, owner: f.c.subject, after: 0, enabled: true)?.id, message.id)
        XCTAssertNil(ChatVisibleRead.latest([message], frames: frames, viewport: viewport, owner: f.c.subject, after: 1, enabled: true))
        var unreadable = message; unreadable.text = nil
        XCTAssertNil(ChatVisibleRead.latest([unreadable], frames: frames, viewport: viewport, owner: f.c.subject, after: 0, enabled: true))
    }

    @MainActor func testSecureStoreFailureStopsBeforeRegistrationOrCredentialExchange() async throws {
        let f = try ChatReviewFixture(); defer { f.clean() }
        f.chat.connection = nil; f.chat.localStore = nil; f.vault.failSave = true
        var requests = 0
        ChatReviewProtocol.handler = { _, stub in requests += 1; stub.respond() }
        do { _ = try await f.chat.connect(); XCTFail("Secure-store failure must stop authentication") } catch {}
        XCTAssertEqual(requests, 0); XCTAssertNil(f.chat.connection)
    }

    @MainActor func testComposerAppearanceAttachments() async throws {
        for (name, dark, reduce, large) in [("light", false, false, false), ("dark", true, false, false), ("opaque", false, true, false), ("accessibility", false, false, true)] {
            let composer = ChatComposer(text: .constant("测试多行输入\n原生 Liquid Glass"), sending: false, connected: true, protocolTitle: "旧安卓兼容", send: {})
                .padding(.vertical, 20).background(Color(uiColor: .systemGroupedBackground))
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.appPrefersOpaqueChatControls, reduce)
                .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
            let host = UIHostingController(rootView: composer)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: large ? 440 : 220)
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.rootViewController = host; window.windowLevel = .alert + 1; window.makeKeyAndVisible()
            host.view.frame = window.bounds; host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            var rendered = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "chat-composer-" + name; attachment.lifetime = .keepAlways
            add(attachment); XCTAssertTrue(rendered); XCTAssertNotNil(image.pngData())
            if let pixels = image.cgImage?.dataProvider?.data { XCTAssertGreaterThan(Set(pixels as Data).count, 8, "Blank preview is not a visual regression result") }
            window.isHidden = true; previous?.makeKey()
        }
    }
}
