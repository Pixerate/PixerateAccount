import Foundation
import Security

public protocol PixerateTokenStore: Sendable {
    func loadToken() -> String?
    func saveToken(_ token: String?)
    func loadSelectedTeamId() -> String?
    func saveSelectedTeamId(_ id: String?)
}

public final class KeychainTokenStore: PixerateTokenStore, @unchecked Sendable {
    private let service: String
    private let account: String
    private let selectedTeamDefaultsKey: String
    private let lock = NSLock()

    public init(
        service: String = "com.pixerate.teams",
        account: String = "api_token",
        selectedTeamDefaultsKey: String = "com.pixerate.teams.selectedTeamId"
    ) {
        self.service = service
        self.account = account
        self.selectedTeamDefaultsKey = selectedTeamDefaultsKey
    }

    public func loadToken() -> String? {
        lock.lock()
        defer { lock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func saveToken(_ token: String?) {
        lock.lock()
        defer { lock.unlock() }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard let token = token, !token.isEmpty, let data = token.data(using: .utf8) else {
            return
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    public func loadSelectedTeamId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return UserDefaults.standard.string(forKey: selectedTeamDefaultsKey)
    }

    public func saveSelectedTeamId(_ id: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let id = id, !id.isEmpty {
            UserDefaults.standard.set(id, forKey: selectedTeamDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedTeamDefaultsKey)
        }
    }
}

public final class InMemoryTokenStore: PixerateTokenStore, @unchecked Sendable {
    private var token: String?
    private var selectedTeamId: String?
    private let lock = NSLock()

    public init(token: String? = nil, selectedTeamId: String? = nil) {
        self.token = token
        self.selectedTeamId = selectedTeamId
    }

    public func loadToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    public func saveToken(_ token: String?) {
        lock.lock()
        defer { lock.unlock() }
        self.token = token
    }

    public func loadSelectedTeamId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return selectedTeamId
    }

    public func saveSelectedTeamId(_ id: String?) {
        lock.lock()
        defer { lock.unlock() }
        self.selectedTeamId = id
    }
}
