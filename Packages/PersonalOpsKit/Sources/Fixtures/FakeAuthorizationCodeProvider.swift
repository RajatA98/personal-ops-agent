import Foundation
import Core
import Integrations

/// Fake `AuthorizationCodeProvider` that returns a canned callback URL instead of presenting
/// a browser — lets the connect/token-exchange flow be unit-tested end to end.
public final class FakeAuthorizationCodeProvider: AuthorizationCodeProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let code: String
    private let error: AppError?
    private var _capturedURL: URL?

    /// - Parameters:
    ///   - code: the authorization code to echo back on the callback.
    ///   - error: if set, `authorize` throws this instead (e.g. simulate user cancellation).
    public init(code: String = "test-auth-code", error: AppError? = nil) {
        self.code = code
        self.error = error
    }

    /// The authorization URL the flow asked to present (for asserting request params).
    public var capturedURL: URL? { lock.withLock { _capturedURL } }

    public func authorize(authorizationURL: URL, callbackScheme: String) async throws -> URL {
        lock.withLock { _capturedURL = authorizationURL }
        if let error { throw error }
        // Echo back the `state` from the request so `parseCallback` validates it.
        let state = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        return URL(string: "\(callbackScheme):/oauth2redirect?code=\(code)&state=\(state)")!
    }
}
