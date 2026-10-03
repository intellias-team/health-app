#if canImport(AuthenticationServices) && canImport(UIKit) && canImport(CryptoKit)
import Foundation
import CoreModels

/// Cognito User Pool configuration (from Config.xcconfig → Info.plist).
public struct CognitoConfig: Sendable, Equatable {
    /// Hosted UI domain: a full host ("auth.example.com", "myapp.auth.eu-west-1.amazoncognito.com") or just the prefix.
    public var domain: String
    public var clientId: String
    public var region: String
    public var redirectURI: String
    public var signOutURI: String
    public var scopes: [String]

    public init(domain: String, clientId: String, region: String, redirectURI: String = "healthapp://auth/callback",
                signOutURI: String = "healthapp://auth/signout", scopes: [String] = ["openid", "email", "profile"]) {
        self.domain = domain; self.clientId = clientId; self.region = region
        self.redirectURI = redirectURI; self.signOutURI = signOutURI; self.scopes = scopes
    }

    public var host: String {
        let d = domain.replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return d.contains(".") ? d : "\(d).auth.\(region).amazoncognito.com"
    }
}

struct StoredTokens: Codable, Sendable {
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

/// Cognito Hosted UI sign-in with Sign in with Apple as the federated IdP, PKCE (S256) and refresh tokens.
/// Tokens are stored in the Keychain (AfterFirstUnlockThisDeviceOnly).
public actor CognitoAuthService: AuthService {
    private let config: CognitoConfig
    private let keychain: KeychainStore
    private let session: URLSession
    private var tokens: StoredTokens?
    private var refreshTask: Task<StoredTokens, Error>?
    private static let tokenKey = "cognito.tokens"
    /// Refresh when the access token expires within this window.
    private let refreshLeeway: TimeInterval = 5 * 60

    public enum AuthError: Error, LocalizedError, Equatable {
        case signedOut, stateMismatch, missingCode, tokenExchange(String)
        public var errorDescription: String? {
            switch self {
            case .signedOut: return "You're signed out."
            case .stateMismatch: return "Sign-in response didn't match the request. Please try again."
            case .missingCode: return "Sign-in didn't return an authorization code."
            case .tokenExchange(let m): return "Couldn't complete sign-in: \(m)"
            }
        }
    }

    public init(config: CognitoConfig, keychain: KeychainStore = KeychainStore(), session: URLSession = .shared) {
        self.config = config; self.keychain = keychain; self.session = session
        self.tokens = try? keychain.codable(StoredTokens.self, for: Self.tokenKey)
    }

    public func currentSession() async -> AuthSession? {
        guard let tokens else { return nil }
        return Self.session(from: tokens)
    }

    public func signIn() async throws -> AuthSession {
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeState()
        var c = URLComponents()
        c.scheme = "https"; c.host = config.host; c.path = "/oauth2/authorize"
        c.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "identity_provider", value: "SignInWithApple"),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = c.url else { throw AuthError.tokenExchange("Invalid Cognito domain") }
        let scheme = URL(string: config.redirectURI)?.scheme ?? "healthapp"
        let callback = try await Self.presentWebAuth(url: url, scheme: scheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else { throw AuthError.stateMismatch }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw AuthError.missingCode }

        let response = try await tokenRequest([
            "grant_type": "authorization_code", "client_id": config.clientId, "code": code,
            "redirect_uri": config.redirectURI, "code_verifier": verifier,
        ])
        guard let refresh = response.refresh_token, let id = response.id_token else { throw AuthError.tokenExchange("Missing tokens") }
        let stored = StoredTokens(idToken: id, accessToken: response.access_token, refreshToken: refresh,
                                  expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in)))
        try save(stored)
        return Self.session(from: stored)
    }

    public func accessToken() async throws -> String { try await accessToken(forceRefresh: false) }

    /// Returns a valid access token, refreshing (once, de-duplicated) if it's about to expire or `forceRefresh`.
    public func accessToken(forceRefresh: Bool) async throws -> String {
        guard let current = tokens else { throw AuthError.signedOut }
        if !forceRefresh, current.expiresAt.timeIntervalSinceNow > refreshLeeway { return current.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let task = Task { () throws -> StoredTokens in
            let response = try await self.tokenRequest([
                "grant_type": "refresh_token", "client_id": self.config.clientId, "refresh_token": current.refreshToken,
            ])
            return StoredTokens(idToken: response.id_token ?? current.idToken, accessToken: response.access_token,
                                refreshToken: response.refresh_token ?? current.refreshToken,
                                expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in)))
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let refreshed = try await task.value
            try save(refreshed)
            return refreshed.accessToken
        } catch AuthError.tokenExchange(let message) where message.contains("invalid_grant") {
            await signOut()
            throw AuthError.signedOut
        }
    }

    public func signOut() async {
        if let refresh = tokens?.refreshToken {
            // Best-effort revoke; ignore errors (offline sign-out still clears local tokens).
            _ = try? await formPost(path: "/oauth2/revoke", ["token": refresh, "client_id": config.clientId])
        }
        tokens = nil
        keychain.remove(Self.tokenKey)
    }

    // MARK: Private

    @MainActor
    private static func presentWebAuth(url: URL, scheme: String) async throws -> URL {
        let authenticator = WebAuthenticator()
        return try await authenticator.authenticate(url: url, callbackScheme: scheme, ephemeral: true)
    }

    private func save(_ t: StoredTokens) throws {
        tokens = t
        try keychain.setCodable(t, for: Self.tokenKey)
    }

    private struct TokenResponse: Decodable {
        var id_token: String?
        var access_token: String
        var refresh_token: String?
        var expires_in: Int
    }

    private func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        let (data, status) = try await formPost(path: "/oauth2/token", form)
        guard (200..<300).contains(status) else {
            throw AuthError.tokenExchange(String(decoding: data, as: UTF8.self))
        }
        do { return try JSONDecoder().decode(TokenResponse.self, from: data) }
        catch { throw AuthError.tokenExchange("Unexpected token response") }
    }

    private func formPost(path: String, _ form: [String: String]) async throws -> (Data, Int) {
        var c = URLComponents()
        c.scheme = "https"; c.host = config.host; c.path = path
        var request = URLRequest(url: c.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func session(from t: StoredTokens) -> AuthSession {
        let claims = PKCE.jwtClaims(t.idToken) ?? [:]
        return AuthSession(userId: claims["sub"] as? String ?? "unknown", email: claims["email"] as? String, expiresAt: t.expiresAt)
    }
}
#endif
