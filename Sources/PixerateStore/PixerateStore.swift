import Foundation
import Observation
import PixerateAccount

/// An app's Pro subscription: bought in the App Store without needing a Pixerate account, or
/// held through a Pixerate account (Pixerate Pro, a complimentary grant).
///
/// Call `start()` once at launch. It works out whether the app came from the App Store,
/// identifies this Apple Account to the server (an *App Store customer*, the same on every
/// device signed in to it), listens for renewals and Family Sharing changes, loads the
/// products and fetches the entitlements. Then read `hasPro`, `proSource` and `supportId`,
/// and send gated API calls through `authorizedRequest(path:method:body:)`.
///
/// Call `accountDidChange()` after signing in to or out of Pixerate.
@MainActor
@Observable
public final class PixerateStore {
    public let configuration: PixerateStoreConfiguration
    /// The Pixerate account, when the app offers sign-in.
    public let account: PixerateAccountClient?

    public private(set) var distribution: PixerateDistribution = .unknown
    /// The app's products, cheapest first. Empty until loaded, and always empty outside the
    /// App Store.
    public private(set) var products: [PixerateStoreProduct] = []
    public private(set) var entitlements: Set<String> = []
    public private(set) var grants: [PixerateEntitlementGrant] = []
    public private(set) var customer: PixerateAppStoreCustomer?
    public private(set) var supportId: String?
    /// Set when the server couldn't be reached and a verified App Store subscription on this
    /// device stands in for it.
    public private(set) var hasOfflinePro = false
    public private(set) var isRefreshing = false
    public private(set) var isPurchasing = false
    /// The last thing that went wrong, for the app to show.
    public var lastError: PixerateStoreError?

    /// The app's Pro is unlocked: its own entitlement or Pixerate Pro, or (offline) a verified
    /// App Store subscription on this device.
    public var hasPro: Bool {
        entitlements.contains(configuration.appEntitlement)
            || entitlements.contains(PixerateEntitlement.pixeratePro)
            || hasOfflinePro
    }

    /// Where Pro comes from, for Settings. `nil` without Pro.
    public var proSource: PixerateProSource? {
        let relevant = grants.filter {
            $0.entitlement == configuration.appEntitlement || $0.entitlement == PixerateEntitlement.pixeratePro
        }
        if let appStore = relevant.first(where: \.isAppStore) {
            return .appStore(familyShared: appStore.isFamilyShared && !relevant.contains { $0.isAppStore && !$0.isFamilyShared })
        }
        if relevant.contains(where: \.isComplimentary) { return .complimentary }
        if entitlements.contains(PixerateEntitlement.pixeratePro) { return .pixeratePro }
        if entitlements.contains(configuration.appEntitlement) { return .plan }
        if hasOfflinePro { return .offline }
        return nil
    }

    /// Purchases can be offered.
    public var canPurchase: Bool { distribution == .appStore }

    @ObservationIgnored private let storeKit: any PixerateStoreKitClient
    @ObservationIgnored private let transport: any PixerateHTTPTransport
    @ObservationIgnored private let sessionStore: any PixerateCustomerSessionStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var session: PixerateCustomerSession?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    public init(
        configuration: PixerateStoreConfiguration,
        account: PixerateAccountClient? = nil,
        storeKit: any PixerateStoreKitClient = LiveStoreKitClient(),
        transport: any PixerateHTTPTransport = URLSessionTransport(),
        sessionStore: (any PixerateCustomerSessionStore)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.account = account
        self.storeKit = storeKit
        self.transport = transport
        self.sessionStore = sessionStore ?? KeychainCustomerSessionStore(account: configuration.bundleIdentifier)
        self.now = now
        self.session = self.sessionStore.load()
        self.customer = session?.customer
        self.supportId = session?.customer.supportId
    }

    // MARK: - Launch

