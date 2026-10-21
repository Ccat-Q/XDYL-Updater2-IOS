import Foundation
import CryptoKit
import Security

struct ChatPrivateKey: Codable {
    let keyID: String
    let algorithm: String
    let privateData: Data
    let publicKey: String
    var published: ChatPublicKey { ChatPublicKey(keyID: keyID, algorithm: algorithm, publicKey: publicKey) }
}
struct ChatKeyRing: Codable {
    var deviceID: String
    var revision: String
    var keys: [ChatPrivateKey]
    var archiveKeys: [ChatPrivateKey]
    var storeKey: Data
    static func create() throws -> ChatKeyRing {
        ChatKeyRing(deviceID: UUID().uuidString.lowercased(), revision: "0", keys: try ChatCrypto.newKeys(), archiveKeys: [], storeKey: try ChatCrypto.random(32))
    }
    func key(_ id: String) throws -> ChatPrivateKey {
        guard let key = (keys + archiveKeys).first(where: { $0.keyID == id }) else { throw ChatFailure.invalid("此设备缺少解密所需的旧私钥，请从可信设备或加密备份恢复。") }; return key
    }
    func mergingHistory(_ importedKeys: [ChatPrivateKey]) throws -> ChatKeyRing {
        var merged = self
        for imported in importedKeys {
            guard UUID(uuidString: imported.keyID) != nil else { throw ChatFailure.invalid("恢复私钥身份无效。") }
            let pub: String
            switch imported.algorithm {
            case "X25519": pub = (ChatCrypto.xPrefix + (try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: imported.privateData)).publicKey.rawRepresentation).base64EncodedString()
            case "P256": pub = (try P256.KeyAgreement.PrivateKey(rawRepresentation: imported.privateData)).publicKey.derRepresentation.base64EncodedString()
            default: throw ChatFailure.invalid("恢复私钥算法未知。")
            }
            guard imported.publicKey == pub else { throw ChatFailure.invalid("恢复私钥与公钥不匹配。") }
            if let existing = (merged.keys + merged.archiveKeys).first(where: { $0.keyID == imported.keyID }) {
                guard existing.algorithm == imported.algorithm, existing.privateData == imported.privateData, existing.publicKey == imported.publicKey else { throw ChatFailure.invalid("恢复私钥与本机冲突。") }
            } else { merged.archiveKeys.append(imported) }
        }
        return merged
    }
}

