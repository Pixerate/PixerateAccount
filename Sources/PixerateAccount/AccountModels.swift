import Foundation

public enum TeamRole: String, Codable, Sendable, CaseIterable, Equatable {
    case owner
    case admin
    case editor
    case member
    case viewer
}

public struct AuthUser: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var email: String?
    public var displayName: String?
    public var photoURL: String?
    public var emailVerified: Bool?

    public init(
        id: String,
        email: String? = nil,
        displayName: String? = nil,
        photoURL: String? = nil,
        emailVerified: Bool? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.photoURL = photoURL
        self.emailVerified = emailVerified
    }
}

/// A subscription an admin granted free of charge. Billing never changes it.
public struct ComplimentarySubscription: Codable, Sendable, Equatable {
    /// The plan the grant unlocks, e.g. "pro".
    public var planId: String
    /// When the grant ends (ISO 8601). `nil`: it never expires.
    public var expiresAt: String?

    public init(planId: String, expiresAt: String? = nil) {
        self.planId = planId
        self.expiresAt = expiresAt
    }

    /// The expiry as a `Date`, or `nil` when it never expires or can't be read.
    public var expiresAtDate: Date? {
        guard let expiresAt else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
    }

    /// Whether the grant is in effect at `date`. An unreadable expiry counts as expired.
    public func isActive(at date: Date = Date()) -> Bool {
        guard expiresAt != nil else { return true }
        guard let end = expiresAtDate else { return false }
        return end > date
    }
}

public struct Team: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var ownerId: String
    public var orgId: String?
    public var planId: String
    public var fuelBalance: Int
    public var memberIds: [String]
    public var role: TeamRole?
    public var cancelAtPeriodEnd: Bool?
    public var billingPeriodStart: String?
    public var billingPeriodEnd: String?
    /// Admin-granted subscription, if any. See `ComplimentarySubscription`.
    public var complimentary: ComplimentarySubscription?

    public init(
        id: String,
        name: String,
        ownerId: String,
        orgId: String? = nil,
        planId: String = "free",
        fuelBalance: Int = 0,
        memberIds: [String] = [],
        role: TeamRole? = nil,
        cancelAtPeriodEnd: Bool? = nil,
        billingPeriodStart: String? = nil,
        billingPeriodEnd: String? = nil,
        complimentary: ComplimentarySubscription? = nil
    ) {
        self.id = id
        self.name = name
        self.ownerId = ownerId
        self.orgId = orgId
        self.planId = planId
        self.fuelBalance = fuelBalance
        self.memberIds = memberIds
        self.role = role
        self.cancelAtPeriodEnd = cancelAtPeriodEnd
        self.billingPeriodStart = billingPeriodStart
        self.billingPeriodEnd = billingPeriodEnd
        self.complimentary = complimentary
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case ownerId
        case orgId
        case planId
        case fuelBalance
        case memberIds
        case role
        case cancelAtPeriodEnd
        case billingPeriodStart
        case billingPeriodEnd
        case complimentary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.ownerId = try container.decodeIfPresent(String.self, forKey: .ownerId) ?? ""
        self.orgId = try container.decodeIfPresent(String.self, forKey: .orgId)
        self.planId = try container.decodeIfPresent(String.self, forKey: .planId) ?? "free"
        self.fuelBalance = try container.decodeIfPresent(Int.self, forKey: .fuelBalance) ?? 0
        self.memberIds = try container.decodeIfPresent([String].self, forKey: .memberIds) ?? []
        self.role = try container.decodeIfPresent(TeamRole.self, forKey: .role)
        self.cancelAtPeriodEnd = try container.decodeIfPresent(Bool.self, forKey: .cancelAtPeriodEnd)
        self.billingPeriodStart = try container.decodeIfPresent(String.self, forKey: .billingPeriodStart)
        self.billingPeriodEnd = try container.decodeIfPresent(String.self, forKey: .billingPeriodEnd)
        // A malformed grant (e.g. a raw Firestore Timestamp) shouldn't fail the whole team.
        self.complimentary = try? container.decodeIfPresent(
            ComplimentarySubscription.self,
            forKey: .complimentary
        )
    }
}

public struct AgentHandshakeInitResponse: Codable, Sendable, Equatable {
    public let id: String?
    public let userCode: String
    public let deviceCode: String
    public let expiresAt: String
    public let verifyUrl: String?

    public init(
        id: String? = nil,
        userCode: String,
        deviceCode: String,
        expiresAt: String,
        verifyUrl: String? = nil
    ) {
        self.id = id
        self.userCode = userCode
        self.deviceCode = deviceCode
        self.expiresAt = expiresAt
        self.verifyUrl = verifyUrl
    }
}

public struct AgentHandshakeRedeemResponse: Codable, Sendable, Equatable {
    public let status: String
    public let rawKey: String?
    public let apiKeyId: String?
    public let user: AuthUser?
    public let defaultTeamId: String?
    public let teams: [Team]?

    public init(
        status: String,
        rawKey: String? = nil,
        apiKeyId: String? = nil,
        user: AuthUser? = nil,
        defaultTeamId: String? = nil,
        teams: [Team]? = nil
    ) {
        self.status = status
        self.rawKey = rawKey
        self.apiKeyId = apiKeyId
        self.user = user
        self.defaultTeamId = defaultTeamId
        self.teams = teams
    }
}

public struct TeamsListResponse: Codable, Sendable, Equatable {
    public let teams: [Team]
    public let defaultTeamId: String?
    public let user: AuthUser?

    public init(teams: [Team], defaultTeamId: String? = nil, user: AuthUser? = nil) {
        self.teams = teams
        self.defaultTeamId = defaultTeamId
        self.user = user
    }
}
