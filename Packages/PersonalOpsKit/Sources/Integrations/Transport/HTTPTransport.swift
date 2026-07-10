import Foundation
import Core

/// The subset of `URLSession` the integration clients depend on. Abstracted so tests can
/// inject a `URLProtocol`-backed session (mocked transport) and exercise the *real*
/// request-building / decoding path without ever hitting the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production transport over a real `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AppError.network(.malformedResponse)
            }
            return (data, http)
        } catch let error as AppError {
            throw error
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut: throw AppError.network(.timeout)
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .dataNotAllowed:
                throw AppError.network(.offline)
            default:
                throw AppError.network(.malformedResponse)
            }
        }
    }
}

/// Maps a completed HTTP response to a typed `AppError`, given the `DataSource` the call
/// belongs to (so an auth failure becomes a *source-specific* reconnect state).
public enum HTTPErrorMapper {
    /// Returns `nil` if the status is success (2xx); otherwise the mapped error.
    public static func error(for status: Int, source: DataSource, body: Data?) -> AppError? {
        switch status {
        case 200...299:
            return nil
        case 401:
            // Access token rejected — expired or revoked. The refresh path distinguishes
            // the two (invalid_grant ⇒ revoked); a bare 401 on an API call means the token
            // needs refreshing, which the authenticator will attempt.
            return .integration(.tokenExpired(source: source))
        case 403:
            // Could be rate-limit ("rateLimitExceeded") or a genuine permission problem.
            if let body, let text = String(data: body, encoding: .utf8),
               text.contains("rateLimitExceeded") || text.contains("userRateLimitExceeded") {
                return .integration(.rateLimited(source: source))
            }
            return .integration(.permissionWithheld(source: source))
        case 429:
            return .integration(.rateLimited(source: source))
        case 500...599:
            return .integration(.unavailable(source: source, reason: "Server error (\(status))"))
        default:
            return .network(.httpStatus(status))
        }
    }
}

/// Runs an async operation under a `RetryPolicy`, retrying only `AppError`s that report
/// `isRetryable`. Backoff sleeps use the policy's `delay(forAttempt:)`. This is the single
/// sanctioned retry path (SETUP conventions: never hand-roll retry loops).
public func withRetry<T: Sendable>(
    policy: RetryPolicy,
    sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
    operation: @Sendable () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        do {
            return try await operation()
        } catch let error as AppError {
            guard error.isRetryable, policy.shouldRetry(afterAttempt: attempt) else { throw error }
            try await sleep(policy.delay(forAttempt: attempt))
            attempt += 1
        }
    }
}