enum ChatCrypto {
    static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw ChatFailure.invalid("无法安全生成随机密钥。") }; return Data(bytes)
    }
    static func digest(_ data: Data) -> String { Data(SHA256.hash(data: data)).base64EncodedString() }
    static func legacyID(_ algorithm: String, _ publicKey: String) -> String { "legacy:" + algorithm + ":" + digest(Data(publicKey.utf8)) }
    static func namespace(relay: URL, subject: String) -> String {
        SHA256.hash(data: Data((relay.absoluteString + "\n" + subject).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func json(_ strings: [String]) throws -> Data { try JSONSerialization.data(withJSONObject: strings, options: [.withoutEscapingSlashes]) }
    static func canonical(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
    }
    static func newKeys() throws -> [ChatPrivateKey] {
        let x = Curve25519.KeyAgreement.PrivateKey(), p = P256.KeyAgreement.PrivateKey()
        return [ChatPrivateKey(keyID: UUID().uuidString.lowercased(), algorithm: "X25519", privateData: x.rawRepresentation, publicKey: (xPrefix + x.publicKey.rawRepresentation).base64EncodedString()),
                ChatPrivateKey(keyID: UUID().uuidString.lowercased(), algorithm: "P256", privateData: p.rawRepresentation, publicKey: p.publicKey.derRepresentation.base64EncodedString())]
    }
    static let xPrefix = Data([0x30,0x2a,0x30,0x05,0x06,0x03,0x2b,0x65,0x6e,0x03,0x21,0])
    static func decoded(_ string: String, maximum: Int) throws -> Data {
        guard let data = Data(base64Encoded: string), data.count <= maximum, data.base64EncodedString() == string else { throw ChatFailure.invalid("聊天加密材料无效。") }; return data
    }
    static func shared(privateKey: ChatPrivateKey, remote: String) throws -> SharedSecret {
        let bytes = try decoded(remote, maximum: 1024)
        switch privateKey.algorithm {
        case "X25519":
            guard bytes.count == 44, bytes.starts(with: xPrefix) else { throw ChatFailure.invalid("X25519 公钥格式错误。") }
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey.privateData)
            return try key.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: bytes.dropFirst(12)))
        case "P256":
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey.privateData).sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(derRepresentation: bytes))
        default: throw ChatFailure.invalid("未知聊天算法。")
        }
    }
    static func aad(_ meta: JSONValue) throws -> Data {
        try json(["nu-chat-v2", meta.chatString("sender_subject"), meta.chatString("sender_device_id"), meta.chatString("recipient_subject"), meta.chatString("client_msg_id"), meta.chatString("target_subject"), meta.chatString("target_device_id"), meta.chatString("algorithm"), meta.chatString("sender_key_id"), meta.chatString("recipient_key_id")])
    }
    static func encrypt(_ text: String, key: ChatPrivateKey, remote: String, metadata: JSONValue, nonce: Data? = nil) throws -> (String, String) {
        try ChatValidation.plaintext(text)
        guard try metadata.chatString("algorithm") == key.algorithm else { throw ChatFailure.invalid("聊天算法与本机密钥不匹配。") }
        let associated = try aad(metadata)
        let derived = try shared(privateKey: key, remote: remote).hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(SHA256.hash(data: associated)), sharedInfo: Data("nu-chat-v2".utf8), outputByteCount: 32)
        let sealed = try AES.GCM.seal(Data(text.utf8), using: derived, nonce: try nonce.map { try AES.GCM.Nonce(data: $0) }, authenticating: associated)
        return (Data(sealed.nonce).base64EncodedString(), (sealed.ciphertext + sealed.tag).base64EncodedString())
    }
    static func decrypt(key: ChatPrivateKey, remote: String, metadata: JSONValue, nonce: String, ciphertext: String) throws -> String {
        guard try metadata.chatString("algorithm") == key.algorithm else { throw ChatFailure.invalid("聊天算法与本机密钥不匹配。") }
        let associated = try aad(metadata)
        let derived = try shared(privateKey: key, remote: remote).hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(SHA256.hash(data: associated)), sharedInfo: Data("nu-chat-v2".utf8), outputByteCount: 32)
        let bytes = try decoded(ciphertext, maximum: 16400), iv = try decoded(nonce, maximum: 12)
        guard bytes.count >= 16, iv.count == 12 else { throw ChatFailure.invalid("聊天密文长度错误。") }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: bytes.dropLast(16), tag: bytes.suffix(16))
        let plain = try AES.GCM.open(box, using: derived, authenticating: associated)
        guard let text = String(data: plain, encoding: .utf8), plain.count <= 16384 else { throw ChatFailure.invalid("聊天正文不是有效文字。") }; return text
    }
    static func encryptLegacy(_ text: String, key: ChatPrivateKey, remote: String, nonce: Data? = nil) throws -> String {
        try ChatValidation.plaintext(text)
        let derived = try shared(privateKey: key, remote: remote).hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(repeating: 0, count: 32), sharedInfo: Data("nu-chat-v1".utf8), outputByteCount: 32)
        let sealed = try AES.GCM.seal(Data(text.utf8), using: derived, nonce: try nonce.map { try AES.GCM.Nonce(data: $0) })
        return Data(sealed.nonce).base64EncodedString() + ":" + (sealed.ciphertext + sealed.tag).base64EncodedString()
    }
    static func decryptLegacy(_ cipher: String, key: ChatPrivateKey, remote: String) throws -> String {
        let parts = cipher.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw ChatFailure.invalid("旧协议密文格式错误。") }
        let iv = try decoded(String(parts[0]), maximum: 12), bytes = try decoded(String(parts[1]), maximum: 16400)
        guard iv.count == 12, bytes.count >= 16 else { throw ChatFailure.invalid("旧协议密文长度错误。") }
        let derived = try shared(privateKey: key, remote: remote).hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(repeating: 0, count: 32), sharedInfo: Data("nu-chat-v1".utf8), outputByteCount: 32)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: bytes.dropLast(16), tag: bytes.suffix(16))
        let plain = try AES.GCM.open(box, using: derived)
        guard plain.count <= 16384, let text = String(data: plain, encoding: .utf8) else { throw ChatFailure.invalid("旧协议正文无效。") }; return text
    }
}

struct ChatKeyVault {
    let service: String
    init(namespace: String) { service = "com.ccatq.xdylupdater2.chat." + namespace }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "keyring"] }
    func load() throws -> ChatKeyRing? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ChatFailure.invalid("请解锁设备后再访问聊天密钥。") }
        return try JSONDecoder().decode(ChatKeyRing.self, from: data)
    }
    func save(_ ring: ChatKeyRing) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(ring), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { var item = query; attributes.forEach { item[$0.key] = $0.value }; status = SecItemAdd(item as CFDictionary, nil) }
        guard status == errSecSuccess else { throw ChatFailure.invalid("聊天私钥无法安全保存，已停止登记或发送。") }
    }
}
