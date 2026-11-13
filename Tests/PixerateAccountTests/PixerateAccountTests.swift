import Foundation
import XCTest
@testable import PixerateAccount

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class PixerateAccountTests: XCTestCase {
    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testInMemoryTokenStore() {
        let store = InMemoryTokenStore()
        XCTAssertNil(store.loadToken())
        XCTAssertNil(store.loadSelectedTeamId())

        store.saveToken("pix_live_token123")
        store.saveSelectedTeamId("team_abc")

        XCTAssertEqual(store.loadToken(), "pix_live_token123")
        XCTAssertEqual(store.loadSelectedTeamId(), "team_abc")

        store.saveToken(nil)
        store.saveSelectedTeamId(nil)

        XCTAssertNil(store.loadToken())
        XCTAssertNil(store.loadSelectedTeamId())
    }

    func testModelDecoding() throws {
        let json = """
        {
            "teams": [
                {
                    "id": "team_1",
                    "name": "Alpha Studio",
                    "ownerId": "user_1",
                    "planId": "pro",
                    "fuelBalance": 420,
                    "memberIds": ["user_1"],
                    "role": "owner"
                }
            ],
            "defaultTeamId": "team_1",
            "user": {
                "id": "user_1",
                "email": "artist@pixerate.com",
                "displayName": "Jazz Artist",
                "emailVerified": true
            }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(TeamsListResponse.self, from: json)
        XCTAssertEqual(decoded.teams.count, 1)
        XCTAssertEqual(decoded.teams[0].name, "Alpha Studio")
        XCTAssertEqual(decoded.teams[0].fuelBalance, 420)
        XCTAssertEqual(decoded.teams[0].role, .owner)
        XCTAssertEqual(decoded.defaultTeamId, "team_1")
        XCTAssertEqual(decoded.user?.displayName, "Jazz Artist")
    }

    @MainActor
    func testHandshakePollingAndRedemptionFlow() async throws {
        let store = InMemoryTokenStore()
        let session = makeMockSession()
        let client = PixerateAccountClient(
            baseURL: URL(string: "https://pixerate.test")!,
            tokenStore: store,
            session: session
        )
        client.pollIntervalNanoseconds = 10_000_000

        nonisolated(unsafe) var redeemPollCount = 0
        nonisolated(unsafe) var openedVerifyURL: URL?

        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            if path == "/api/auth/handshake" {
                let body = """
                {
                    "id": "hs_1",
                    "userCode": "PIX-4829",
                    "deviceCode": "pix_dev_secret123",
                    "expiresAt": "2026-11-07T13:00:00Z",
                    "verifyUrl": "https://pixerate.test/auth/device?code=PIX-4829"
                }
                """.data(using: .utf8)!
                return (resp, body)
            }

            if path == "/api/auth/handshake/redeem" {
                redeemPollCount += 1
                if redeemPollCount < 2 {
                    let pendingBody = """
                    { "status": "pending" }
                    """.data(using: .utf8)!
                    return (resp, pendingBody)
                } else {
                    let approvedBody = """
                    {
                        "status": "approved",
                        "rawKey": "pix_live_minted_key_999",
                        "apiKeyId": "key_999"
                    }
                    """.data(using: .utf8)!
                    return (resp, approvedBody)
                }
            }

            if path == "/api/teams" {
                let authHeader = request.value(forHTTPHeaderField: "Authorization")
                XCTAssertEqual(authHeader, "Bearer pix_live_minted_key_999")
                let teamsBody = """
                {
                    "teams": [
                        {
                            "id": "team_personal",
                            "name": "Personal Team",
                            "ownerId": "u_1",
                            "planId": "free",
                            "fuelBalance": 100,
                            "memberIds": ["u_1"],
                            "role": "owner"
                        },
                        {
                            "id": "team_studio",
                            "name": "Studio Team",
                            "ownerId": "u_1",
                            "planId": "pro",
                            "fuelBalance": 2500,
                            "memberIds": ["u_1"],
                            "role": "owner"
                        }
                    ],
                    "defaultTeamId": "team_personal",
                    "user": {
                        "id": "u_1",
                        "email": "painter@pixerate.com",
                        "displayName": "Painter"
                    }
                }
                """.data(using: .utf8)!
                return (resp, teamsBody)
            }

            throw URLError(.fileDoesNotExist)
        }

        await client.signInWithBrowser(
            agentName: "Swash",
            clientSource: "swash",
            openURL: { url in
                openedVerifyURL = url
            }
        )

        XCTAssertEqual(openedVerifyURL?.absoluteString, "https://pixerate.test/auth/device?code=PIX-4829")
        XCTAssertGreaterThanOrEqual(redeemPollCount, 2)
        XCTAssertTrue(client.isAuthenticated)
        XCTAssertEqual(client.token, "pix_live_minted_key_999")
        XCTAssertEqual(store.loadToken(), "pix_live_minted_key_999")
        XCTAssertEqual(client.user?.displayName, "Painter")
        XCTAssertEqual(client.teams.count, 2)
        XCTAssertEqual(client.activeTeamId, "team_personal")
        XCTAssertEqual(client.fuelBalance, 100)
        XCTAssertTrue(client.canUseAI)

        let req = try client.authorizedRequest(path: "/api/writing/partner", method: "POST", body: Data("{}".utf8))
        XCTAssertEqual(req.url?.absoluteString, "https://pixerate.test/api/writing/partner")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer pix_live_minted_key_999")

        client.selectTeam("team_studio")
        XCTAssertEqual(client.activeTeam?.name, "Studio Team")
        XCTAssertEqual(client.fuelBalance, 2500)
        XCTAssertEqual(store.loadSelectedTeamId(), "team_studio")

        client.signOut()
        XCTAssertFalse(client.isAuthenticated)
        XCTAssertNil(client.token)
        XCTAssertNil(store.loadToken())
        XCTAssertEqual(client.teams.count, 0)
        XCTAssertThrowsError(try client.authorizedRequest(path: "/api/writing/partner"))
    }

    @MainActor
    func testRestoreSession() async throws {
        let store = InMemoryTokenStore(token: "pix_live_saved", selectedTeamId: "team_2")
        let client = PixerateAccountClient(
            baseURL: URL(string: "https://pixerate.test")!,
            tokenStore: store,
            session: makeMockSession()
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/teams")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer pix_live_saved")
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = """
            {
                "teams": [
                    { "id": "team_1", "name": "One", "ownerId": "u_1" },
                    { "id": "team_2", "name": "Two", "ownerId": "u_1" }
                ],
                "defaultTeamId": "team_1",
                "user": { "id": "u_1", "displayName": "Ada" }
            }
            """.data(using: .utf8)!
            return (resp, body)
        }

        await client.restoreSession()
        XCTAssertTrue(client.isAuthenticated)
        XCTAssertEqual(client.activeTeamId, "team_2")
        XCTAssertEqual(client.activeTeam?.name, "Two")
    }

    @MainActor
    func testSignInIgnoresVerifyUrlOnForeignHost() async throws {
        let client = PixerateAccountClient(
            baseURL: URL(string: "https://pixerate.test")!,
            tokenStore: InMemoryTokenStore(),
            session: makeMockSession()
        )
        client.pollIntervalNanoseconds = 10_000_000

        nonisolated(unsafe) var openedVerifyURL: URL?

        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path == "/api/auth/handshake" {
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                let body = """
                {
                    "id": "hs_run",
                    "userCode": "PIX-7777",
                    "deviceCode": "pix_dev_run",
                    "expiresAt": "2026-11-07T13:00:00Z",
                    "verifyUrl": "https://pixerate-web-92395469338.us-east4.run.app/auth/device?code=PIX-7777"
                }
                """.data(using: .utf8)!
                return (resp, body)
            }
            let gone = HTTPURLResponse(
                url: request.url!, statusCode: 410, httpVersion: nil, headerFields: nil
            )!
            return (gone, Data())
        }

        await client.signInWithBrowser(openURL: { url in openedVerifyURL = url })

        XCTAssertEqual(
            openedVerifyURL?.absoluteString,
            "https://pixerate.test/auth/device?code=PIX-7777"
        )
    }

    @MainActor
    func testResolveVerifyURL() {
        let client = PixerateAccountClient(
            baseURL: URL(string: "https://pixerate.com")!,
            tokenStore: InMemoryTokenStore(),
            session: makeMockSession()
        )

        XCTAssertEqual(
            client.resolveVerifyURL(
                serverVerifyUrl: "https://PIXERATE.com/auth/device?code=PIX-1&x=1",
                userCode: "PIX-1"
            ).absoluteString,
            "https://PIXERATE.com/auth/device?code=PIX-1&x=1"
        )

        let expected = "https://pixerate.com/auth/device?code=PIX-1"
        let rejected: [String?] = [
            "https://pixerate-web-92395469338.us-east4.run.app/auth/device?code=PIX-1",
            "http://pixerate.com/auth/device?code=PIX-1",
            "https://pixerate.com:8443/auth/device?code=PIX-1",
            "https://evil.example/auth/device?code=PIX-1",
            "/auth/device?code=PIX-1",
            nil
        ]
        for candidate in rejected {
            XCTAssertEqual(
                client.resolveVerifyURL(serverVerifyUrl: candidate, userCode: "PIX-1").absoluteString,
                expected,
                "verifyUrl \(candidate ?? "nil") should fall back to baseURL"
            )
        }
    }
}

// MARK: - App sign-in (authorization code + PKCE)

@MainActor
private final class FakeWebAuthPresenter: PixerateWebAuthPresenter {
    var shownURL: URL?
    let respond: (URL) throws -> URL
    init(_ respond: @escaping (URL) throws -> URL) { self.respond = respond }
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        shownURL = url
        XCTAssertEqual(callbackScheme, "swash")
        return try respond(url)
    }
}

private func query(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == name })?.value
}

extension PixerateAccountTests {
    func testPKCEChallengeMatchesRFC7636() {
        XCTAssertEqual(
            PixerateAppSignIn.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
        let v = PixerateAppSignIn.makeVerifier()
        XCTAssertEqual(v.count, 43)
        XCTAssertNotEqual(v, PixerateAppSignIn.makeVerifier())
    }

    @MainActor
    func testAppSignInTradesTheCodeForAKey() async throws {
        let store = InMemoryTokenStore()
        let client = PixerateAccountClient(baseURL: URL(string: "https://pixerate.test")!, tokenStore: store, session: makeMockSession())
        nonisolated(unsafe) var tokenBody: [String: Any] = [:]
        nonisolated(unsafe) var challenge: String?
        MockURLProtocol.requestHandler = { @Sendable request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            switch request.url?.path {
            case "/api/auth/app/token":
                let data = request.httpBodyStream.map { s -> Data in
                    s.open(); defer { s.close() }
                    var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
                    while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
                    return d
                } ?? request.httpBody ?? Data()
                tokenBody = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                return (resp, Data(#"{"token":"pix_live_app_key","apiKeyId":"key_app"}"#.utf8))
            case "/api/teams":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer pix_live_app_key")
                return (resp, Data(#"{"teams":[{"id":"t1","name":"Personal","ownerId":"u_1","planId":"free","fuelBalance":100,"memberIds":["u_1"],"role":"owner"}],"defaultTeamId":"t1","user":{"id":"u_1","email":"a@b.c","displayName":"Ada"}}"#.utf8))
            default:
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }
        let presenter = FakeWebAuthPresenter { url in
            challenge = query(url, "code_challenge")
            return URL(string: "swash://auth?code=one-time&state=\(query(url, "state")!)")!
        }

        await client.signInWithApp(clientId: "swash", callbackScheme: "swash", deviceName: "Mac", presenter: presenter)

        let shown = try XCTUnwrap(presenter.shownURL)
        XCTAssertEqual(shown.path, "/auth/app")
        XCTAssertEqual(query(shown, "client_id"), "swash")
        XCTAssertEqual(query(shown, "redirect_uri"), "swash://auth")
        XCTAssertEqual(query(shown, "code_challenge_method"), "S256")
        XCTAssertEqual(tokenBody["code"] as? String, "one-time")
        XCTAssertEqual(tokenBody["device_name"] as? String, "Mac")
        XCTAssertEqual(PixerateAppSignIn.challenge(for: tokenBody["code_verifier"] as? String ?? ""), challenge)
        XCTAssertEqual(store.loadToken(), "pix_live_app_key")
        XCTAssertTrue(client.isAuthenticated)
        XCTAssertEqual(client.user?.displayName, "Ada")
        XCTAssertNil(client.error)
        XCTAssertFalse(client.isAuthenticating)
    }

    @MainActor
    func testAppSignInRefusesAForeignStateAndKeepsQuietWhenCancelled() async throws {
        let store = InMemoryTokenStore()
        let client = PixerateAccountClient(baseURL: URL(string: "https://pixerate.test")!, tokenStore: store, session: makeMockSession())
        MockURLProtocol.requestHandler = { @Sendable request in
            XCTFail("No request expected, got \(request.url?.path ?? "")")
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        await client.signInWithApp(clientId: "swash", callbackScheme: "swash", presenter: FakeWebAuthPresenter { _ in URL(string: "swash://auth?code=x&state=forged")! })
        XCTAssertEqual(client.error, PixerateAppSignInError.invalidCallback.localizedDescription)
        XCTAssertNil(store.loadToken())

        await client.signInWithApp(clientId: "swash", callbackScheme: "swash", presenter: FakeWebAuthPresenter { url in URL(string: "swash://auth?error=access_denied&state=\(query(url, "state")!)")! })
        XCTAssertNil(client.error)

        await client.signInWithApp(clientId: "swash", callbackScheme: "swash", presenter: FakeWebAuthPresenter { _ in throw PixerateAppSignInError.cancelled })
        XCTAssertNil(client.error)
        XCTAssertFalse(client.isAuthenticated)
    }

    @MainActor
    func testAppSignInShowsTheServersRefusal() async throws {
        let client = PixerateAccountClient(baseURL: URL(string: "https://pixerate.test")!, tokenStore: InMemoryTokenStore(), session: makeMockSession())
        MockURLProtocol.requestHandler = { @Sendable request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (resp, Data(#"{"error":"invalid_grant","error_description":"This sign-in code has expired. Sign in again."}"#.utf8))
        }
        await client.signInWithApp(clientId: "swash", callbackScheme: "swash", presenter: FakeWebAuthPresenter { url in URL(string: "swash://auth?code=old&state=\(query(url, "state")!)")! })
        XCTAssertEqual(client.error, "This sign-in code has expired. Sign in again.")
        XCTAssertFalse(client.isAuthenticated)
    }
}
