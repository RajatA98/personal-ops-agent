import Foundation

/// Typed, exhaustive application error model. Every failure path in later phases maps
/// to one of these cases so the UI can degrade *visibly* (Safety Rule #6) instead of
/// crashing or silently omitting data.
public enum AppError: Error, Equatable, Sendable {
    case network(NetworkError)
    case integration(IntegrationError)
    case auth(AuthError)
    case data(DataError)
    case reasoning(ReasoningError)
    case voice(VoiceError)
    case configuration(ConfigError)
}

public enum NetworkError: Equatable, Sendable {
    case timeout
    case offline
    case httpStatus(Int)
    case malformedResponse
}

public enum IntegrationError: Equatable, Sendable {
    case tokenExpired(source: DataSource)
    case tokenRevoked(source: DataSource)
    case permissionWithheld(source: DataSource)
    case rateLimited(source: DataSource)
    case unavailable(source: DataSource, reason: String)
}

public enum AuthError: Equatable, Sendable {
    case consentCancelled
    case keychainFailure
    case refreshFailed
}

public enum DataError: Equatable, Sendable {
    case notFound
    case migrationFailed(String)
    case conflict(String)
    case persistenceFailure(String)
}

public enum ReasoningError: Equatable, Sendable {
    case providerUnavailable
    case invalidResponse
    case roundBudgetExceeded
}

public enum VoiceError: Equatable, Sendable {
    case sttUnavailable
    case ttsFailed
    case lowConfidenceTranscript
}

public enum ConfigError: Error, Equatable, Sendable {
    case missingKey(String)
    case malformedLine(String)
    case fileNotFound(String)
}

public extension AppError {

    /// Whether the failure is worth surfacing directly to the user (vs. a transient
    /// internal condition a retry may absorb).
    var isUserVisible: Bool {
        switch self {
        case .integration, .auth, .configuration, .voice:
            return true
        case .network, .data, .reasoning:
            return true
        }
    }

    /// Whether a retry (per `RetryPolicy`) could plausibly succeed. Configuration and
    /// permission problems are never retried — they need user action.
    var isRetryable: Bool {
        switch self {
        case .network(let n):
            switch n {
            case .timeout, .offline, .httpStatus, .malformedResponse: return true
            }
        case .integration(let i):
            switch i {
            case .tokenExpired, .rateLimited, .unavailable: return true
            case .tokenRevoked, .permissionWithheld: return false
            }
        case .reasoning(let r):
            switch r {
            case .providerUnavailable, .invalidResponse: return true
            case .roundBudgetExceeded: return false
            }
        case .auth, .data, .voice, .configuration:
            return false
        }
    }

    /// The user-visible degraded state this error should render as, if any.
    var degradedState: DegradedState? {
        switch self {
        case .integration(let i):
            switch i {
            case .tokenExpired(let s), .tokenRevoked(let s):
                return .reconnectRequired(source: s)
            case .permissionWithheld(let s):
                return .permissionWithheld(source: s)
            case .rateLimited(let s):
                return .sourceUnavailable(source: s, reason: "Rate limited")
            case .unavailable(let s, let reason):
                return .sourceUnavailable(source: s, reason: reason)
            }
        case .network:
            return .sourceUnavailable(source: .calendar, reason: "Network unavailable")
        default:
            return nil
        }
    }

    /// A short, secret-free message safe to show the user. Never echoes key values.
    var userMessage: String {
        switch self {
        case .network(.offline):
            return "You appear to be offline. Some information may be out of date."
        case .network:
            return "A network problem interrupted syncing. Retrying."
        case .integration(.tokenRevoked(let s)), .integration(.tokenExpired(let s)):
            return "\(s.displayName) needs to be reconnected."
        case .integration(.permissionWithheld(let s)):
            return "\(s.displayName) access is turned off. Related suggestions are unavailable."
        case .integration(.rateLimited(let s)):
            return "\(s.displayName) is temporarily rate-limited."
        case .integration(.unavailable(let s, _)):
            return "\(s.displayName) is currently unavailable."
        case .auth:
            return "Sign-in could not be completed."
        case .data:
            return "A local data problem occurred."
        case .reasoning:
            return "The assistant is temporarily unavailable."
        case .voice:
            return "Voice is temporarily unavailable."
        case .configuration(.missingKey(let name)):
            // Names the *key*, never a value.
            return "Missing configuration: \(name). See docs/SETUP.md."
        case .configuration:
            return "The local configuration file is invalid. See docs/SETUP.md."
        }
    }
}

public extension DataSource {
    var displayName: String {
        switch self {
        case .calendar: return "Calendar"
        case .gmail: return "Gmail"
        case .healthKit: return "Health"
        case .reasoning: return "Assistant"
        case .iMessage: return "Messages"
        }
    }
}
