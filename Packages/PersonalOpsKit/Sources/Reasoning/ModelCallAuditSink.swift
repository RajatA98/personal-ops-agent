import Foundation
import Core

/// Where per-round model-call audits go (AGENT_DESIGN §2). Kept a protocol so the app can log
/// to disk / the unified log while tests capture in memory and assert on the metadata.
///
/// The audit records ONLY metadata — purpose, coarse input categories, provider name, whether
/// raw external content was included, and requested tool names + sanitized arg summaries. It
/// carries no tokens, no auth headers, and no raw prompt/response text (Safety Rule #5). The
/// `ModelCallAudit` schema itself (Core, Phase 0) has no field that could hold a secret.
public protocol ModelCallAuditSink: Sendable {
    func record(_ audit: ModelCallAudit)
}

/// In-memory recorder for tests and previews.
public final class InMemoryModelCallAuditSink: ModelCallAuditSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _audits: [ModelCallAudit] = []

    public init() {}

    public var audits: [ModelCallAudit] {
        lock.withLock { _audits }
    }

    public func record(_ audit: ModelCallAudit) {
        lock.withLock { _audits.append(audit) }
    }
}

/// Production sink that emits each audit through the `RedactingLogger` as a compact, secret-free
/// line. Even if a tool-argument summary somehow contained a key-shaped value, the logger scrubs
/// it (Safety Rule #5) — but by construction the audit never carries tokens or headers.
public struct LoggingModelCallAuditSink: ModelCallAuditSink {
    private let logger: RedactingLogger

    public init(logger: RedactingLogger = RedactingLogger(category: "model-call")) {
        self.logger = logger
    }

    public func record(_ audit: ModelCallAudit) {
        let tools = audit.toolCallsRequested.isEmpty ? "none" : audit.toolCallsRequested.joined(separator: ", ")
        let categories = audit.inputCategories.map(\.rawValue).joined(separator: ",")
        logger.log(.info, """
        model-call purpose=\(audit.purpose.rawValue) provider=\(audit.provider) \
        round=\(audit.roundCount) rawExternal=\(audit.includedRawExternalContent) \
        inputs=[\(categories)] tools=[\(tools)]
        """)
    }
}
