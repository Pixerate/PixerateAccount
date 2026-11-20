import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The Pro paywall: products with price and period, a Family Sharing note, Restore Purchases,
/// and the app's terms and privacy links (App Review requires both on a subscription paywall).
///
/// Outside the App Store it offers nothing to buy and shows `directMessage` instead. With Pro
/// it shows where Pro comes from.
public struct PixerateProPaywall: View {
    private let store: PixerateStore
    private let title: String
    private let features: [String]
    private let termsURL: URL
    private let privacyURL: URL
    private let directMessage: String

    public init(
        store: PixerateStore,
        title: String,
        features: [String] = [],
        termsURL: URL,
        privacyURL: URL,
        directMessage: String = "Sign in to Pixerate to use Pixerate Pro or a complimentary subscription."
    ) {
        self.store = store
        self.title = title
        self.features = features
        self.termsURL = termsURL
        self.privacyURL = privacyURL
        self.directMessage = directMessage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if !features.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(features, id: \.self) { feature in
                        Label(feature, systemImage: "checkmark")
                    }
                }
                .font(.callout)
            }

            if let source = store.proSource {
                Label(Self.describe(source), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.tint)
            } else if store.canPurchase {
                purchaseOptions
            } else if store.distribution == .direct {
                Text(directMessage).font(.callout).foregroundStyle(.secondary)
            }

            if store.canPurchase {
                HStack {
                    Button("Restore Purchases") { Task { await store.restore() } }
                        .disabled(store.isPurchasing)
                    Spacer()
                    Link("Terms of Use", destination: termsURL)
                    Link("Privacy Policy", destination: privacyURL)
                }
                .font(.footnote)
            }

            if let error = store.lastError?.errorDescription {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var purchaseOptions: some View {
        if store.products.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading subscriptions…").foregroundStyle(.secondary)
            }
        } else {
            ForEach(store.products) { product in
                Button {
                    Task { await store.buy(product.id) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(product.displayName)
                            if product.isFamilyShareable {
                                Text("Shared with your family").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(Self.price(product)).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(store.isPurchasing)
            }
            Text("Subscriptions renew automatically until cancelled in your Apple Account settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static func price(_ product: PixerateStoreProduct) -> String {
        guard let period = product.periodDescription else { return product.displayPrice }
        return "\(product.displayPrice) / \(period)"
    }

    /// Settings text for where Pro comes from.
    public static func describe(_ source: PixerateProSource) -> String {
        switch source {
        case .appStore(familyShared: false): return "Subscribed through the App Store"
        case .appStore(familyShared: true): return "Shared by your family through the App Store"
        case .complimentary: return "Complimentary subscription"
        case .pixeratePro: return "Included with Pixerate Pro"
        case .plan: return "Included with your team's plan"
        case .offline: return "Subscribed (can't reach Pixerate right now)"
        }
    }
}

/// "Support ID" with the id in a monospaced font and a Copy button. Shows nothing without an id.
public struct PixerateSupportIDRow: View {
    private let supportId: String?
    @State private var copied = false

    public init(supportId: String?) {
        self.supportId = supportId
    }

    public var body: some View {
        if let supportId {
            LabeledContent("Support ID") {
                HStack(spacing: 8) {
                    Text(supportId)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy") {
                        Self.copy(supportId)
                        copied = true
                    }
                    .accessibilityLabel("Copy Support ID")
                }
            }
        }
    }

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Previews

@MainActor
private enum PreviewData {
    static let products = [
        PixerateStoreProduct(id: "pro.monthly", displayName: "Swash Pro Monthly", displayPrice: "$3.99", price: 3.99, periodDescription: "month", isFamilyShareable: true),
        PixerateStoreProduct(id: "pro.yearly", displayName: "Swash Pro Yearly", displayPrice: "$29.99", price: 29.99, periodDescription: "year", isFamilyShareable: true)
    ]
    static let terms = URL(string: "https://example.com/terms")!
    static let privacy = URL(string: "https://example.com/privacy")!

    static func paywall(_ store: PixerateStore) -> some View {
        PixerateProPaywall(
            store: store,
            title: "Swash Pro",
            features: ["Writing partner on pause", "Your vocabulary everywhere"],
            termsURL: terms,
            privacyURL: privacy
        )
        .padding()
        .frame(width: 420)
    }

    static func grant(_ entitlement: String, _ source: String, ownership: String? = nil) -> PixerateEntitlements {
        PixerateEntitlements(
            entitlements: entitlement == PixerateEntitlement.pixeratePro
                ? [PixerateEntitlement.pixeratePro, PixerateEntitlement.swashPro, PixerateEntitlement.jazzPaintPro]
                : [entitlement],
            grants: [PixerateEntitlementGrant(entitlement: entitlement, source: source, ownership: ownership)],
            supportId: "K7QM-4XRT"
        )
    }
}

#Preview("Paywall: not subscribed") {
    PreviewData.paywall(.preview(products: PreviewData.products))
}

#Preview("Paywall: bought in the App Store") {
    PreviewData.paywall(.preview(entitlements: PreviewData.grant(PixerateEntitlement.swashPro, "app_store", ownership: "PURCHASED")))
}

#Preview("Paywall: Family Sharing") {
    PreviewData.paywall(.preview(entitlements: PreviewData.grant(PixerateEntitlement.swashPro, "app_store", ownership: "FAMILY_SHARED")))
}

#Preview("Paywall: Pixerate Pro") {
    PreviewData.paywall(.preview(entitlements: PreviewData.grant(PixerateEntitlement.pixeratePro, "plan")))
}

#Preview("Paywall: complimentary") {
    PreviewData.paywall(.preview(entitlements: PreviewData.grant(PixerateEntitlement.pixeratePro, "complimentary")))
}

#Preview("Paywall: direct download") {
    PreviewData.paywall(.preview(distribution: .direct))
}

#Preview("Support ID") {
    Form {
        PixerateSupportIDRow(supportId: "K7QM-4XRT")
    }
    .frame(width: 360)
}
