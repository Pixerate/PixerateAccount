import Foundation
import Observation
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum PixerateAccountError: LocalizedError, Sendable {
    case unauthenticated
    case invalidURL(String)
    case httpError(statusCode: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case .unauthenticated:
            return "Not authenticated with Pixerate."
        case .invalidURL(let path):
            return "Invalid URL path: \(path)"
        case .httpError(let code, let message):
            return message ?? "HTTP error \(code)"
        }
    }
}

@MainActor
@Observable
public final class PixerateAccountClient {
    public var baseURL: URL
    public private(set) var token: String?
    public private(set) var user: AuthUser?
    public private(set) var teams: [Team] = []
    public private(set) var activeTeamId: String?
    public private(set) var isAuthenticating = false
    public private(set) var pendingUserCode: String?
    public private(set) var pendingVerifyURL: URL?
    public var error: String?

    public var isAuthenticated: Bool {
        token != nil && user != nil
    }

    public var activeTeam: Team? {
        guard let activeTeamId else { return teams.first }
        return teams.first(where: { $0.id == activeTeamId }) ?? teams.first
    }

    public var fuelBalance: Int {
        activeTeam?.fuelBalance ?? 0
    }

    public var canUseAI: Bool {
        isAuthenticated && fuelBalance > 0
    }

    private let tokenStore: any PixerateTokenStore
    private let session: URLSession
    private var pollingTask: Task<Void, Never>?
    public var pollIntervalNanoseconds: UInt64 = 2_000_000_000

    public init(
        baseURL: URL = URL(string: "https://pixerate.com")!,
        tokenStore: any PixerateTokenStore = KeychainTokenStore(),
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.tokenStore = tokenStore
        self.session = session
        self.token = tokenStore.loadToken()
        self.activeTeamId = tokenStore.loadSelectedTeamId()
    }

    public func restoreSession() async {
        guard let savedToken = tokenStore.loadToken(), !savedToken.isEmpty else {
            return
        }
        self.token = savedToken
        if let savedTeamId = tokenStore.loadSelectedTeamId() {
            self.activeTeamId = savedTeamId
        }
        await refreshTeams()
    }

    public func signInWithBrowser(
        agentName: String = "Pixerate App",
        clientSource: String = "pixerate-app",
        scopes: [String] = [],
        openURL: ((URL) -> Void)? = nil
    ) async {
        cancelSignIn()
        isAuthenticating = true
        error = nil

        do {
            let initURL = endpointURL(path: "/api/auth/handshake")
            var initReq = URLRequest(url: initURL)
            initReq.httpMethod = "POST"
            initReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let payload: [String: Any] = [
                "agentName": agentName,
                "clientSource": clientSource,
                "scopes": scopes
            ]
            initReq.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await session.data(for: initReq)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw PixerateAccountError.httpError(
                    statusCode: http.statusCode,
                    message: "Failed to initiate authentication handshake (\(http.statusCode))"
                )
            }

            let initRes = try JSONDecoder().decode(AgentHandshakeInitResponse.self, from: data)
            self.pendingUserCode = initRes.userCode

            let verifyURL = resolveVerifyURL(
                serverVerifyUrl: initRes.verifyUrl,
                userCode: initRes.userCode
            )
            self.pendingVerifyURL = verifyURL

            if let openURL {
                openURL(verifyURL)
            } else {
                openSystemBrowser(verifyURL)
            }

            let deviceCode = initRes.deviceCode
            let pollInterval = self.pollIntervalNanoseconds

            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                let redeemURL = self.endpointURL(path: "/api/auth/handshake/redeem")

                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: pollInterval)
                    if Task.isCancelled { break }

