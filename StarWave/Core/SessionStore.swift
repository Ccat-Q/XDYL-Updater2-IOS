import Foundation
import Combine
import Security

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var accessToken: String?
    @Published private(set) var refreshToken: String?
    @Published private(set) var username: String?

    private let keychain = KeychainStore(service: "com.ccatq.xdylupdater2.session")

    init() {
        accessToken = keychain.read("accessToken")
        refreshToken = keychain.read("refreshToken")
        username = keychain.read("username")
    }

    var isAuthenticated: Bool { !(accessToken ?? "").isEmpty }

    func save(_ tokens: AuthTokens) {
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken
        username = tokens.username
        keychain.write(tokens.accessToken, key: "accessToken")
        keychain.write(tokens.refreshToken, key: "refreshToken")
        keychain.write(tokens.username, key: "username")
    }

    func clear() {
        accessToken = nil
        refreshToken = nil
        username = nil
        ["accessToken", "refreshToken", "username"].forEach(keychain.delete)
    }
}

private struct KeychainStore {
    let service: String

    func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String?, key: String) {
        guard let value else { delete(key); return }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
