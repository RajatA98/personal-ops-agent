import Foundation
import Core

/// # HealthKit pacing (Phase 3C) — a pure, deterministic data transform on plan values
///
/// Pacing reads recent **sleep / resting-heart-rate / HRV** summaries (`HealthSummary`, a Core
/// contract — so this engine never imports `Integrations` and can never touch a calendar) and,
/// when recovery has been poor, *eases* the upcoming task load: shorter and slightly less
/// frequent sessions, **strictly within playbook-defined bounds** (`PacingPolicy`). It changes
/// nothing about the goal engine itself — it transforms `TaskRule` values before planning and
/// stamps a visible `PacingInfluence` marker on the affected `PlannedTask`s.
///
/// This is *pacing guidance, not medical advice* (PRD "HealthKit"): the only automatic
/// direction is to reduce load under poor recovery, never to push harder. Everything here is
/// pure and deterministic so it is fully fixture-testable on the host.

// MARK: - Recovery classification

/// How recovered the recent window looks. Only `.poor` triggers an adjustment; `.normal`/`.good`
/// leave the plan untouched (bias toward caution — we ease load, we don't add it).
public enum RecoveryLevel: String, Equatable, Sendable {
    case poor, normal, good
}

/// The derived recovery signal plus a plain-language rationale suitable for the UI.
public struct PacingSignal: Equatable, Sendable {
    public let recovery: RecoveryLevel
    /// One-line, non-medical explanation, e.g. "Sleep averaged 5.6h over 4 nights (below 6.5h)."
    public let rationale: String
    /// How many nights of data informed this.
    public let nights: Int

    public init(recovery: RecoveryLevel, rationale: String, nights: Int) {
        self.recovery = recovery
        self.rationale = rationale
        self.nights = nights
    }

    /// Deterministically classify recovery from summaries. Sleep is the primary signal;
    /// elevated resting HR and depressed HRV corroborate. Missing fields are ignored, not
    /// guessed.
    public static func derive(from summaries: [HealthSummary]) -> PacingSignal? {
        guard !summaries.isEmpty else { return nil }

        func avg(_ path: (HealthSummary) -> Double?) -> Double? {
            let values = summaries.compactMap(path)
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }
        let sleep = avg { $0.sleepHours }
        let rhr = avg { $0.restingHeartRate }
        let hrv = avg { $0.hrv }

        let sleepPoor = sleep.map { $0 < 6.5 } ?? false
        let rhrPoor = rhr.map { $0 > 58 } ?? false
        let hrvPoor = hrv.map { $0 < 55 } ?? false
        let poorSignals = [sleepPoor, rhrPoor, hrvPoor].filter { $0 }.count

        let recovery: RecoveryLevel
        if sleepPoor || poorSignals >= 2 {
            recovery = .poor
        } else if (sleep.map { $0 >= 7.5 } ?? false) && poorSignals == 0 {
            recovery = .good
        } else {
            recovery = .normal
        }

        var parts: [String] = []
        if let sleep { parts.append(String(format: "sleep averaged %.1fh", sleep)) }
        if let rhr { parts.append(String(format: "resting HR %.0f bpm", rhr)) }
        if let hrv { parts.append(String(format: "HRV %.0f ms", hrv)) }
        let rationale = parts.isEmpty
            ? "recent recovery signals"
            : parts.joined(separator: ", ") + " over \(summaries.count) night\(summaries.count == 1 ? "" : "s")"
        return PacingSignal(recovery: recovery, rationale: rationale, nights: summaries.count)
    }
}

// MARK: - Playbook-defined bounds

/// The limits within which HealthKit may adjust a goal's task load. Living on the `GoalPlaybook`
/// makes "how far can pacing go" a property of the goal *type*, not of engine code.
public struct PacingPolicy: Equatable, Sendable {
    /// Which `TaskRule`s (by key) may be eased. Rules outside this set are never touched —
    /// e.g. an immovable dawn swim / long ride stays put; only the softer sessions flex.
    public let adjustableRuleKeys: Set<String>
    /// Floor on duration scaling — pacing will never cut a session below this fraction.
    public let minDurationScale: Double
    /// Cap on how many weekly sessions pacing may drop from any one rule.
    public let maxFrequencyReduction: Int
    /// Target duration scale applied under poor recovery (clamped up to `minDurationScale`).
    public let poorDurationScale: Double
    /// Target weekly-frequency reduction under poor recovery (clamped by `maxFrequencyReduction`).
    public let poorFrequencyReduction: Int

    public init(adjustableRuleKeys: Set<String>, minDurationScale: Double,
                maxFrequencyReduction: Int, poorDurationScale: Double,
                poorFrequencyReduction: Int) {
        self.adjustableRuleKeys = adjustableRuleKeys
        self.minDurationScale = minDurationScale
        self.maxFrequencyReduction = maxFrequencyReduction
        self.poorDurationScale = poorDurationScale
        self.poorFrequencyReduction = poorFrequencyReduction
    }
}

