import Foundation

/// Context-assembly helpers (AGENT_DESIGN §4). Deterministic flows inject a compact,
/// structured JSON snapshot of their context; the model never fetches its own data for them.
/// Budgets are *targets* (Gemini Flash's window is large) — kept small so cost and latency stay
/// predictable and outputs stay grounded.
public enum AgentContext {

    /// Encode any `Encodable` context object (e.g. `MorningBriefing`, `WeeklyReview`) to a
    /// compact, deterministic JSON string suitable for injecting into a prompt. Dates are ISO-8601
    /// and keys are sorted so the same context always serializes identically (fixture-stable).
    public static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

/// A deliberately simple, provider-neutral token estimator used only for BUDGET CONFORMANCE
/// checks (§6 fixture #6) and to keep assembled context disciplined. It is an estimate, not a
/// tokenizer: ~4 characters per token is a standard rough rule for English + JSON. It never
/// gates a real API call — it only lets tests assert "this assembled context is within target".
public enum TokenBudget {
    /// Per-flow target budgets from AGENT_DESIGN §4 (in estimated tokens).
    public static let morningBriefing = 4_000
    public static let weeklyReview = 8_000
    public static let classification = 2_000
    public static let goalPlanning = 6_000
    public static let qaPreamble = 1_500

    /// Estimate the token count of a string (~4 chars/token).
    public static func estimate(_ text: String) -> Int {
        Int((Double(text.count) / 4.0).rounded(.up))
    }

    /// Estimate the total token count of an assembled transcript.
    public static func estimate(messages: [String]) -> Int {
        messages.reduce(0) { $0 + estimate($1) }
    }
}
