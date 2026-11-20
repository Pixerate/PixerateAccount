import Foundation

/// The App Store customer the server knows this Apple Account (for this app) as.
public struct PixerateAppStoreCustomer: Codable, Sendable, Equatable {
    public var id: String
    public var supportId: String?
    public var linkedUserId: String?

    public init(id: String, supportId: String? = nil, linkedUserId: String? = nil) {
        self.id = id
        self.supportId = supportId
        self.linkedUserId = linkedUserId
    }
}

/// One reason the person has an entitlement.
public struct PixerateEntitlementGrant: Codable, Sendable, Equatable, Hashable {
    /// `pixerate_pro`, `swash_pro`, `jazzpaint_pro`, …
    public var entitlement: String
    /// `app_store`, `plan` or `complimentary` (kept as a string so new sources decode).
    public var source: String
    /// `customer`, `team` or `organization`.
    public var via: String?
    public var teamId: String?
    public var productId: String?
    /// `PURCHASED` or `FAMILY_SHARED` for App Store grants.
    public var ownership: String?
    /// When it ends. `nil`: no end (or not known).
    public var expiresAt: Date?

    public init(
        entitlement: String,
        source: String,
        via: String? = nil,
        teamId: String? = nil,
        productId: String? = nil,
        ownership: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.entitlement = entitlement
        self.source = source
        self.via = via
        self.teamId = teamId
        self.productId = productId
        self.ownership = ownership
        self.expiresAt = expiresAt
    }

    public var isAppStore: Bool { source == "app_store" }
    public var isComplimentary: Bool { source == "complimentary" }
    public var isFamilyShared: Bool { ownership == "FAMILY_SHARED" }
}

/// `GET /api/me/entitlements`.
public struct PixerateEntitlements: Codable, Sendable, Equatable {
    public var entitlements: [String]
    public var grants: [PixerateEntitlementGrant]
    public var supportId: String?
    public var customer: PixerateAppStoreCustomer?
    public var user: User?

    public struct User: Codable, Sendable, Equatable {
        public var id: String
        public var email: String?

        public init(id: String, email: String? = nil) {
            self.id = id
            self.email = email
        }
    }

    public init(
        entitlements: [String] = [],
        grants: [PixerateEntitlementGrant] = [],
        supportId: String? = nil,
        customer: PixerateAppStoreCustomer? = nil,
        user: User? = nil
    ) {
        self.entitlements = entitlements
        self.grants = grants
        self.supportId = supportId
        self.customer = customer
        self.user = user
    }

    enum CodingKeys: String, CodingKey {
        case entitlements, grants, supportId, customer, user
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entitlements = try c.decodeIfPresent([String].self, forKey: .entitlements) ?? []
        grants = try c.decodeIfPresent([PixerateEntitlementGrant].self, forKey: .grants) ?? []
        supportId = try c.decodeIfPresent(String.self, forKey: .supportId)
        customer = try c.decodeIfPresent(PixerateAppStoreCustomer.self, forKey: .customer)
        user = try c.decodeIfPresent(User.self, forKey: .user)
    }
}

/// `POST /api/auth/app-store`.
struct AppStoreSessionResponse: Decodable, Sendable {
    var token: String
    var expiresAt: Date?
    var customer: PixerateAppStoreCustomer
}

/// The JSON error body the server sends with 4xx responses.
struct ServerErrorBody: Decodable, Sendable {
    var error: String?
    var code: String?
}

/// Where the person's Pro comes from, most specific first. Apps use it for Settings text.
public enum PixerateProSource: Sendable, Equatable {
    /// Bought in the App Store by this Apple Account, or shared with it by their family.
    case appStore(familyShared: Bool)
    /// A complimentary grant from Pixerate.
    case complimentary
    /// Pixerate Pro, which includes every app's Pro.
    case pixeratePro
    /// A team plan for this app (not Pixerate Pro).
    case plan
    /// The server couldn't be reached; a verified App Store subscription on this device is
    /// standing in until it can.
    case offline
}

public enum PixerateStoreError: LocalizedError, Sendable, Equatable {
    /// Purchases aren't offered: the app wasn't installed from the App Store.
    case notAppStoreBuild
    /// Neither an App Store customer session nor a Pixerate sign-in is available.
    case unauthenticated
    /// This App Store purchase is linked to another Pixerate account. Ask, then call
    /// `link(confirmMove: true)`.
    case linkedElsewhere
    /// The purchase has been moved between accounts too often recently.
    case relinkLimited
    /// The server refused, with its `code` and message when it sent them.
    case serverRejected(status: Int, code: String?, message: String?)
    /// The server couldn't be reached.
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notAppStoreBuild:
            return "Purchases are only available in the App Store version."
        case .unauthenticated:
            return "Sign in to Pixerate or buy Pro in the App Store version."
        case .linkedElsewhere:
            return "This App Store purchase is linked to another Pixerate account."
        case .relinkLimited:
            return "This purchase has been moved between accounts too often. Try again later."
        case .serverRejected(_, _, let message):
            return message ?? "Pixerate couldn't complete the request."
        case .network(let message):
            return message
        }
    }
}

extension JSONDecoder {
    /// ISO 8601 dates, with or without fractional seconds.
    static var pixerateStore: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = PixerateDates.parse(string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(string)")
        }
        return decoder
    }
}

enum PixerateDates {
    static func parse(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
