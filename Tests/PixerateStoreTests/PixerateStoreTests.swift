import Foundation
import PixerateAccount
@testable import PixerateStore
import StoreKitTest
import XCTest

// MARK: - Fakes

/// Records requests and answers them from a handler.
private final class MockTransport: PixerateHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var handler: @Sendable (URLRequest) throws -> (Int, String)

    init(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, String)) {
        self.handler = handler
    }

    var requests: [URLRequest] { lock.withLock { _requests } }
    func requests(to path: String) -> [URLRequest] { requests.filter { $0.url?.path == path } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let (status, body) = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

/// A scripted StoreKit.
private final class FakeStoreKit: PixerateStoreKitClient, @unchecked Sendable {
    private let lock = NSLock()
    var appTransaction: String? = "app-transaction-jws"
    var available: [PixerateStoreProduct] = []
    var outcome: PixeratePurchaseOutcome = .cancelled
    var current: [PixerateStoreTransaction] = []
    var unfinished: [PixerateStoreTransaction] = []
    private(set) var events: [String] = []
    private(set) var appTransactionCalls = 0

    func record(_ event: String) { lock.withLock { events.append(event) } }

    func appTransactionJWS() async -> String? {
        lock.withLock { appTransactionCalls += 1 }
        return appTransaction
    }
    func products(for ids: [String]) async throws -> [PixerateStoreProduct] {
        record("products")
        return available.filter { ids.contains($0.id) }
    }
    func purchase(productId: String) async throws -> PixeratePurchaseOutcome {
        record("purchase \(productId)")
        return outcome
    }
    func sync() async throws { record("sync") }
    func currentEntitlements() async -> [PixerateStoreTransaction] { current }
    func unfinishedTransactions() async -> [PixerateStoreTransaction] { unfinished }
    func transactionUpdates() -> AsyncStream<PixerateStoreTransaction> { AsyncStream { _ in } }

    func transaction(_ productId: String, id: UInt64 = 1, expires: Date? = nil, familyShared: Bool = false) -> PixerateStoreTransaction {
        PixerateStoreTransaction(
            id: id,
            originalId: id,
            productId: productId,
            jwsRepresentation: "tx-jws-\(id)",
            expirationDate: expires,
            isFamilyShared: familyShared,
            finish: { [weak self] in self?.record("finish \(id)") }
        )
    }
}

private let monthly = "com.pixerate.test.pro.monthly"
private let yearly = "com.pixerate.test.pro.yearly"

private let sessionJSON = """
{"token":"pix_asc_token","expiresAt":"2099-01-01T00:00:00.000Z","customer":{"id":"asc_1","supportId":"K7QM-4XRT","linkedUserId":null}}
"""

private func entitlementsJSON(_ entitlements: [String], source: String = "app_store", ownership: String? = "PURCHASED") -> String {
    let grants = entitlements.map {
        "{\"entitlement\":\"\($0)\",\"source\":\"\(source)\",\"via\":\"customer\"\(ownership.map { ",\"ownership\":\"\($0)\"" } ?? "")}"
    }
    return "{\"entitlements\":[\(entitlements.map { "\"\($0)\"" }.joined(separator: ","))],\"grants\":[\(grants.joined(separator: ","))],\"supportId\":\"K7QM-4XRT\",\"customer\":{\"id\":\"asc_1\",\"supportId\":\"K7QM-4XRT\"}}"
}

