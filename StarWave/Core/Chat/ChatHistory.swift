import Foundation
import CryptoKit

struct ChatHistoryArchive: Codable {
    let format: String
    let owner: String
    let relay: String
    let messages: [ChatMessage]
    let peers: [ChatPeer]
    let privateKeys: [ChatPrivateKey]
}
struct ChatPreparedPack: Codable, Identifiable {
    let id: String
    let kind: String
    let root: String
    let recoveryKeyID: String
    let manifest: String
    let digests: [String]
    let bytes: Int
    let sourcePublicKey: String?
    let approvalProof: String?
}
struct ChatPairing: Codable {
    let version: Int
    let relay: String
    let owner: String
    let packID: String
    let targetDevice: String
    let targetPublicKey: String
    let secret: String
    let expiresAt: Int64
}
struct ChatTransferTarget: Codable {
    let pairing: ChatPairing
    let key: ChatPrivateKey
}

enum ChatHistoryCrypto {
    static let chunkBytes = 1048576
    static func context(_ owner: String, _ pack: String, _ kind: String) -> [String] { ["nu-chat-history/1", owner, pack, kind] }
    static func cipher(root: String, salt: Data, owner: String, pack: String, kind: String) throws -> SymmetricKey {
        let bytes = try ChatCrypto.decoded(root, maximum: 32)
        guard bytes.count == 32, salt.count == 32 else { throw ChatFailure.invalid("恢复密钥或盐长度错误。") }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes), salt: salt, info: try ChatCrypto.json(context(owner, pack, kind)), outputByteCount: 32)
    }
    static func aad(owner: String, pack: String, kind: String, index: Int?) throws -> Data {
        var values: [Any] = context(owner, pack, kind)
        if let index { values += ["chunk", index] } else { values += ["manifest"] }
        return try JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes])
    }
    static func seal(_ data: Data, key: SymmetricKey, aad: Data) throws -> Data {
        guard let bytes = try AES.GCM.seal(data, using: key, authenticating: aad).combined else { throw ChatFailure.storage }; return bytes
    }
    static func open(_ data: Data, key: SymmetricKey, aad: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: aad)
    }
    static func pairingContext(_ p: ChatPairing, sourceDevice: String, sourcePublicKey: String) -> JSONValue {
        .chatObject(["owner": p.owner, "pack_id": p.packID, "source_device": sourceDevice, "target_device": p.targetDevice, "source_public_key": sourcePublicKey, "target_public_key": p.targetPublicKey])
    }
    static func proof(_ p: ChatPairing, sourceDevice: String, sourcePublicKey: String) throws -> String {
        let secret = try ChatCrypto.decoded(p.secret, maximum: 32); guard secret.count == 32 else { throw ChatFailure.invalid("迁移码无效。") }
        return Data(HMAC<SHA256>.authenticationCode(for: try ChatCrypto.canonical(pairingContext(p, sourceDevice: sourceDevice, sourcePublicKey: sourcePublicKey)), using: SymmetricKey(data: secret))).base64EncodedString()
    }
    static func transferRoot(_ p: ChatPairing, key: ChatPrivateKey, peerPublicKey: String, sourceDevice: String, sourcePublicKey: String, proof: String) throws -> String {
        let secret = try ChatCrypto.decoded(p.secret, maximum: 32), mac = try ChatCrypto.decoded(proof, maximum: 32)
        let context = try ChatCrypto.canonical(pairingContext(p, sourceDevice: sourceDevice, sourcePublicKey: sourcePublicKey))
        guard secret.count == 32, HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: context, using: SymmetricKey(data: secret)), let contextString = String(data: context, encoding: .utf8) else { throw ChatFailure.invalid("迁移批准证明不匹配，已停止恢复。") }
        let root = try ChatCrypto.shared(privateKey: key, remote: peerPublicKey).hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(SHA256.hash(data: secret)), sharedInfo: Data(("nu-chat-transfer/1:" + contextString).utf8), outputByteCount: 32)
        return root.withUnsafeBytes { Data($0).base64EncodedString() }
    }
}

