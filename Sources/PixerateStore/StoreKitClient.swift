import Foundation
import StoreKit

/// A product to show on a paywall. Plain values, so previews and tests don't need StoreKit.
public struct PixerateStoreProduct: Identifiable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var description: String
    /// Localized price, e.g. "$4.99".
    public var displayPrice: String
    public var price: Decimal
    /// e.g. "month", "year", "2 months"; `nil` for non-subscriptions.
    public var periodDescription: String?
    public var isFamilyShareable: Bool

    public init(
        id: String,
        displayName: String,
        description: String = "",
        displayPrice: String,
        price: Decimal,
        periodDescription: String? = nil,
        isFamilyShareable: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.displayPrice = displayPrice
        self.price = price
        self.periodDescription = periodDescription
        self.isFamilyShareable = isFamilyShareable
    }
}

/// A verified StoreKit transaction. Unverified ones never get this far.
public struct PixerateStoreTransaction: Sendable {
    public var id: UInt64
    public var originalId: UInt64
    public var productId: String
    /// The signed transaction, sent to the server.
    public var jwsRepresentation: String
    public var expirationDate: Date?
    public var revocationDate: Date?
    public var isFamilyShared: Bool
    /// Tells StoreKit the app has dealt with it.
    public var finish: @Sendable () async -> Void

    public init(
        id: UInt64,
        originalId: UInt64,
        productId: String,
        jwsRepresentation: String,
        expirationDate: Date? = nil,
        revocationDate: Date? = nil,
        isFamilyShared: Bool = false,
        finish: @escaping @Sendable () async -> Void = {}
    ) {
        self.id = id
        self.originalId = originalId
        self.productId = productId
        self.jwsRepresentation = jwsRepresentation
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.isFamilyShared = isFamilyShared
        self.finish = finish
    }

    /// Not refunded or revoked, and not past its end date.
    func isActive(at now: Date) -> Bool {
        if revocationDate != nil { return false }
        if let expirationDate, expirationDate <= now { return false }
        return true
    }
}

public enum PixeratePurchaseOutcome: Sendable {
    case purchased(PixerateStoreTransaction)
    /// Waiting for approval (Ask to Buy, or a payment that needs action). It arrives later
    /// through `transactionUpdates`.
    case pending
    case cancelled
}

/// The StoreKit calls `PixerateStore` makes, so tests can replace them.
public protocol PixerateStoreKitClient: Sendable {
    /// The signed `AppTransaction`, or `nil` when the app wasn't installed from the App Store.
    func appTransactionJWS() async -> String?
    func products(for ids: [String]) async throws -> [PixerateStoreProduct]
    func purchase(productId: String) async throws -> PixeratePurchaseOutcome
    func sync() async throws
    func currentEntitlements() async -> [PixerateStoreTransaction]
    func unfinishedTransactions() async -> [PixerateStoreTransaction]
    /// Renewals, Ask to Buy approvals, Family Sharing changes and purchases made on other
    /// devices or outside the app, for as long as the app runs.
    func transactionUpdates() -> AsyncStream<PixerateStoreTransaction>
}

/// StoreKit 2.
public final class LiveStoreKitClient: PixerateStoreKitClient, @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: Product] = [:]

    public init() {}

    public func appTransactionJWS() async -> String? {
        do {
            let result = try await AppTransaction.shared
            guard case .verified = result else { return nil }
            return result.jwsRepresentation
        } catch {
            return nil
        }
    }

    public func products(for ids: [String]) async throws -> [PixerateStoreProduct] {
        let products = try await Product.products(for: ids)
        lock.withLock {
            for product in products { cache[product.id] = product }
        }
        return products.map(Self.describe)
    }

    public func purchase(productId: String) async throws -> PixeratePurchaseOutcome {
        var product = lock.withLock { cache[productId] }
        if product == nil {
            product = try await Product.products(for: [productId]).first
        }
        guard let product else { throw StoreKitError.notAvailableInStorefront }
        switch try await product.purchase() {
        case .success(let result):
            guard let transaction = Self.verified(result) else {
                throw StoreKitError.unknown
            }
            return .purchased(transaction)
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    public func sync() async throws {
        try await AppStore.sync()
    }

    public func currentEntitlements() async -> [PixerateStoreTransaction] {
        var transactions: [PixerateStoreTransaction] = []
        for await result in Transaction.currentEntitlements {
            if let transaction = Self.verified(result) { transactions.append(transaction) }
        }
        return transactions
    }

    public func unfinishedTransactions() async -> [PixerateStoreTransaction] {
        var transactions: [PixerateStoreTransaction] = []
        for await result in Transaction.unfinished {
            if let transaction = Self.verified(result) { transactions.append(transaction) }
        }
        return transactions
    }

    public func transactionUpdates() -> AsyncStream<PixerateStoreTransaction> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    if let transaction = Self.verified(result) { continuation.yield(transaction) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func verified(_ result: VerificationResult<Transaction>) -> PixerateStoreTransaction? {
        guard case .verified(let transaction) = result else { return nil }
        return PixerateStoreTransaction(
            id: transaction.id,
            originalId: transaction.originalID,
            productId: transaction.productID,
            jwsRepresentation: result.jwsRepresentation,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            isFamilyShared: transaction.ownershipType == .familyShared,
            finish: { await transaction.finish() }
        )
    }

    static func describe(_ product: Product) -> PixerateStoreProduct {
        PixerateStoreProduct(
            id: product.id,
            displayName: product.displayName,
            description: product.description,
            displayPrice: product.displayPrice,
            price: product.price,
            periodDescription: product.subscription.map { describe($0.subscriptionPeriod) },
            isFamilyShareable: product.isFamilyShareable
        )
    }

    static func describe(_ period: Product.SubscriptionPeriod) -> String {
        let unit: String
        switch period.unit {
        case .day: unit = "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: unit = "period"
        }
        return period.value == 1 ? unit : "\(period.value) \(unit)s"
    }
}