@MainActor
final class PixerateStoreTests: XCTestCase {
    private func makeStore(
        storeKit: FakeStoreKit,
        transport: MockTransport,
        distribution: PixerateDistribution = .appStore,
        account: PixerateAccountClient? = nil,
        sessionStore: InMemoryCustomerSessionStore = InMemoryCustomerSessionStore(),
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> PixerateStore {
        PixerateStore(
            configuration: PixerateStoreConfiguration(
                baseURL: URL(string: "https://pixerate.test")!,
                productIds: [monthly, yearly],
                appEntitlement: PixerateEntitlement.swashPro,
                bundleIdentifier: "com.pixerate.test",
                distributionMode: .fixed(distribution)
            ),
            account: account,
            storeKit: storeKit,
            transport: transport,
            sessionStore: sessionStore,
            now: { now }
        )
    }

    /// A server that mints sessions and returns `entitlements` from the entitlements endpoint.
    private func server(entitlements: [String] = [], source: String = "app_store", ownership: String? = "PURCHASED", verifyStatus: Int = 200) -> MockTransport {
        MockTransport { request in
            switch request.url?.path {
            case "/api/auth/app-store": return (200, sessionJSON)
            case "/api/me/entitlements": return (200, entitlementsJSON(entitlements, source: source, ownership: ownership))
            case "/api/billing/apple/verify":
                return verifyStatus == 200
                    ? (200, entitlementsJSON([PixerateEntitlement.swashPro]))
                    : (verifyStatus, "{\"error\":\"Nope\",\"code\":\"invalid_argument\"}")
            default: return (404, "{}")
            }
        }
    }

    // MARK: Session

    func testStartMintsACustomerSessionAndLoadsEverything() async throws {
        let storeKit = FakeStoreKit()
        storeKit.available = [
            PixerateStoreProduct(id: yearly, displayName: "Yearly", displayPrice: "$29.99", price: 29.99, isFamilyShareable: true),
            PixerateStoreProduct(id: monthly, displayName: "Monthly", displayPrice: "$3.99", price: 3.99, isFamilyShareable: true)
        ]
        let transport = server()
        let sessions = InMemoryCustomerSessionStore()
        let store = makeStore(storeKit: storeKit, transport: transport, sessionStore: sessions)

        await store.start()

        XCTAssertEqual(store.distribution, .appStore)
        XCTAssertEqual(store.products.map(\.id), [monthly, yearly], "cheapest first")
        XCTAssertEqual(store.supportId, "K7QM-4XRT")
        XCTAssertEqual(sessions.load()?.token, "pix_asc_token")

        let mint = try XCTUnwrap(transport.requests(to: "/api/auth/app-store").first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: mint.httpBody ?? Data()) as? [String: String])
        XCTAssertEqual(body["appTransaction"], "app-transaction-jws")

        let fetch = try XCTUnwrap(transport.requests(to: "/api/me/entitlements").first)
        XCTAssertEqual(fetch.value(forHTTPHeaderField: "X-Pixerate-App-Store-Customer"), "pix_asc_token")
        XCTAssertNil(fetch.value(forHTTPHeaderField: "Authorization"))
    }

    func testAFreshSavedSessionIsReused() async {
        let saved = PixerateCustomerSession(
            token: "pix_asc_saved",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000 + 7 * 86_400),
            customer: PixerateAppStoreCustomer(id: "asc_1", supportId: "SAVE-D000")
        )
        let transport = server()
        let store = makeStore(storeKit: FakeStoreKit(), transport: transport, sessionStore: InMemoryCustomerSessionStore(saved))

        await store.start()

