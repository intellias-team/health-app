import Foundation
import CoreModels
import Networking
#if canImport(AuthenticationServices) && canImport(UIKit)
import AuthKit
#endif

/// Oura is integrated server-side: the backend holds the OAuth tokens (KMS-encrypted), receives webhooks and
/// syncs hourly. The app only starts the OAuth flow, triggers on-demand syncs and disconnects.
///
/// Flow: `POST /v1/integrations/oura/authorize` → `{authorizeUrl}` → ASWebAuthenticationSession →
/// Oura consent → backend callback → `302 healthapp://oura/connected` (or `healthapp://oura/error?reason=`).
public struct OuraConnectionService: OuraService {
    public enum OuraError: Error, LocalizedError, Equatable {
        case denied(String)
        case unsupported
        public var errorDescription: String? {
            switch self {
            case .denied(let r): return "Oura connection failed: \(r)"
            case .unsupported: return "Oura connection isn't supported on this platform."
            }
        }
    }

    private let api: APIClient

    public init(api: APIClient) { self.api = api }

    /// Parses the backend's final redirect.
    public static func parseCallback(_ url: URL) -> Result<Void, OuraError> {
        guard url.scheme == "healthapp", url.host == "oura" else { return .failure(.denied("unexpected callback")) }
        if url.path == "/connected" { return .success(()) }
        let reason = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "reason" }?.value
        return .failure(.denied(reason ?? "unknown"))
    }

    public func connect() async throws {
        #if canImport(AuthenticationServices) && canImport(UIKit)
        let authorize = try await api.send(API.ouraAuthorize())
        // Not ephemeral: users are likely already signed in to Oura in Safari.
        let callback = try await Self.present(url: authorize.authorizeUrl)
        if case .failure(let error) = Self.parseCallback(callback) { throw error }
        // Kick off an initial backfill (last 30 days); the backend also syncs hourly and on webhooks.
        _ = try? await sync(from: LocalDate.today().adding(days: -30), to: LocalDate.today())
        #else
        throw OuraError.unsupported
        #endif
    }

    #if canImport(AuthenticationServices) && canImport(UIKit)
    @MainActor
    private static func present(url: URL) async throws -> URL {
        let authenticator = WebAuthenticator()
        return try await authenticator.authenticate(url: url, callbackScheme: "healthapp", ephemeral: false)
    }
    #endif

    public func disconnect() async throws {
        _ = try await api.send(API.ouraDisconnect())
    }

    public func sync(from: LocalDate?, to: LocalDate?) async throws -> OuraSyncResult {
        try await api.send(try API.ouraSync(from: from, to: to))
    }
}
