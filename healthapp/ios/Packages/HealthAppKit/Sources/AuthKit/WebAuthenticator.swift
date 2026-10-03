#if canImport(AuthenticationServices) && canImport(UIKit)
import Foundation
import AuthenticationServices
import UIKit

/// Presents an `ASWebAuthenticationSession` and returns the callback URL.
/// Shared by Cognito sign-in and the Oura OAuth connect flow.
@MainActor
public final class WebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    public enum WebAuthError: Error, LocalizedError {
        case cancelled
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .cancelled: return "Sign-in was cancelled."
            case .failed(let m): return m
            }
        }
    }

    private var session: ASWebAuthenticationSession?

    public override init() { super.init() }

    /// - Parameters:
    ///   - ephemeral: true to avoid sharing cookies with Safari (used for Cognito so "Sign out" really signs out).
    public func authenticate(url: URL, callbackScheme: String, ephemeral: Bool = true) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                Task { @MainActor in self?.session = nil }
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: WebAuthError.cancelled)
                } else if let error {
                    continuation.resume(throwing: WebAuthError.failed(error.localizedDescription))
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: WebAuthError.failed("No callback URL."))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = ephemeral
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: WebAuthError.failed("Couldn't start the sign-in session."))
            }
        }
    }

    public nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return key }
            if let scene = scenes.first { return UIWindow(windowScene: scene) }
            return ASPresentationAnchor()
        }
    }
}
#endif