        XCTAssertTrue(transport.requests(to: "/api/auth/app-store").isEmpty)
        XCTAssertEqual(transport.requests(to: "/api/me/entitlements").first?.value(forHTTPHeaderField: "X-Pixerate-App-Store-Customer"), "pix_asc_saved")
    }

    func testASessionAboutToExpireIsReplaced() async {
        let saved = PixerateCustomerSession(
            token: "pix_asc_old",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000 + 3_600),
            customer: PixerateAppStoreCustomer(id: "asc_1")
        )
        let transport = server()
        let store = makeStore(storeKit: FakeStoreKit(), transport: transport, sessionStore: InMemoryCustomerSessionStore(saved))

        await store.start()

        XCTAssertEqual(transport.requests(to: "/api/auth/app-store").count, 1)
        XCTAssertEqual(transport.requests(to: "/api/me/entitlements").first?.value(forHTTPHeaderField: "X-Pixerate-App-Store-Customer"), "pix_asc_token")
    }

    func testARejectedTokenIsMintedAgainOnce() async {
        let saved = PixerateCustomerSession(token: "pix_asc_revoked", expiresAt: nil, customer: PixerateAppStoreCustomer(id: "asc_1"))
        let transport = MockTransport { request in
            switch request.url?.path {
            case "/api/auth/app-store": return (200, sessionJSON)
            case "/api/me/entitlements":
                let token = request.value(forHTTPHeaderField: "X-Pixerate-App-Store-Customer")
                return token == "pix_asc_token" ? (200, entitlementsJSON(["swash_pro"])) : (401, "{\"code\":\"unauthenticated\"}")
            default: return (404, "{}")
            }
        }
        let store = makeStore(storeKit: FakeStoreKit(), transport: transport, sessionStore: InMemoryCustomerSessionStore(saved))

        await store.start()

        XCTAssertTrue(store.hasPro)
        XCTAssertEqual(transport.requests(to: "/api/me/entitlements").count, 2)
    }

    // MARK: Entitlements

    func testPixerateProCountsAsTheAppsPro() async {
        let store = makeStore(storeKit: FakeStoreKit(), transport: server(entitlements: ["pixerate_pro", "swash_pro", "jazzpaint_pro"], source: "plan", ownership: nil))
        await store.start()
        XCTAssertTrue(store.hasPro)
        XCTAssertEqual(store.proSource, .pixeratePro)
    }

    func testPixerateProAloneIsEnough() async {
        let store = makeStore(storeKit: FakeStoreKit(), transport: server(entitlements: ["pixerate_pro"], source: "plan", ownership: nil))
        await store.start()
        XCTAssertTrue(store.hasPro)
    }

    func testAnotherAppsProDoesNotCount() async {
        let store = makeStore(storeKit: FakeStoreKit(), transport: server(entitlements: ["jazzpaint_pro"]))
        await store.start()
        XCTAssertFalse(store.hasPro)
        XCTAssertNil(store.proSource)
    }

    func testProSourceForFamilySharingAndComplimentary() async {
        let family = makeStore(storeKit: FakeStoreKit(), transport: server(entitlements: ["swash_pro"], ownership: "FAMILY_SHARED"))
        await family.start()
        XCTAssertEqual(family.proSource, .appStore(familyShared: true))

        let comp = makeStore(storeKit: FakeStoreKit(), transport: server(entitlements: ["pixerate_pro"], source: "complimentary", ownership: nil))
        await comp.start()
        XCTAssertEqual(comp.proSource, .complimentary)
    }

    func testOfflineFallsBackToAVerifiedSubscriptionOnThisDevice() async {
        let storeKit = FakeStoreKit()
        storeKit.current = [storeKit.transaction(monthly, expires: Date(timeIntervalSince1970: 1_900_000_000))]
        let transport = MockTransport { _ in throw URLError(.notConnectedToInternet) }
        let store = makeStore(storeKit: storeKit, transport: transport)

        await store.start()

        XCTAssertTrue(store.hasPro)
        XCTAssertEqual(store.proSource, .offline)
    }

    func testOfflineIgnoresExpiredOrOtherSubscriptions() async {
        let storeKit = FakeStoreKit()
        storeKit.current = [
            storeKit.transaction(monthly, id: 1, expires: Date(timeIntervalSince1970: 1_700_000_000)),
            storeKit.transaction("com.other.pro", id: 2, expires: Date(timeIntervalSince1970: 1_900_000_000))
        ]
        let store = makeStore(storeKit: storeKit, transport: MockTransport { _ in throw URLError(.timedOut) })

        await store.start()

        XCTAssertFalse(store.hasPro)
    }

    // MARK: Purchases

    func testBuySendsTheTransactionToTheServerBeforeFinishingIt() async throws {
        let storeKit = FakeStoreKit()
        storeKit.outcome = .purchased(storeKit.transaction(monthly, id: 42))
        let transport = server()
        transport.handler = { [storeKit] request in
            if request.url?.path == "/api/billing/apple/verify" { storeKit.record("verify") }
            switch request.url?.path {
            case "/api/auth/app-store": return (200, sessionJSON)
            case "/api/billing/apple/verify": return (200, entitlementsJSON(["swash_pro"]))
            default: return (200, entitlementsJSON([]))
            }
        }
        let store = makeStore(storeKit: storeKit, transport: transport)
        await store.start()

        let accepted = await store.buy(monthly)

        XCTAssertTrue(accepted)
        XCTAssertTrue(store.hasPro)
        XCTAssertEqual(storeKit.events.suffix(3), ["purchase \(monthly)", "verify", "finish 42"])
        let verify = try XCTUnwrap(transport.requests(to: "/api/billing/apple/verify").first)
        XCTAssertEqual(verify.value(forHTTPHeaderField: "X-Pixerate-App-Store-Customer"), "pix_asc_token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: verify.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["signedTransactionInfo"] as? String, "tx-jws-42")
        XCTAssertNil(body["target"], "customer purchases carry no team target")
    }

    func testARejectedPurchaseIsNotFinished() async {
        let storeKit = FakeStoreKit()
        storeKit.outcome = .purchased(storeKit.transaction(monthly, id: 7))
        let store = makeStore(storeKit: storeKit, transport: server(verifyStatus: 400))
        await store.start()

        let accepted = await store.buy(monthly)

        XCTAssertFalse(accepted)
        XCTAssertFalse(storeKit.events.contains("finish 7"))
        XCTAssertEqual(store.lastError, .serverRejected(status: 400, code: "invalid_argument", message: "Nope"))
    }

    func testUnfinishedTransactionsAreSentAtLaunch() async {
        let storeKit = FakeStoreKit()
        storeKit.unfinished = [storeKit.transaction(yearly, id: 9), storeKit.transaction("com.other", id: 10)]
        let transport = server()
        let store = makeStore(storeKit: storeKit, transport: transport)

        await store.start()

        XCTAssertEqual(transport.requests(to: "/api/billing/apple/verify").count, 1)
        XCTAssertTrue(storeKit.events.contains("finish 9"))
        XCTAssertFalse(storeKit.events.contains("finish 10"))
    }

    func testRestoreSyncsAndSendsCurrentSubscriptions() async {
        let storeKit = FakeStoreKit()
        storeKit.current = [storeKit.transaction(yearly, id: 3, familyShared: true)]
        let transport = server(entitlements: ["swash_pro"], ownership: "FAMILY_SHARED")
        let store = makeStore(storeKit: storeKit, transport: transport)
        await store.start()

        let restored = await store.restore()

        XCTAssertTrue(restored)
        XCTAssertTrue(storeKit.events.contains("sync"))
        XCTAssertEqual(transport.requests(to: "/api/billing/apple/verify").count, 1)
        XCTAssertEqual(store.proSource, .appStore(familyShared: true))
    }

    func testDirectDistributionNeverTouchesTheAppStore() async {
        let storeKit = FakeStoreKit()
        storeKit.available = [PixerateStoreProduct(id: monthly, displayName: "Monthly", displayPrice: "$3.99", price: 3.99)]
        let transport = server()
        let store = makeStore(storeKit: storeKit, transport: transport, distribution: .direct)

        await store.start()
        let bought = await store.buy(monthly)

        XCTAssertFalse(store.canPurchase)
        XCTAssertTrue(store.products.isEmpty)
        XCTAssertFalse(bought)
        XCTAssertEqual(store.lastError, .notAppStoreBuild)
        XCTAssertEqual(storeKit.appTransactionCalls, 0)
        XCTAssertTrue(storeKit.events.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty, "signed out in a direct build: nothing to ask")
    }

    func testDirectDistributionUsesTheSignedInAccount() async throws {
        let account = PixerateAccountClient(baseURL: URL(string: "https://pixerate.test")!, tokenStore: InMemoryTokenStore(token: "pix_live_key"))
        let transport = server(entitlements: ["pixerate_pro"], source: "complimentary", ownership: nil)
        let store = makeStore(storeKit: FakeStoreKit(), transport: transport, distribution: .direct, account: account)

        await store.start()

        XCTAssertTrue(store.hasPro)
        let fetch = try XCTUnwrap(transport.requests(to: "/api/me/entitlements").first)
        XCTAssertEqual(fetch.value(forHTTPHeaderField: "Authorization"), "Bearer pix_live_key")
        XCTAssertNil(fetch.value(forHTTPHeaderField: "X-Pixerate-App-Store-Customer"))
    }

    // MARK: Requests and linking

    func testAuthorizedRequestCarriesBothCredentials() async throws {
        let account = PixerateAccountClient(baseURL: URL(string: "https://pixerate.test")!, tokenStore: InMemoryTokenStore(token: "pix_live_key"))
        let store = makeStore(storeKit: FakeStoreKit(), transport: server(), account: account)
        await store.start()

        let request = try store.authorizedRequest(path: "/api/agent/text-lead", body: Data("{}".utf8))

        XCTAssertEqual(request.url?.absoluteString, "https://pixerate.test/api/agent/text-lead")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Pixerate-App-Store-Customer"), "pix_asc_token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer pix_live_key")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testAuthorizedRequestNeedsSomeCredential() async {
        let store = makeStore(storeKit: FakeStoreKit(), transport: server(), distribution: .direct)
        await store.start()
        XCTAssertThrowsError(try store.authorizedRequest(path: "/api/x")) { error in
            XCTAssertEqual(error as? PixerateStoreError, .unauthenticated)
        }
    }

    func testLinkMapsConflictsAndRetriesWithConfirmation() async throws {
        let account = PixerateAccountClient(baseURL: URL(string: "https://pixerate.test")!, tokenStore: InMemoryTokenStore(token: "pix_live_key"))
        let transport = MockTransport { request in
            switch request.url?.path {
            case "/api/auth/app-store": return (200, sessionJSON)
            case "/api/app-store/link":
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
                return body["confirmMove"] as? Bool == true
                    ? (200, "{\"customer\":{\"id\":\"asc_1\",\"supportId\":\"K7QM-4XRT\",\"linkedUserId\":\"u1\"}}")
                    : (409, "{\"error\":\"Linked elsewhere\",\"code\":\"linked_elsewhere\"}")
            default:
                // After linking, the server reports the customer with its linked user.
                let linked = "{\"entitlements\":[\"swash_pro\"],\"grants\":[],\"supportId\":\"K7QM-4XRT\",\"customer\":{\"id\":\"asc_1\",\"supportId\":\"K7QM-4XRT\",\"linkedUserId\":\"u1\"}}"
                return (200, linked)
            }
        }
        let store = makeStore(storeKit: FakeStoreKit(), transport: transport, account: account)
        await store.start()

        do {
            try await store.link()
            XCTFail("expected linkedElsewhere")
        } catch {
            XCTAssertEqual(error as? PixerateStoreError, .linkedElsewhere)
        }
        try await store.link(confirmMove: true)
        XCTAssertEqual(store.customer?.linkedUserId, "u1")
    }

    func testLinkRateLimitAndUnlink() async throws {
        let account = PixerateAccountClient(baseURL: URL(string: "https://pixerate.test")!, tokenStore: InMemoryTokenStore(token: "pix_live_key"))
        let transport = MockTransport { request in
            switch (request.url?.path, request.httpMethod) {
            case ("/api/auth/app-store", _): return (200, sessionJSON)
            case ("/api/app-store/link", "POST"): return (429, "{\"code\":\"relink_limited\"}")
            case ("/api/app-store/link", "DELETE"): return (200, "{\"customer\":{\"id\":\"asc_1\",\"linkedUserId\":null}}")
            default: return (200, entitlementsJSON([]))
            }
        }
        let store = makeStore(storeKit: FakeStoreKit(), transport: transport, account: account)
        await store.start()

        do {
            try await store.link(confirmMove: true)
            XCTFail("expected relinkLimited")
        } catch {
            XCTAssertEqual(error as? PixerateStoreError, .relinkLimited)
        }
        try await store.unlink()
        XCTAssertNil(store.customer?.linkedUserId)
    }

    func testLinkNeedsASignedInAccount() async {
        let store = makeStore(storeKit: FakeStoreKit(), transport: server())
        await store.start()
        do {
            try await store.link()
            XCTFail("expected unauthenticated")
        } catch {
            XCTAssertEqual(error as? PixerateStoreError, .unauthenticated)
        }
    }

    // MARK: Decoding

    func testEntitlementsDecodeWithAndWithoutFractionalSeconds() throws {
        let json = Data("""
        {"entitlements":["swash_pro"],"grants":[
          {"entitlement":"swash_pro","source":"app_store","via":"customer","ownership":"FAMILY_SHARED","expiresAt":"2030-01-01T00:00:00.000Z"},
          {"entitlement":"pixerate_pro","source":"complimentary","via":"team","teamId":"t1","expiresAt":null},
          {"entitlement":"swash_pro","source":"something_new","expiresAt":"2030-01-01T00:00:00Z"}
        ],"supportId":"K7QM-4XRT","customer":null,"user":{"id":"u1","email":"a@b.c"}}
        """.utf8)
        let decoded = try JSONDecoder.pixerateStore.decode(PixerateEntitlements.self, from: json)
        XCTAssertEqual(decoded.grants.count, 3)
        XCTAssertTrue(decoded.grants[0].isFamilyShared)
        XCTAssertNotNil(decoded.grants[0].expiresAt)
        XCTAssertNil(decoded.grants[1].expiresAt)
        XCTAssertEqual(decoded.grants[2].source, "something_new")
        XCTAssertEqual(decoded.user?.id, "u1")
    }

    func testPaywallPriceAndSourceText() {
        let product = PixerateStoreProduct(id: monthly, displayName: "Monthly", displayPrice: "$3.99", price: 3.99, periodDescription: "month")
        XCTAssertEqual(PixerateProPaywall.price(product), "$3.99 / month")
        XCTAssertEqual(PixerateProPaywall.describe(.appStore(familyShared: true)), "Shared by your family through the App Store")
    }

    // MARK: StoreKit

    /// Runs the live StoreKit client against the test configuration file. Local StoreKit
    /// testing isn't available everywhere `swift test` runs (it needs a signed-in macOS
    /// session), so this skips when the session can't start.
    func testLiveClientWithStoreKitConfiguration() async throws {
        guard let url = Bundle.module.url(forResource: "PixerateStoreTests", withExtension: "storekit") else {
            throw XCTSkip("StoreKit configuration file missing from the test bundle")
        }
        let session: SKTestSession
        do {
            session = try SKTestSession(contentsOf: url)
        } catch {
            throw XCTSkip("Local StoreKit testing unavailable: \(error)")
        }
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }

        let client = LiveStoreKitClient()
        let products: [PixerateStoreProduct]
        do {
            products = try await client.products(for: [monthly, yearly])
        } catch {
            throw XCTSkip("StoreKit products unavailable: \(error)")
        }
        guard !products.isEmpty else { throw XCTSkip("StoreKit returned no products in this environment") }

        XCTAssertEqual(Set(products.map(\.id)), [monthly, yearly])
        XCTAssertTrue(products.allSatisfy(\.isFamilyShareable))
        XCTAssertEqual(products.first { $0.id == monthly }?.periodDescription, "month")

        let transport = server()
        transport.handler = { request in
            switch request.url?.path {
            case "/api/auth/app-store": return (200, sessionJSON)
            case "/api/billing/apple/verify": return (200, entitlementsJSON(["swash_pro"]))
            default: return (200, entitlementsJSON([]))
            }
        }
        let store = PixerateStore(
            configuration: PixerateStoreConfiguration(
                baseURL: URL(string: "https://pixerate.test")!,
                productIds: [monthly, yearly],
                appEntitlement: PixerateEntitlement.swashPro,
                bundleIdentifier: "com.pixerate.test",
                distributionMode: .fixed(.appStore)
            ),
            storeKit: client,
            transport: transport,
            sessionStore: InMemoryCustomerSessionStore(PixerateCustomerSession(token: "pix_asc_token", expiresAt: nil, customer: .init(id: "asc_1")))
        )
        await store.start()
        let bought = await store.buy(monthly)

        XCTAssertTrue(bought)
        XCTAssertEqual(transport.requests(to: "/api/billing/apple/verify").count, 1)
        let current = await client.currentEntitlements()
        XCTAssertTrue(current.contains { $0.productId == monthly })
    }
}