    /// Sets everything up. Safe to call more than once; later calls only refresh.
    public func start() async {
        guard !started else {
            await refreshEntitlements()
            return
        }
        started = true
        distribution = await resolveDistribution()

        if distribution == .appStore {
            listenForUpdates()
            for transaction in await storeKit.unfinishedTransactions() {
                await handle(transaction, finish: true)
            }
            await loadProducts()
        }
        await refreshEntitlements()
    }

    /// Call after signing in to or out of Pixerate, or changing team.
    public func accountDidChange() async {
        await refreshEntitlements()
    }

    private func resolveDistribution() async -> PixerateDistribution {
        switch configuration.distributionMode {
        case .fixed(let distribution):
            if distribution == .appStore { await ensureCustomerSession() }
            return distribution
        case .automatic:
            #if os(macOS)
            // A downloaded Mac app has no App Store receipt. Asking StoreKit anyway can show an
            // App Store sign-in prompt, so don't.
            let receipt = Bundle.main.bundleURL.appendingPathComponent("Contents/_MASReceipt/receipt")
            guard FileManager.default.fileExists(atPath: receipt.path) else { return .direct }
            #endif
            guard await storeKit.appTransactionJWS() != nil else { return .direct }
            await ensureCustomerSession()
            return .appStore
        }
    }

    private func listenForUpdates() {
        guard updatesTask == nil else { return }
        let stream = storeKit.transactionUpdates()
        updatesTask = Task { [weak self] in
            for await transaction in stream {
                guard let self else { return }
                await self.handle(transaction, finish: true)
            }
        }
    }

    private func loadProducts() async {
        do {
            products = try await storeKit.products(for: configuration.productIds).sorted { $0.price < $1.price }
        } catch {
            lastError = .network(error.localizedDescription)
        }
    }

    // MARK: - Customer session

