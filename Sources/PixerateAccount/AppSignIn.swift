import CryptoKit
import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/**
 * App sign-in (`signInWithApp`): OAuth 2.0 authorization code with PKCE against Pixerate's
 * `/auth/app` and `/api/auth/app/token`. The app shows Pixerate's sign-in page in a system sheet
 * (`ASWebAuthenticationSession`, which shares Safari's pixerate.com session), the person taps
 * Continue, and the sheet returns a one-time code to the app's callback scheme, which only this
 * app can trade (it alone holds the PKCE verifier) for a personal API key.
 */
public enum PixerateAppSignIn {
    /// A PKCE code verifier: 32 random bytes, base64url (43 characters).
    public static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return base64url(Data(bytes))
    }

    /// The S256 challenge of `verifier` (RFC 7636).
    public static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// `/auth/app` on `baseURL` for this client.
    public static func authorizeURL(baseURL: URL, clientId: String, redirectURI: String, challenge: String, state: String) -> URL? {
        var c = URLComponents(url: baseURL.appendingPathComponent("auth/app"), resolvingAgainstBaseURL: false)
        c?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return c?.url
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Why app sign-in stopped without signing in.
public enum PixerateAppSignInError: LocalizedError, Sendable, Equatable {
    /// The person closed the sheet or tapped Cancel (not shown as an error).
    case cancelled
    /// The sheet came back without a matching `state` or a code.
    case invalidCallback
    /// The server refused the code (`error_description`).
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in was cancelled."
        case .invalidCallback: return "Sign-in returned an unexpected response. Try again."
        case .refused(let message): return message
        }
    }
}

/// Shows a sign-in URL and returns the callback URL the page sends the person back to.
@MainActor
public protocol PixerateWebAuthPresenter {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

#if canImport(AuthenticationServices)
/**
 * Presents app sign-in in an `ASWebAuthenticationSession` sheet over the key window. It shares
 * the browser's cookies (not ephemeral), so a person already signed in on pixerate.com only taps
 * Continue.
 */
@MainActor
public final class SystemWebAuthPresenter: NSObject, PixerateWebAuthPresenter, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    override public init() {}

    public func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callback, error in
                self?.session = nil
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: PixerateAppSignInError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? PixerateAppSignInError.invalidCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: PixerateAppSignInError.invalidCallback)
            }
        }
    }

    public nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #else
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}
#endif

struct AppTokenResponse: Decodable {
    let token: String?
    let apiKeyId: String?
    let error: String?
    let error_description: String?
}
