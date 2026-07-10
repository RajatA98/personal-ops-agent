import Foundation

/// Model-call audit record — AGENT_DESIGN.md §2. One is written per LLM round from
/// Phase 5 onward. This is the *schema only*; there is no LLM integration in Phase 0.
///
/// Deliberately records metadata, never payload: no tokens, no auth headers, no raw
/// prompt/response text (Safety Rule #5). `toolCallsRequested` holds tool *names* (and,
/// later, sanitized argument summaries), which are safe to audit.
public struct ModelCallAudit: Equatable, Sendable, Codable {

    public enum Purpose: String, Equatable, Sendable, Codable {
        case morningBriefing
        case weeklyReview
        case classification
        case goalPlanning
        case qanda
        case voice
    }

    /// Categories of input that fed the call — coarse enough to audit without storing content.
    public enum InputCategory: String, Equatable, Sendable, Codable {
        case calendar
        case gmail
        case healthKit
        case memory
        case goals
        case preferences
        case userMessage
    }

    public let timestamp: Date
    public let purpose: Purpose
    public let inputCategories: [InputCategory]
    public let provider: String
    /// Whether raw external content (e.g. an email body) was included in the prompt.
    public let includedRawExternalContent: Bool
    public let toolCallsRequested: [String]
    public let roundCount: Int

    public init(timestamp: Date,
                purpose: Purpose,
                inputCategories: [InputCategory],
                provider: String,
                includedRawExternalContent: Bool,
                toolCallsRequested: [String] = [],
                roundCount: Int = 1) {
        self.timestamp = timestamp
        self.purpose = purpose
        self.inputCategories = inputCategories
        self.provider = provider
        self.includedRawExternalContent = includedRawExternalContent
        self.toolCallsRequested = toolCallsRequested
        self.roundCount = roundCount
    }
}
