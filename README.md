# PixerateAccount

Public Swift packages for Pixerate accounts on macOS and iOS:

- **PixerateAccount**: sign in with a Pixerate account.
- **PixerateStore**: sell an app's Pro subscription through the App Store, without requiring an account, and unlock it for Pixerate Pro and complimentary accounts too.

## Features

- Browser sign-in via OAuth 2.0 Authorization Code + PKCE (`signInWithApp`) and device handshake (`signInWithBrowser`)
- Session restore (`restoreSession`) and sign-out (`signOut`)
- Keychain-backed token storage (`KeychainTokenStore`) and in-memory store for tests (`InMemoryTokenStore`)
- Signed-in user (`AuthUser`) and teams (`Team`, `activeTeam`, `selectTeam(_:)`)
- Authenticated request builder (`authorizedRequest(path:method:body:)`)
- App Store Pro subscriptions without an account (`PixerateStore`, below)

## PixerateStore

`PixerateStore` handles an app's Pro subscription:

- **No account needed to buy.** At launch it reads the signed `AppTransaction` and trades it for an *App Store customer* token (`POST /api/auth/app-store`). The customer is the same on every device signed in to the same Apple Account (Universal Purchase), and different for each Family Sharing member.
- **Purchases are confirmed by the server before they're finished.** Each verified transaction goes to `POST /api/billing/apple/verify`; it's finished only once the server accepts it, so StoreKit delivers it again otherwise. Renewals, Ask to Buy approvals and Family Sharing changes arrive through `Transaction.updates`.
- **Entitlements, not plans.** `GET /api/me/entitlements` returns what the App Store customer and the signed-in account (if any) hold. `hasPro` is true for the app's own entitlement or Pixerate Pro. `proSource` says where it comes from (App Store, Family Sharing, complimentary, Pixerate Pro).
- **Support ID** for Settings (`supportId`, `PixerateSupportIDRow`).
- **Optional Pixerate account.** `link()` connects the App Store customer to the signed-in account so the purchase shows on the web; a `linkedElsewhere` error means another account has it, so ask before `link(confirmMove: true)`.
- **Direct downloads never sell.** A Mac app without an App Store receipt is `.direct`: no products, no StoreKit calls, Pro only through sign-in.
- **Offline.** If the server can't be reached, a verified, unexpired App Store subscription on the device keeps `hasPro` true (`proSource == .offline`). Server features still need the network.

```swift
import PixerateAccount
import PixerateStore

let account = PixerateAccountClient()
let store = PixerateStore(
    configuration: .init(
        productIds: ["com.example.app.pro.monthly", "com.example.app.pro.yearly"],
        appEntitlement: PixerateEntitlement.swashPro
    ),
    account: account
)

// At launch
await account.restoreSession()
await store.start()

// After signing in or out
await store.accountDidChange()

// Calling a gated endpoint: carries the customer token and, when signed in, the account key
let request = try store.authorizedRequest(path: "/api/agent/text-lead", body: body)
```

SwiftUI: `PixerateProPaywall(store:title:features:termsURL:privacyURL:)` shows products, the Family Sharing note, Restore Purchases and the required terms and privacy links. With Pro it shows where Pro comes from instead.

**Local testing.** Add a StoreKit configuration file to your app's scheme. On macOS, a debug build run from Xcode has no App Store receipt, so pass `distributionMode: .fixed(.appStore)` in debug builds (or behind your App Store build flag). `Tests/PixerateStoreTests/PixerateStoreTests.storekit` is a starting point: two family-shareable subscriptions in one group.

`PixerateStore.preview(...)` makes a store with fixed state for SwiftUI previews.

## Requirements

- macOS 14.0+ / iOS 17.0+ (tested on macOS 15+ and iOS 17+)
- Swift 6.0+

## Installation

Add `PixerateAccount` in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Pixerate/PixerateAccount.git", from: "0.3.0")
]
```

## License

MIT. See [LICENSE](LICENSE).