                    do {
                        var redeemReq = URLRequest(url: redeemURL)
                        redeemReq.httpMethod = "POST"
                        redeemReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        redeemReq.httpBody = try JSONSerialization.data(
                            withJSONObject: ["deviceCode": deviceCode]
                        )

                        let (redeemData, redeemResp) = try await self.session.data(for: redeemReq)
                        if let http = redeemResp as? HTTPURLResponse,
                           !(200..<300).contains(http.statusCode) {
                            if http.statusCode == 404 || http.statusCode == 410 {
                                self.error = "Authentication session expired."
                                break
                            }
                            continue
                        }

                        let decoded = try JSONDecoder().decode(
                            AgentHandshakeRedeemResponse.self,
                            from: redeemData
                        )

                        if decoded.status == "approved", let rawKey = decoded.rawKey {
                            self.token = rawKey
                            self.tokenStore.saveToken(rawKey)
                            self.pendingUserCode = nil
                            self.pendingVerifyURL = nil
                            self.isAuthenticating = false
                            if let user = decoded.user {
                                self.user = user
                            }
                            if let teams = decoded.teams {
                                self.teams = teams
                            }
                            if let defaultTeamId = decoded.defaultTeamId {
                                self.activeTeamId = defaultTeamId
                                self.tokenStore.saveSelectedTeamId(defaultTeamId)
                            }
                            await self.refreshTeams()
                            return
                        } else if decoded.status == "expired" || decoded.status == "denied" {
                            self.error = "Authentication was \(decoded.status)."
                            break
                        }
                    } catch {
                        if Task.isCancelled { break }
                    }
                }

                self.isAuthenticating = false
                self.pendingUserCode = nil
                self.pendingVerifyURL = nil
            }

            self.pollingTask = task
            await task.value
        } catch {
            self.error = error.localizedDescription
            self.isAuthenticating = false
            self.pendingUserCode = nil
            self.pendingVerifyURL = nil
        }
    }

    public func cancelSignIn() {
        pollingTask?.cancel()
        pollingTask = nil
        isAuthenticating = false
        pendingUserCode = nil
        pendingVerifyURL = nil
    }

    public func signInWithToken(_ rawToken: String) async {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.error = "API token cannot be empty."
            return
        }
        error = nil
        token = trimmed
        tokenStore.saveToken(trimmed)
        await refreshTeams()
    }

    /**
     * Signs in with Pixerate's app sign-in sheet (`/auth/app`, OAuth 2.0 authorization code with
     * PKCE): `presenter` shows the page (an `ASWebAuthenticationSession` sheet by default), the
     * person signs in if needed and taps Continue, and the one-time code that comes back on
     * `callbackScheme` is traded for a personal API key, saved like the device handshake's.
     * Cancelling sets no error. `deviceName` labels the key (e.g. "Swash (Mac)").
     */
    public func signInWithApp(
        clientId: String,
        callbackScheme: String,
        deviceName: String? = nil,
        presenter: (any PixerateWebAuthPresenter)? = nil
    ) async {
        cancelSignIn()
        isAuthenticating = true
        error = nil
        defer { isAuthenticating = false }

        let redirectURI = "\(callbackScheme)://auth"
        let verifier = PixerateAppSignIn.makeVerifier()
        let state = PixerateAppSignIn.makeVerifier()
        guard let url = PixerateAppSignIn.authorizeURL(
            baseURL: baseURL,
            clientId: clientId,
            redirectURI: redirectURI,
            challenge: PixerateAppSignIn.challenge(for: verifier),
            state: state
        ) else {
            error = PixerateAccountError.invalidURL("/auth/app").localizedDescription
            return
        }

        do {
            #if canImport(AuthenticationServices)
            let shown = presenter ?? SystemWebAuthPresenter()
            #else
            guard let shown = presenter else { throw PixerateAppSignInError.invalidCallback }
            #endif
            let callback = try await shown.authenticate(url: url, callbackScheme: callbackScheme)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first(where: { $0.name == name })?.value }
            guard value("state") == state else { throw PixerateAppSignInError.invalidCallback }
            if value("error") == "access_denied" { throw PixerateAppSignInError.cancelled }
            guard let code = value("code"), !code.isEmpty else { throw PixerateAppSignInError.invalidCallback }

            var req = URLRequest(url: endpointURL(path: "/api/auth/app/token"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: String] = [
                "grant_type": "authorization_code",
                "client_id": clientId,
                "code": code,
                "code_verifier": verifier,
                "redirect_uri": redirectURI,
            ]
            if let deviceName, !deviceName.isEmpty { body["device_name"] = deviceName }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: req)
            let decoded = try? JSONDecoder().decode(AppTokenResponse.self, from: data)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let rawKey = decoded?.token, !rawKey.isEmpty else {
                throw PixerateAppSignInError.refused(decoded?.error_description ?? "Sign-in failed. Try again.")
            }
            token = rawKey
            tokenStore.saveToken(rawKey)
            await refreshTeams()
        } catch PixerateAppSignInError.cancelled {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func refreshTeams() async {
        guard let token = token, !token.isEmpty else {
            return
        }

        do {
            let req = try authorizedRequest(path: "/api/teams", method: "GET")
            let (data, response) = try await session.data(for: req)

            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 {
                    signOut()
                    self.error = "Session expired or invalid API key."
                    return
                }
                if !(200..<300).contains(http.statusCode) {
                    self.error = "Failed to load teams (HTTP \(http.statusCode))."
                    return
                }
            }

            let decoded = try JSONDecoder().decode(TeamsListResponse.self, from: data)
            if let user = decoded.user {
                self.user = user
            } else if self.user == nil {
                self.user = AuthUser(id: "authenticated")
            }
            self.teams = decoded.teams

            let storedTeamId = tokenStore.loadSelectedTeamId() ?? activeTeamId
            if let storedTeamId, decoded.teams.contains(where: { $0.id == storedTeamId }) {
                self.activeTeamId = storedTeamId
            } else if let defaultId = decoded.defaultTeamId,
                      decoded.teams.contains(where: { $0.id == defaultId }) {
                self.activeTeamId = defaultId
                tokenStore.saveSelectedTeamId(defaultId)
            } else {
                self.activeTeamId = decoded.teams.first?.id
                if let firstId = self.activeTeamId {
                    tokenStore.saveSelectedTeamId(firstId)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func selectTeam(_ teamId: String) {
        activeTeamId = teamId
        tokenStore.saveSelectedTeamId(teamId)
    }

    public func updateTeam(id teamId: String, _ mutate: (inout Team) -> Void) {
        guard let index = teams.firstIndex(where: { $0.id == teamId }) else {
            return
        }
        mutate(&teams[index])
    }

    public func authorizedRequest(
        path: String,
        method: String = "POST",
        body: Data? = nil
    ) throws -> URLRequest {
        guard let token = token, !token.isEmpty else {
            throw PixerateAccountError.unauthenticated
        }
        let url = endpointURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    public func signOut() {
        cancelSignIn()
        token = nil
        user = nil
        teams = []
        activeTeamId = nil
        error = nil
        tokenStore.saveToken(nil)
        tokenStore.saveSelectedTeamId(nil)
    }

    /// The page the user opens to approve the device sign-in.
    ///
    /// The server's `verifyUrl` is used only when it points at the same scheme, host
    /// and port as `baseURL`. Behind a proxy the server can see its internal host
    /// (for example a Cloud Run `*.run.app` address that refuses direct visits), so
    /// any other host falls back to `baseURL + /auth/device?code=<userCode>`.
    func resolveVerifyURL(serverVerifyUrl: String?, userCode: String) -> URL {
        if let verifyStr = serverVerifyUrl,
           let parsed = URL(string: verifyStr),
           parsed.scheme?.lowercased() == baseURL.scheme?.lowercased(),
           let host = parsed.host?.lowercased(),
           host == baseURL.host?.lowercased(),
           parsed.port == baseURL.port {
            return parsed
        }
        var components = URLComponents(
            url: endpointURL(path: "/auth/device"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "code", value: userCode)]
        return components?.url ?? endpointURL(path: "/auth/device")
    }

    private func endpointURL(path: String) -> URL {
        let cleanBase = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanPath = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: cleanBase + cleanPath) ?? baseURL.appendingPathComponent(path)
    }

    private func openSystemBrowser(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}
