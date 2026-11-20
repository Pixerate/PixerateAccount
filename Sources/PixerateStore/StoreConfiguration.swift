import Foundation

/// How the app was installed, which decides whether it may sell anything through the App Store.
public enum PixerateDistribution: String, Sendable, Equatable {
    /// Installed from the App Store (or TestFlight, or run from Xcode with a StoreKit
    /// configuration). Purchases are offered.
    case appStore
    /// Installed some other way (a notarized download, a Homebrew cask, a build from source).
    /// Purchases are never offered; Pro comes only from signing in to Pixerate.
    case direct
    /// Not worked out yet (`start()` hasn't run).
    case unknown
}

/// How `PixerateStore` decides the distribution.
public enum PixerateDistributionMode: Sendable, Equatable {
    /// Ask StoreKit. On macOS, an app without a Mac App Store receipt is treated as `.direct`
    /// without asking StoreKit, so a downloaded app never shows an App Store sign-in prompt.
    case automatic
    /// Use this distribution. Apps that know at build time (an `APP_STORE` compile flag, or a
    /// debug build run with a StoreKit configuration file) can say so here.
    case fixed(PixerateDistribution)
}

/// What one app sells and where its server is.
public struct PixerateStoreConfiguration: Sendable {
    /// The Pixerate server. Default `https://pixerate.com`.
    public var baseURL: URL
    /// The app's auto-renewable subscription product ids, as set up in App Store Connect.
    public var productIds: [String]
    /// The entitlement the app's Pro unlocks, e.g. `"swash_pro"`. Pixerate Pro
    /// (`"pixerate_pro"`) always counts too.
    public var appEntitlement: String
    /// The app's bundle id; it names the Keychain item that keeps the customer token.
    public var bundleIdentifier: String
    public var distributionMode: PixerateDistributionMode

    public init(
        baseURL: URL = URL(string: "https://pixerate.com")!,
        productIds: [String],
        appEntitlement: String,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.pixerate.app",
        distributionMode: PixerateDistributionMode = .automatic
    ) {
        self.baseURL = baseURL
        self.productIds = productIds
        self.appEntitlement = appEntitlement
        self.bundleIdentifier = bundleIdentifier
        self.distributionMode = distributionMode
    }
}

/// Entitlement ids the Pixerate server knows.
public enum PixerateEntitlement {
    public static let pixeratePro = "pixerate_pro"
    public static let swashPro = "swash_pro"
    public static let jazzPaintPro = "jazzpaint_pro"
}

/// Server paths and headers, in one place.
enum PixerateStoreAPI {
    static let appStoreSessionPath = "/api/auth/app-store"
    static let verifyPath = "/api/billing/apple/verify"
    static let entitlementsPath = "/api/me/entitlements"
    static let linkPath = "/api/app-store/link"
    static let customerHeader = "X-Pixerate-App-Store-Customer"
}
