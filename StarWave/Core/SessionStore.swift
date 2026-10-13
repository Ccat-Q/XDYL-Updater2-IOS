import Foundation
import Combine
import Security

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var accessToken: String?
    @Published private(set) var refreshToken: String?
    @Published private(set) var username: String?
    private(set) var generation = UUID()

    private let keychain: KeychainStore

    init(keychainService: String = "com.ccatq.xdylupdater2.session") {
        keychain = KeychainStore(service: keychainService)
        accessToken = keychain.read("accessToken")
        refreshToken = keychain.read("refreshToken")
        username = keychain.read("username")
    }

    var isAuthenticated: Bool { !(accessToken ?? "").isEmpty }

    /// A new login always changes the session identity; refreshing the same
    /// identity keeps its generation so concurrent authenticated reads can retry.
    func save(_ tokens: AuthTokens, isRefresh: Bool = false) {
        if !isRefresh { generation = UUID() }
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken ?? (isRefresh ? refreshToken : nil)
        username = tokens.username ?? (isRefresh ? username : nil)
        keychain.write(tokens.accessToken, key: "accessToken")
        keychain.write(refreshToken, key: "refreshToken")
        keychain.write(username, key: "username")
    }

    func clear() {
        generation = UUID()
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