// MARK: - The visible marker

/// The **"HealthKit-influenced"** marker stamped on any task/preview block whose load pacing
/// changed. Its mere presence is the assertion tests key on; the UI renders `label` + `rationale`
/// so influence is never invisible (PRD: "visibly labeled as such").
public struct PacingInfluence: Equatable, Sendable {
    /// The fixed, user-facing source label surfaced wherever an influenced value appears.
    public static let sourceLabel = "HealthKit-influenced"

    public let recovery: RecoveryLevel
    /// Short headline, e.g. "Eased by HealthKit — low recent recovery".
    public let headline: String
    /// Why, in plain language (from `PacingSignal.rationale`).
    public let rationale: String
    /// The duration scale that was applied (e.g. 0.8 = 20% shorter).
    public let durationScale: Double
    /// The weekly-frequency change that was applied (negative = fewer sessions).
    public let frequencyDelta: Int

    public init(recovery: RecoveryLevel, headline: String, rationale: String,
                durationScale: Double, frequencyDelta: Int) {
        self.recovery = recovery
        self.headline = headline
        self.rationale = rationale
        self.durationScale = durationScale
        self.frequencyDelta = frequencyDelta
    }

    /// Always true where a `PacingInfluence` exists — a convenience for assertions and UI.
    public var isHealthKitInfluenced: Bool { true }
    /// The user-facing label ("HealthKit-influenced").
    public var label: String { Self.sourceLabel }
}

// MARK: - The transform

/// The result of pacing a playbook: the (possibly) rule-adjusted playbook, the per-rule
/// influence markers, and the recovery signal that drove it.
public struct PacingResult: Equatable, Sendable {
    public let playbook: GoalPlaybook
    public let influences: [String: PacingInfluence]
    public let signal: PacingSignal?

    public init(playbook: GoalPlaybook, influences: [String: PacingInfluence], signal: PacingSignal?) {
        self.playbook = playbook
        self.influences = influences
        self.signal = signal
    }

    /// Whether pacing actually changed anything.
    public var isInfluenced: Bool { !influences.isEmpty }
}

/// Pure transform: playbook + recent summaries → paced playbook + influence markers. No I/O,
/// no clock beyond the caller-supplied `asOf`, fully deterministic.
public struct PacingAdjuster: Sendable {
    public init() {}

    public func adjust(playbook: GoalPlaybook, summaries: [HealthSummary], asOf: Date) -> PacingResult {
        // No bounds declared, or no data → the plan is untouched (influence simply absent).
        guard let policy = playbook.pacingPolicy,
              let signal = PacingSignal.derive(from: summaries) else {
            return PacingResult(playbook: playbook, influences: [:], signal: nil)
        }
        // Only poor recovery eases load; normal/good leave the plan as designed.
        guard signal.recovery == .poor else {
            return PacingResult(playbook: playbook, influences: [:], signal: signal)
        }

        let scale = max(policy.minDurationScale, policy.poorDurationScale)
        let drop = max(0, min(policy.maxFrequencyReduction, policy.poorFrequencyReduction))

        var influences: [String: PacingInfluence] = [:]
        let newRules: [TaskRule] = playbook.taskRules.map { rule in
            guard policy.adjustableRuleKeys.contains(rule.key) else { return rule }
            let newFrequency = max(1, rule.weeklyFrequency - drop)     // never zero a session out
            let newDuration = rule.expectedDuration * scale
            let freqDelta = newFrequency - rule.weeklyFrequency
            // Only record influence if something actually changed.
            if newDuration != rule.expectedDuration || freqDelta != 0 {
                influences[rule.key] = PacingInfluence(
                    recovery: .poor,
                    headline: "Eased by HealthKit — low recent recovery",
                    rationale: signal.rationale,
                    durationScale: scale,
                    frequencyDelta: freqDelta)
            }
            return TaskRule(
                key: rule.key, titleTemplate: rule.titleTemplate, flexibility: rule.flexibility,
                priority: rule.priority, conflictPolicy: rule.conflictPolicy,
                expectedDuration: newDuration, weeklyFrequency: newFrequency,
                scheduleBlockKey: rule.scheduleBlockKey)
        }

        return PacingResult(
            playbook: playbook.replacingTaskRules(newRules),
            influences: influences,
            signal: signal)
    }
}

// MARK: - Paced planning (pure)

/// Wraps `GoalPlanner` with the pacing transform. Deterministic and pure — it takes the
/// already-fetched `[HealthSummary]`, so the async HealthKit read stays out of the engine.
///
/// The `influenceEnabled` flag is the user's pacing toggle: when `false`, this is *exactly*
/// `GoalPlanner.generatePlan` with no markers — so disabling influence provably changes nothing
/// about the goal data itself, only whether HealthKit shapes it.
public struct PacedPlanner: Sendable {
    private let planner = GoalPlanner()
    private let adjuster = PacingAdjuster()

