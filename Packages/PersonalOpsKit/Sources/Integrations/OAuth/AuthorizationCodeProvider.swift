import Foundation
import Core

/// Presents the OAuth consent UI and returns the callback URL Google redirects to. Abstracted
/// behind a protocol so the whole token flow is testable with a canned-code fake (a real
/// browser can't run in `swift test`), while production uses `ASWebAuthenticationSession`.
public protocol AuthorizationCodeProvider: Sendable {
    /// Load `authorizationURL` in a secure web session and return the redirect callback URL
    /// once Google redirects to `callbackScheme`. Throws `AppError.auth(.consentCancelled)`
    /// if the user cancels.
    func authorize(authorizationURL: URL, callbackScheme: String) async throws -> URL
}

#if canImport(AuthenticationServices)
import AuthenticationServices

/// Real consent presenter over `ASWebAuthenticationSession`. Uses the system's secure
/// browser (not an embeddable WKWebView), which Google requires for OAuth and which keeps
/// the app out of the credential path entirely.
public final class WebAuthorizationCodeProvider: NSObject, AuthorizationCodeProvider, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {

    /// `true` uses a private/ephemeral session (no shared cookies). We default to `false` so
    /// an already-signed-in Google session in the system browser can be reused (fewer taps),
    /// while still never exposing credentials to the app.
    private let prefersEphemeralSession: Bool

    public init(prefersEphemeralSession: Bool = false) {
        self.prefersEphemeralSession = prefersEphemeralSession
    }

    public func authorize(authorizationURL: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    if let asError = error as? ASWebAuthenticationSessionError,
                       asError.code == .canceledLogin {
                        continuation.resume(throwing: AppError.auth(.consentCancelled))
                    } else {
                        continuation.resume(throwing: AppError.auth(.refreshFailed))
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: AppError.auth(.refreshFailed))
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = prefersEphemeralSession
            // Presentation must start on the main thread.
            DispatchQueue.main.async {
                if !session.start() {
                    // start() only fails if it can't present; treat as cancellation.
                }
            }
        }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        // Find a key window to anchor the sheet to.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        return window ?? ASPresentationAnchor()
        #elseif canImport(AppKit)
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#endif
