# PixerateAccount

Public Swift package for signing in with a Pixerate account on macOS and iOS.

## Features

- Browser sign-in via OAuth 2.0 Authorization Code + PKCE (`signInWithApp`) and device handshake (`signInWithBrowser`)
- Session restore (`restoreSession`) and sign-out (`signOut`)
- Keychain-backed token storage (`KeychainTokenStore`) and in-memory store for tests (`InMemoryTokenStore`)
- Signed-in user (`AuthUser`) and teams (`Team`, `activeTeam`, `selectTeam(_:)`)
- Authenticated request builder (`authorizedRequest(path:method:body:)`)

## Requirements

- macOS 14.0+ / iOS 17.0+ (tested on macOS 15+ and iOS 17+)
- Swift 6.0+

## Installation

Add `PixerateAccount` in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Pixerate/PixerateAccount.git", from: "0.1.0")
]
```

## License

MIT. See [LICENSE](LICENSE).
