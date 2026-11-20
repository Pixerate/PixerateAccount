import Foundation
import Security

// MARK: - HTTP

/// Sends requests to the Pixerate server. Replace it in tests.
public protocol PixerateHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The default transport.
public struct URLSessionTransport: PixerateHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

// MARK: - Customer token storage

/// A minted App Store customer token and when it stops working.
public struct PixerateCustomerSession: Codable, Sendable, Equatable {
    public var token: String
    public var expiresAt: Date?
    public var customer: PixerateAppStoreCustomer

    public init(token: String, expiresAt: Date?, customer: PixerateAppStoreCustomer) {
        self.token = token
        self.expiresAt = expiresAt
        self.customer = customer
    }

    /// Still usable for at least `margin` more seconds.
    func isFresh(at now: Date, margin: TimeInterval = 24 * 60 * 60) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > margin
    }
}

/// Keeps the App Store customer session between launches.
public protocol PixerateCustomerSessionStore: Sendable {
    func load() -> PixerateCustomerSession?
    func save(_ session: PixerateCustomerSession?)
}

/// Keychain storage: service `com.pixerate.store`, account = the app's bundle id.
public final class KeychainCustomerSessionStore: PixerateCustomerSessionStore, @unchecked Sendable {
    private let service: String
    private let account: String
    private let lock = NSLock()

    public init(service: String = "com.pixerate.store", account: String) {
        self.service = service
        self.account = account
    }

    public func load() -> PixerateCustomerSession? {
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
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PixerateCustomerSession.self, from: data)
    }

    public func save(_ session: PixerateCustomerSession?) {
        lock.lock()
        defer { lock.unlock() }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard let session, let data = try? JSONEncoder().encode(session) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// For tests and previews.
public final class InMemoryCustomerSessionStore: PixerateCustomerSessionStore, @unchecked Sendable {
    private var session: PixerateCustomerSession?
    private let lock = NSLock()

    public init(_ session: PixerateCustomerSession? = nil) {
        self.session = session
    }

    public func load() -> PixerateCustomerSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    public func save(_ session: PixerateCustomerSession?) {
        lock.lock()
        defer { lock.unlock() }
        self.session = session
    }
}