extension ChatController {
    func requireHistory(_ feature: String) throws {
        guard features.contains(feature) else { throw ChatFailure.service(503, "HISTORY_NOT_CONFIGURED", nil) }
    }
    func historyFilters() async throws -> (String, [JSONValue]) {
        var cursor: String?, revision: String?, filters: [JSONValue] = []
        repeat {
            var q = [URLQueryItem(name: "limit", value: "500")]; if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
            let result = try await json("/chat/v2/history/filters", query: q), nextRevision = try result.chatSequence("revision")
            if let revision, revision != nextRevision { throw ChatFailure.service(409, "FILTER_CHANGED", nil) }
            revision = nextRevision; filters += try result["filters"].chatArray()
            cursor = result["has_more"]?.boolValue == true ? try result.chatString("next_cursor") : nil
        } while cursor != nil
        return (revision ?? "0", filters)
    }
    func preparedHistory() async throws -> [ChatPreparedPack] { let c = try await connect(); return try await c.store.all(ChatPreparedPack.self, kind: "preparedHistory") }
    func prepareBackup() async throws -> ChatPreparedPack {
        try requireHistory("encrypted_backups")
        let c = try await connect(), root = try ChatCrypto.random(32).base64EncodedString()
        return try await prepareHistory(c, id: UUID().uuidString.lowercased(), kind: "backup", root: root)
    }
    private func prepareHistory(_ c: ChatConnection, id: String, kind: String, root: String, sourcePublicKey: String? = nil, proof: String? = nil) async throws -> ChatPreparedPack {
        let filters = try await historyFilters()
        let history = try await c.store.all(ChatMessage.self, kind: "message").filter { ChatHistoryFilter.allows($0, filters: filters.1) }
        let archive = ChatHistoryArchive(format: "nu-chat-records/1", owner: c.subject, relay: c.transport.relay.absoluteString, messages: history,
                                         peers: peers, privateKeys: c.ring.keys + c.ring.archiveKeys)
        let data = try JSONEncoder().encode(archive)
        guard data.count < 100 * 1048576 - 4096 else { throw ChatFailure.invalid("历史超过本客户端单包 100 MiB 限制，请先清理或分批保留历史。") }
        let salt = try ChatCrypto.random(32), key = try ChatHistoryCrypto.cipher(root: root, salt: salt, owner: c.subject, pack: id, kind: kind)
        let length = ChatHistoryCrypto.chunkBytes - 28
        var digests: [String] = [], byteCount = 0
        for offset in stride(from: 0, to: data.count, by: length) {
            let index = digests.count
            let chunk = try ChatHistoryCrypto.seal(data.subdata(in: offset..<min(data.count, offset + length)), key: key, aad: ChatHistoryCrypto.aad(owner: c.subject, pack: id, kind: kind, index: index))
            try current(c); try await c.store.put(chunk, kind: "historyChunk", id: id + ":\(index)")
            digests.append(ChatCrypto.digest(chunk)); byteCount += chunk.count
        }
        let manifest = JSONValue.object(["format": .string("nu-chat-records/1"), "records": .number(Double(history.count)),
            "chunks": .array(digests.enumerated().map { .object(["index": .number(Double($0.offset)), "digest": .string($0.element)]) })])
        let sealed = try ChatHistoryCrypto.seal(ChatCrypto.canonical(manifest), key: key, aad: ChatHistoryCrypto.aad(owner: c.subject, pack: id, kind: kind, index: nil))
        let wrapper = JSONValue.chatObject(["format": "nu-chat-history/1", "salt": salt.base64EncodedString(), "sealed_manifest": sealed.base64EncodedString()])
        guard let manifestString = String(data: try ChatCrypto.canonical(wrapper), encoding: .utf8) else { throw ChatFailure.storage }
        let prepared = ChatPreparedPack(id: id, kind: kind, root: root, recoveryKeyID: UUID().uuidString.lowercased(), manifest: manifestString, digests: digests, bytes: byteCount, sourcePublicKey: sourcePublicKey, approvalProof: proof)
        try current(c); try await c.store.put(prepared, kind: "preparedHistory", id: id)
        return prepared
    }
    func uploadBackup(_ prepared: ChatPreparedPack) async throws {
        try requireHistory("encrypted_backups"); guard prepared.kind == "backup" else { throw ChatFailure.invalid("恢复包类型不匹配。") }
        let store = try localStorage()
        guard try await store.get(Bool.self, kind: "backupKeySaved", id: prepared.id) == true else { throw ChatFailure.invalid("请先查看并明确确认已安全保存此备份的恢复密钥，再上传或续传。") }
        _ = try await json("/chat/v2/history/backups", method: "POST", body: .object(["pack_id": .string(prepared.id), "expected_bytes": .number(Double(prepared.bytes)), "chunk_count": .number(Double(prepared.digests.count)), "recovery_key_id": .string(prepared.recoveryKeyID)]))
        try await uploadHistory(prepared)
    }
    func confirmBackupKeySaved(_ id: String) async throws {
        let store = try localStorage()
        guard let pack = try await store.get(ChatPreparedPack.self, kind: "preparedHistory", id: id), pack.kind == "backup" else { throw ChatFailure.invalid("本机没有此备份的恢复密钥。") }
        try await store.put(true, kind: "backupKeySaved", id: id)
    }
    private func uploadHistory(_ p: ChatPreparedPack) async throws {
        let c = try await connect(), base = "/chat/v2/history/" + (p.kind == "backup" ? "backups/" : "transfers/") + p.id
        let pack = try await json(base)
        if pack["state"]?.stringValue == "ready" {
            guard pack["manifest"]?.stringValue == p.manifest else { throw ChatFailure.invalid("已完成包的密封清单与本机不同，不能覆盖。") }; return
        }
        let existing = try pack["chunks"].chatArray()
        for index in p.digests.indices {
            if let old = existing.first(where: { $0["chunk_index"]?.integer == index }), old["state"]?.stringValue == "ready", old["digest"]?.stringValue == p.digests[index] { continue }
            guard let bytes = try await c.store.get(Data.self, kind: "historyChunk", id: p.id + ":\(index)"), ChatCrypto.digest(bytes) == p.digests[index] else { throw ChatFailure.invalid("本机缺少原始加密分块，不能重新加密后冒充断点续传。") }
            try current(c); _ = try await c.transport.binary(base + "/chunks/\(index)", token: c.token, method: "PUT", bytes: bytes)
        }
        try current(c)
        _ = try await json(base + "/complete", method: "POST", body: .chatObject(["expected_revision": try pack.chatSequence("revision"), "manifest": p.manifest]))
    }
    func beginTransfer() async throws -> ChatPairing {
        try requireHistory("device_history_transfer")
        let c = try await connect(), key = try ChatCrypto.newKeys()[0]
        let id = UUID().uuidString.lowercased()
        let result = try await json("/chat/v2/history/transfers", method: "POST", body: .chatObject(["pack_id": id, "target_public_key": key.publicKey]))
        let pairing = ChatPairing(version: 1, relay: c.transport.relay.absoluteString, owner: c.subject, packID: id, targetDevice: c.ring.deviceID,
                                  targetPublicKey: key.publicKey, secret: try ChatCrypto.random(32).base64EncodedString(), expiresAt: try result.chatInt64("approval_expires_at_ms"))
        try await c.store.put(ChatTransferTarget(pairing: pairing, key: key), kind: "transferTarget", id: id); try current(c)
        return pairing
    }
    func approveTransfer(_ raw: String) async throws {
        try requireHistory("device_history_transfer")
        let pairing = try JSONDecoder().decode(ChatPairing.self, from: Data(raw.utf8)), c = try await connect()
        guard pairing.version == 1, pairing.owner == c.subject, pairing.relay == c.transport.relay.absoluteString, pairing.expiresAt > Self.now,
              pairing.targetDevice != c.ring.deviceID, UUID(uuidString: pairing.packID) != nil else { throw ChatFailure.invalid("迁移码账号、主机、设备或有效期不匹配。") }
        let pack = try await json("/chat/v2/history/transfers/\(pairing.packID)")
        guard pack["target_public_key"]?.stringValue == pairing.targetPublicKey, pack["target_device"]?.stringValue == pairing.targetDevice else { throw ChatFailure.invalid("云端迁移请求与二维码不一致。") }
        let source = try ChatCrypto.newKeys()[0], proof = try ChatHistoryCrypto.proof(pairing, sourceDevice: c.ring.deviceID, sourcePublicKey: source.publicKey)
        let root = try ChatHistoryCrypto.transferRoot(pairing, key: source, peerPublicKey: pairing.targetPublicKey, sourceDevice: c.ring.deviceID, sourcePublicKey: source.publicKey, proof: proof)
        let prepared = try await prepareHistory(c, id: pairing.packID, kind: "transfer", root: root, sourcePublicKey: source.publicKey, proof: proof)
        _ = try await json("/chat/v2/history/transfers/\(pairing.packID)/approve", method: "POST", body: .object(["expected_revision": pack["revision"] ?? .string("1"), "expected_bytes": .number(Double(prepared.bytes)), "chunk_count": .number(Double(prepared.digests.count)), "source_public_key": .string(source.publicKey), "approval_proof": .string(proof)]))
        try await uploadHistory(prepared)
    }
    func resumePrepared(_ pack: ChatPreparedPack) async throws {
        if pack.kind == "backup" { try await uploadBackup(pack) }
        else {
            try requireHistory("device_history_transfer")
            let state = try await json("/chat/v2/history/transfers/\(pack.id)")
            if state["state"]?.stringValue == "awaiting_approval", let pub = pack.sourcePublicKey, let proof = pack.approvalProof {
                _ = try await json("/chat/v2/history/transfers/\(pack.id)/approve", method: "POST", body: .object(["expected_revision": state["revision"] ?? .string("1"), "expected_bytes": .number(Double(pack.bytes)), "chunk_count": .number(Double(pack.digests.count)), "source_public_key": .string(pub), "approval_proof": .string(proof)]))
            }
            try await uploadHistory(pack)
        }
    }
    func restoreBackup(id: String, recoveryKey: String) async throws {
        try requireHistory("encrypted_backups"); guard UUID(uuidString: id) != nil else { throw ChatFailure.invalid("恢复包 ID 无效。") }
        try await restoreHistory(id: id, kind: "backup", root: recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func receiveTransfer(id: String) async throws {
        try requireHistory("device_history_transfer"); let c = try await connect()
        guard let target = try await c.store.get(ChatTransferTarget.self, kind: "transferTarget", id: id) else { throw ChatFailure.invalid("本机没有此迁移请求的临时私钥。") }
        let pack = try await json("/chat/v2/history/transfers/\(id)")
        let source = try pack.chatString("source_public_key"), device = try pack.chatString("source_device"), proof = try pack.chatString("approval_proof")
        let root = try ChatHistoryCrypto.transferRoot(target.pairing, key: target.key, peerPublicKey: source, sourceDevice: device, sourcePublicKey: source, proof: proof)
        try await restoreHistory(id: id, kind: "transfer", root: root)
    }
    private func restoreHistory(id: String, kind: String, root: String) async throws {
        let c = try await connect(), base = "/chat/v2/history/" + (kind == "backup" ? "backups/" : "transfers/") + id
        let pack = try await json(base)
        guard pack["state"]?.stringValue == "ready", let manifestText = pack["manifest"]?.stringValue else { throw ChatFailure.invalid("恢复包尚未就绪。") }
        let wrapper = try JSONDecoder().decode(JSONValue.self, from: Data(manifestText.utf8))
        guard wrapper["format"]?.stringValue == "nu-chat-history/1" else { throw ChatFailure.invalid("恢复包格式不支持。") }
        let salt = try ChatCrypto.decoded(wrapper.chatString("salt"), maximum: 32)
        let key = try ChatHistoryCrypto.cipher(root: root, salt: salt, owner: c.subject, pack: id, kind: kind)
        let sealedManifest = try ChatCrypto.decoded(wrapper.chatString("sealed_manifest"), maximum: 49152)
        let manifest = try JSONDecoder().decode(JSONValue.self, from: ChatHistoryCrypto.open(sealedManifest, key: key, aad: ChatHistoryCrypto.aad(owner: c.subject, pack: id, kind: kind, index: nil)))
        let chunks = try manifest["chunks"].chatArray()
        guard !chunks.isEmpty, chunks.count <= 100, manifest["format"]?.stringValue == "nu-chat-records/1" else { throw ChatFailure.invalid("恢复清单无效或超过容量限制。") }
        var plain = Data()
        for (index, chunk) in chunks.enumerated() {
            guard chunk["index"]?.integer == index else { throw ChatFailure.invalid("恢复分块顺序错误。") }
            let bytes = try await c.transport.binary(base + "/chunks/\(index)", token: c.token)
            try current(c); guard ChatCrypto.digest(bytes) == chunk["digest"]?.stringValue else { throw ChatFailure.invalid("分块与密封清单不一致。") }
            plain += try ChatHistoryCrypto.open(bytes, key: key, aad: ChatHistoryCrypto.aad(owner: c.subject, pack: id, kind: kind, index: index))
            guard plain.count <= 100 * 1048576 else { throw ChatFailure.invalid("恢复历史超过容量限制。") }
        }
        let archive = try JSONDecoder().decode(ChatHistoryArchive.self, from: plain)
        guard archive.format == "nu-chat-records/1", archive.owner == c.subject, archive.relay == c.transport.relay.absoluteString else { throw ChatFailure.invalid("恢复历史属于其他账号或中继。") }
        for m in archive.messages {
            guard UUID(uuidString: m.id) != nil, UUID(uuidString: m.conversationID) != nil, (m.sender == c.subject || m.recipient == c.subject),
                  let sequence = Int64(m.sequence), sequence >= 0, m.peerSubject == (m.sender == c.subject ? m.recipient : m.sender), (m.text?.utf8.count ?? 0) <= 16384 else { throw ChatFailure.invalid("恢复记录身份或顺序号错误。") }
        }
        let filters = try await historyFilters()
        try await localWrite(c) {
        // Stage in memory until BOTH reads succeed. No partial history can be
        // left behind if the final filter fetch fails.
        let latest = try await historyFilters(); try current(c)
        let vault = ChatKeyVault(namespace: c.namespace)
        guard let currentRing = try vault.load(), currentRing.deviceID == c.ring.deviceID else { throw CancellationError() }
        let ring = try currentRing.mergingHistory(archive.privateKeys)
        try vault.save(ring)
        try await c.store.mergeRestored(archive.messages, filters: filters.1 + latest.1)
        try current(c)
        if var live = connection, live.ticket == c.ticket { live.ring = ring; connection = live }
        for peer in archive.peers where !peers.contains(where: { $0.subject == peer.subject }) {
            try await c.store.put(peer, kind: "peer", id: peer.subject); try current(c); peers.append(peer)
        }
        try current(c); messages = try await c.store.all(ChatMessage.self, kind: "message")
        if kind == "transfer" {
            _ = try await json(base + "/ack", method: "POST", body: .chatObject(["expected_revision": try pack.chatSequence("revision"), "filter_revision": latest.0]))
            try await c.store.remove(kind: "transferTarget", id: id)
        }
        }
        // No send, sync cursor reset, unread increment, or message receipt here.
    }
}
