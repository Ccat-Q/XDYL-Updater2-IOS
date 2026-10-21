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
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-review-" + UUID().uuidString, isDirectory: true)
        session = SessionStore(keychainService: "chat-review-" + UUID().uuidString)
        session.save(AuthTokens(json: .chatObject(["access_token": "synthetic", "username": "alice"]))!)
        let config = reviewConfiguration()
        let api = APIClient(sessionStore: session, session: URLSession(configuration: config))
        chat = ChatController(sessionStore: session, mainAPI: api, defaults: UserDefaults(suiteName: UUID().uuidString)!,
            transportFactory: { ChatTransport(relay: $0, configuration: reviewConfiguration()) })
        try chat.changeRelay("https://" + UUID().uuidString.lowercased() + ".test", profile: UserProfile(json: .object(["id": .number(1), "username": .string("alice")])))
        chat.setEnabled(true); chat.foreground = true
        var ring = try ChatKeyRing.create(); ring.revision = "1"
        try ChatKeyVault(namespace: chat.namespace!).save(ring)
        let store = try ChatLocalStore(namespace: chat.namespace!, key: ring.storeKey, directory: directory)
        let relay = try ChatValidation.relay(chat.relayText)
        c = ChatConnection(ticket: chat.ticket, namespace: chat.namespace!, subject: "account:1", username: "alice", token: "chat-synthetic", expiresAt: Int64.max,
            transport: ChatTransport(relay: relay, configuration: config), store: store, ring: ring)
        chat.connection = c; chat.localStore = store; chat.connected = true; chat.currentDeviceID = ring.deviceID
        chat.features = ["encrypted_backups", "device_history_transfer", "legacy_android_interop"]
    }
    func clean() {
        chat.suspend(); session.clear(); ChatReviewProtocol.handler = nil
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: ChatKeyVault(namespace: c.namespace).service] as CFDictionary)
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

final class ChatReviewTests: XCTestCase {
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
        event = try f.chat.decodeMessage(raw, c: f.c); f.chat.messages = [event]
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
        let ring = try XCTUnwrap(ChatKeyVault(namespace: f.c.namespace).load())
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

    @MainActor func testComposerAppearanceAttachments() async throws {
        for (name, dark, reduce, large) in [("light", false, false, false), ("dark", true, false, false), ("opaque", false, true, false), ("accessibility", false, false, true)] {
            let composer = ChatComposer(text: .constant("测试多行输入\n原生 Liquid Glass"), sending: false, connected: true, protocolTitle: "旧安卓兼容", send: {})
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.accessibilityReduceTransparency, reduce)
                .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
                .padding(.vertical, 20).background(Color(uiColor: .systemGroupedBackground))
            let host = UIHostingController(rootView: composer)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: large ? 440 : 220))
            window.rootViewController = host; window.isHidden = false; host.view.frame = window.bounds; host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "chat-composer-" + name; attachment.lifetime = .keepAlways
            add(attachment); XCTAssertNotNil(image.pngData()); window.isHidden = true
        }
    }
}