    public init() {}

    public func generatePlan(
        playbook: GoalPlaybook,
        answers: IntakeAnswers,
        goalTitle: String,
        now: Date,
        targetDate: Date,
        summaries: [HealthSummary],
        influenceEnabled: Bool
    ) -> GeneratedPlan {
        guard influenceEnabled else {
            return planner.generatePlan(playbook: playbook, answers: answers,
                                        goalTitle: goalTitle, now: now, targetDate: targetDate)
        }
        let result = adjuster.adjust(playbook: playbook, summaries: summaries, asOf: now)
        let plan = planner.generatePlan(playbook: result.playbook, answers: answers,
                                        goalTitle: goalTitle, now: now, targetDate: targetDate)
        guard result.isInfluenced else { return plan }

        let stamped = plan.tasks.map { task -> PlannedTask in
            guard let influence = result.influences[task.ruleKey] else { return task }
            return task.stampingPacing(influence)
        }
        return GeneratedPlan(
            playbookKey: plan.playbookKey, goalTitle: plan.goalTitle,
            startDate: plan.startDate, targetDate: plan.targetDate,
            milestones: plan.milestones, tasks: stamped)
    }
}

// MARK: - Async coordinator (bridges the HealthKit read to the pure engine)

/// A compact summary of a live pacing influence, for the Goals UI to render a labeled banner
/// without generating a whole plan.
public struct PacingInfluenceSummary: Equatable, Sendable {
    public let signal: PacingSignal
    /// Task titles whose load pacing eased.
    public let affectedTitles: [String]
    /// Representative influence (headline/scale) shared by the affected tasks.
    public let influence: PacingInfluence

    public var label: String { PacingInfluence.sourceLabel }

    public init(signal: PacingSignal, affectedTitles: [String], influence: PacingInfluence) {
        self.signal = signal
        self.affectedTitles = affectedTitles
        self.influence = influence
    }
}

/// Bridges an async, read-only `HealthKitDataSource` (the real `HealthKitClient` on device, a
/// fake in tests) to the pure `PacedPlanner`. **Denial-safe by construction**: a throwing read
/// (permission withheld / HealthKit unavailable) is swallowed to "no summaries", so goal
/// planning and the daily loop keep working with influence simply absent (PRD Integration
/// Failure Modes). Honors the user's pacing toggle without ever touching goal data.
public struct HealthPacingCoordinator: Sendable {
    public let source: any HealthKitDataSource
    /// How far back to read recovery signals (default: the last week).
    public let lookback: TimeInterval
    private let paced = PacedPlanner()
    private let adjuster = PacingAdjuster()

    public init(source: any HealthKitDataSource, lookback: TimeInterval = 7 * 86_400) {
        self.source = source
        self.lookback = lookback
    }

    /// Recent summaries, or `[]` if the toggle is off or the read fails (denied/unavailable).
    private func recentSummaries(asOf now: Date, influenceEnabled: Bool) async -> [HealthSummary] {
        guard influenceEnabled else { return [] }
        let range = now.addingTimeInterval(-lookback)...now
        return (try? await source.summary(for: range)) ?? []
    }

    /// Generate a plan, applying HealthKit pacing when enabled and data is available.
    public func generatePlan(
        playbook: GoalPlaybook,
        answers: IntakeAnswers,
        goalTitle: String,
        now: Date,
        targetDate: Date,
        influenceEnabled: Bool
    ) async -> GeneratedPlan {
        let summaries = await recentSummaries(asOf: now, influenceEnabled: influenceEnabled)
        return paced.generatePlan(
            playbook: playbook, answers: answers, goalTitle: goalTitle,
            now: now, targetDate: targetDate, summaries: summaries,
            influenceEnabled: influenceEnabled)
    }

    /// For the UI: the current pacing influence (if any) without building a full plan. `nil`
    /// when the toggle is off, permission is denied, there's no data, or recovery is fine.
    public func currentInfluence(
        playbook: GoalPlaybook,
        asOf now: Date,
        influenceEnabled: Bool
    ) async -> PacingInfluenceSummary? {
        let summaries = await recentSummaries(asOf: now, influenceEnabled: influenceEnabled)
        let result = adjuster.adjust(playbook: playbook, summaries: summaries, asOf: now)
        guard result.isInfluenced, let signal = result.signal,
              let anyInfluence = result.influences.values.first else { return nil }
        let affectedTitles = playbook.taskRules
            .filter { result.influences.keys.contains($0.key) }
            .map(\.titleTemplate)
        return PacingInfluenceSummary(signal: signal, affectedTitles: affectedTitles, influence: anyInfluence)
    }
}