    /// Mints (or reuses) the App Store customer token. Returns whether one is available.
    @discardableResult
    private func ensureCustomerSession(forceNew: Bool = false) async -> Bool {
        if !forceNew, let session, session.isFresh(at: now()) { return true }
        guard let jws = await storeKit.appTransactionJWS() else { return session != nil }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["appTransaction": jws])
            let (data, http) = try await transport.send(request(PixerateStoreAPI.appStoreSessionPath, method: "POST", body: body))
            guard (200..<300).contains(http.statusCode) else {
                lastError = rejection(http.statusCode, data)
                return session != nil
            }
            let decoded = try JSONDecoder.pixerateStore.decode(AppStoreSessionResponse.self, from: data)
            let minted = PixerateCustomerSession(token: decoded.token, expiresAt: decoded.expiresAt, customer: decoded.customer)
            session = minted
            sessionStore.save(minted)
            customer = minted.customer
            if supportId == nil { supportId = minted.customer.supportId }
            return true
        } catch {
            lastError = .network(error.localizedDescription)
            return session != nil
        }
    }

    // MARK: - Purchases

    /// Buys a product. Returns `true` once the server has accepted it.
    @discardableResult
    public func buy(_ productId: String) async -> Bool {
        guard canPurchase else {
            lastError = .notAppStoreBuild
            return false
        }
        lastError = nil
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await storeKit.purchase(productId: productId) {
            case .purchased(let transaction):
                return await handle(transaction, finish: true)
            case .pending, .cancelled:
                return false
            }
        } catch {
            lastError = .network(error.localizedDescription)
            return false
        }
    }

    /// Restore Purchases: syncs with the App Store and sends every current subscription to the
    /// server. Returns whether Pro is unlocked afterwards.
    @discardableResult
    public func restore() async -> Bool {
        guard canPurchase else {
            lastError = .notAppStoreBuild
            return false
        }
        lastError = nil
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            try await storeKit.sync()
        } catch {
            lastError = .network(error.localizedDescription)
        }
        await ensureCustomerSession()
        for transaction in await storeKit.currentEntitlements() where configuration.productIds.contains(transaction.productId) {
            await handle(transaction, finish: false, refresh: false)
        }
        await refreshEntitlements()
        return hasPro
    }

    /// Sends one of the app's verified transactions to the server, then finishes it, but only
    /// after the server accepted it, so StoreKit delivers it again otherwise.
    @discardableResult
    private func handle(_ transaction: PixerateStoreTransaction, finish: Bool, refresh: Bool = true) async -> Bool {
        guard configuration.productIds.contains(transaction.productId) else { return false }
        guard await ensureCustomerSession(), let session else {
            lastError = .unauthenticated
            return false
        }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["signedTransactionInfo": transaction.jwsRepresentation])
            var req = request(PixerateStoreAPI.verifyPath, method: "POST", body: body)
            req.setValue(session.token, forHTTPHeaderField: PixerateStoreAPI.customerHeader)
            let (data, http) = try await transport.send(req)
            guard (200..<300).contains(http.statusCode) else {
                lastError = rejection(http.statusCode, data)
                return false
            }
            if finish { await transaction.finish() }
            if let payload = try? JSONDecoder.pixerateStore.decode(PixerateEntitlements.self, from: data),
               !payload.entitlements.isEmpty || !payload.grants.isEmpty {
                apply(payload)
            } else if refresh {
                await refreshEntitlements()
            }
            return true
        } catch {
            lastError = .network(error.localizedDescription)
            return false
        }
    }

    // MARK: - Entitlements

    /// Fetches the entitlements for this App Store customer and the signed-in account.
    public func refreshEntitlements() async {
        guard customerToken != nil || accountToken != nil else {
            apply(PixerateEntitlements(supportId: session?.customer.supportId, customer: session?.customer))
            // In the App Store build, no customer token means minting it failed (usually no
            // network), so a verified subscription on this device stands in.
            await applyOfflineFallback(serverReachable: distribution != .appStore)
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            var (data, http) = try await transport.send(authorizedRequestUnchecked(PixerateStoreAPI.entitlementsPath, method: "GET"))
            if http.statusCode == 401, distribution == .appStore, await ensureCustomerSession(forceNew: true) {
                (data, http) = try await transport.send(authorizedRequestUnchecked(PixerateStoreAPI.entitlementsPath, method: "GET"))
            }
            guard (200..<300).contains(http.statusCode) else {
                lastError = rejection(http.statusCode, data)
                await applyOfflineFallback(serverReachable: http.statusCode < 500)
                return
            }
            apply(try JSONDecoder.pixerateStore.decode(PixerateEntitlements.self, from: data))
            hasOfflinePro = false
        } catch {
            lastError = .network(error.localizedDescription)
            await applyOfflineFallback(serverReachable: false)
        }
    }

    private func apply(_ payload: PixerateEntitlements) {
        entitlements = Set(payload.entitlements)
        grants = payload.grants
        if let customer = payload.customer {
            self.customer = customer
            if var session, session.customer != customer {
                session.customer = customer
                self.session = session
                sessionStore.save(session)
            }
        }
        supportId = payload.supportId ?? customer?.supportId
    }

    /// Without the server, a verified, active App Store subscription on this device keeps Pro
    /// showing as unlocked. Server features still need the network.
    private func applyOfflineFallback(serverReachable: Bool) async {
        guard !serverReachable, distribution == .appStore else {
            hasOfflinePro = false
            return
        }
        let date = now()
        hasOfflinePro = await storeKit.currentEntitlements().contains {
            configuration.productIds.contains($0.productId) && $0.isActive(at: date)
        }
    }

    // MARK: - Linking to a Pixerate account

    /// Links this App Store customer to the signed-in Pixerate account, so its purchases show
    /// on the web. Throws `.linkedElsewhere` when another account has it; ask, then call again
    /// with `confirmMove: true`.
    public func link(confirmMove: Bool = false) async throws {
        guard customerToken != nil, accountToken != nil else { throw PixerateStoreError.unauthenticated }
        var body: [String: Any] = [:]
        if confirmMove { body["confirmMove"] = true }
        try await sendLink(method: "POST", body: JSONSerialization.data(withJSONObject: body))
    }

    /// Unlinks this App Store customer from the signed-in Pixerate account.
    public func unlink() async throws {
        guard customerToken != nil, accountToken != nil else { throw PixerateStoreError.unauthenticated }
        try await sendLink(method: "DELETE", body: nil)
    }

    private func sendLink(method: String, body: Data?) async throws {
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport.send(authorizedRequestUnchecked(PixerateStoreAPI.linkPath, method: method, body: body))
        } catch {
            throw PixerateStoreError.network(error.localizedDescription)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw rejection(http.statusCode, data)
        }
        struct LinkResponse: Decodable { var customer: PixerateAppStoreCustomer? }
        if let linked = try? JSONDecoder.pixerateStore.decode(LinkResponse.self, from: data).customer {
            customer = linked
        }
        await refreshEntitlements()
    }

    // MARK: - Requests

    /// A request to the Pixerate server carrying the App Store customer token and, when signed
    /// in, the account's key, so gated endpoints see both. Throws `.unauthenticated` with
    /// neither.
    public func authorizedRequest(path: String, method: String = "POST", body: Data? = nil) throws -> URLRequest {
        guard customerToken != nil || accountToken != nil else { throw PixerateStoreError.unauthenticated }
        return authorizedRequestUnchecked(path, method: method, body: body)
    }

    private var customerToken: String? { session?.token }

    private var accountToken: String? {
        guard let token = account?.token, !token.isEmpty else { return nil }
        return token
    }

    private func authorizedRequestUnchecked(_ path: String, method: String, body: Data? = nil) -> URLRequest {
        var req = request(path, method: method, body: body)
        if let customerToken { req.setValue(customerToken, forHTTPHeaderField: PixerateStoreAPI.customerHeader) }
        if let accountToken { req.setValue("Bearer \(accountToken)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func request(_ path: String, method: String, body: Data? = nil) -> URLRequest {
        let base = configuration.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var req = URLRequest(url: URL(string: base + (path.hasPrefix("/") ? path : "/" + path))!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        return req
    }

    private func rejection(_ status: Int, _ data: Data) -> PixerateStoreError {
        let body = try? JSONDecoder().decode(ServerErrorBody.self, from: data)
        switch (status, body?.code) {
        case (409, "linked_elsewhere"): return .linkedElsewhere
        case (429, "relink_limited"): return .relinkLimited
        case (401, _) where body?.code == nil || body?.code == "unauthenticated": return .unauthenticated
        default: return .serverRejected(status: status, code: body?.code, message: body?.error)
        }
    }

    // MARK: - Previews

    /// For previews and screenshots: fixed state, no StoreKit or network.
    public static func preview(
        configuration: PixerateStoreConfiguration = .init(productIds: [], appEntitlement: PixerateEntitlement.swashPro, bundleIdentifier: "preview"),
        distribution: PixerateDistribution = .appStore,
        products: [PixerateStoreProduct] = [],
        entitlements: PixerateEntitlements = PixerateEntitlements()
    ) -> PixerateStore {
        let store = PixerateStore(
            configuration: configuration,
            storeKit: PreviewStoreKitClient(),
            transport: PreviewTransport(),
            sessionStore: InMemoryCustomerSessionStore()
        )
        store.started = true
        store.distribution = distribution
        store.products = products
        store.apply(entitlements)
        return store
    }
}

/// Does nothing; for `PixerateStore.preview`.
private struct PreviewStoreKitClient: PixerateStoreKitClient {
    func appTransactionJWS() async -> String? { nil }
    func products(for ids: [String]) async throws -> [PixerateStoreProduct] { [] }
    func purchase(productId: String) async throws -> PixeratePurchaseOutcome { .cancelled }
    func sync() async throws {}
    func currentEntitlements() async -> [PixerateStoreTransaction] { [] }
    func unfinishedTransactions() async -> [PixerateStoreTransaction] { [] }
    func transactionUpdates() -> AsyncStream<PixerateStoreTransaction> { AsyncStream { $0.finish() } }
}

/// Never reaches a server; for `PixerateStore.preview`.
private struct PreviewTransport: PixerateHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}
