import Foundation
import Core
import Data
import Goals
import DailyLoop

/// The result of parsing one spoken Evening-Capture utterance into a reviewable draft. Nothing
/// here is persisted — the controller shows this for confirmation, then calls
/// `EveningCapture.apply(_:now:)` only on approval.
public struct VoiceCaptureDraft {
    /// The structured input that *would* be applied on confirmation.
    public let input: CaptureInput
    public let completedTitles: [String]
    public let skippedTitles: [String]
    public let note: String?

    public var isEmpty: Bool {
        completedTitles.isEmpty && skippedTitles.isEmpty
            && (note?.isEmpty ?? true)
    }

    /// A short, plain-language summary for the review/confirm step.
    public var reviewSummary: String {
        var parts: [String] = []
        if !completedTitles.isEmpty { parts.append("Done: \(completedTitles.joined(separator: ", "))") }
        if !skippedTitles.isEmpty { parts.append("Skipped: \(skippedTitles.joined(separator: ", "))") }
        if let note, !note.isEmpty { parts.append("Note: \(note)") }
        return parts.isEmpty ? "Nothing recognized." : parts.joined(separator: "\n")
    }
}

/// # VoiceCaptureParser — deterministic transcript → `CaptureInput`
///
/// Voice-first Evening Capture without an LLM (same spirit as `PlanTextExtractor`, Phase 4C): a
/// simple, predictable command grammar maps a spoken sentence onto the day's open tasks.
///
/// Grammar:
///   - "done with X" / "finished X" / "completed X" / "did X" → mark task X **complete**
///   - "skipped X" / "missed X" / "didn't do X" → mark task X **skipped**
///   - anything else (and any command that doesn't match a real task) → the day's **note**
///
/// A command only acts on a task when the spoken words overlap a real open-task title — an
/// unmatched command falls through to the note rather than guessing the wrong task (bias to not
/// mis-writing, Safety Rules #1/#3). Fully deterministic and host-testable.
public struct VoiceCaptureParser {

    public init() {}

    private static let completionCues = ["done", "finished", "completed", "complete",
                                         "did", "knocked out", "wrapped up", "got through"]
    private static let skipCues = ["skipped", "skip", "missed", "didn't", "did not",
                                   "couldn't", "could not", "bailed on", "no time for"]

    public func parse(transcript: String,
                      openTasks: [(goal: Goal, task: GoalTask)]) -> VoiceCaptureDraft {
        let clauses = Self.clauses(in: transcript)

        var completed: [TaskOutcome] = []
        var skipped: [TaskOutcome] = []
        var completedTitles: [String] = []
        var skippedTitles: [String] = []
        var noteFragments: [String] = []
        var usedTaskIDs = Set<UUID>()

        for clause in clauses {
            let lower = clause.lowercased()
            let isSkip = Self.skipCues.contains { lower.contains($0) }
            let isDone = !isSkip && Self.completionCues.contains { lower.contains($0) }

            if isSkip || isDone {
                if let match = Self.bestMatch(for: lower, in: openTasks, excluding: usedTaskIDs) {
                    usedTaskIDs.insert(match.task.appID)
                    let metricKey = PlaybookLibrary.playbook(forKey: match.goal.playbookKey)?
                        .progressSignals.first?.metricKey ?? "progress"
                    let outcome = TaskOutcome(task: match.task, goal: match.goal, metricKey: metricKey)
                    if isSkip {
                        skipped.append(outcome); skippedTitles.append(match.task.title)
                    } else {
                        completed.append(outcome); completedTitles.append(match.task.title)
                    }
                    continue
                }
            }
            // Unmatched command, or plain statement → keep as note (never guess a task).
            let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { noteFragments.append(trimmed) }
        }

        let note = noteFragments.isEmpty ? nil : noteFragments.joined(separator: ". ")
        let input = CaptureInput(note: note, completed: completed, skipped: skipped)
        return VoiceCaptureDraft(input: input,
                                 completedTitles: completedTitles,
                                 skippedTitles: skippedTitles,
                                 note: note)
    }

    // MARK: - Grammar helpers

    /// Split the utterance into clauses on natural boundaries ("and", commas, "then", periods).
    static func clauses(in text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: " and ", with: "\n")
            .replacingOccurrences(of: " then ", with: "\n")
        return normalized
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" || $0 == "." })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The open task whose title best overlaps the clause's words (must share at least one
    /// meaningful word); nil if nothing overlaps.
    static func bestMatch(for clause: String,
                          in openTasks: [(goal: Goal, task: GoalTask)],
                          excluding used: Set<UUID>)
        -> (goal: Goal, task: GoalTask)? {
        let clauseWords = tokens(clause)
        var best: (goal: Goal, task: GoalTask)?
        var bestScore = 0
        for pair in openTasks where !used.contains(pair.task.appID) {
            let titleWords = tokens(pair.task.title.lowercased())
            let overlap = titleWords.filter { clauseWords.contains($0) }.count
            if overlap > bestScore {
                bestScore = overlap
                best = pair
            }
        }
        return bestScore > 0 ? best : nil
    }

    /// Content words of a phrase (drops short stopwords so "the run" matches "run").
    static func tokens(_ text: String) -> Set<String> {
        let stop: Set<String> = ["the", "a", "an", "with", "my", "to", "of", "for", "on", "and",
                                 "did", "do", "done", "i", "was", "is", "at", "in"]
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stop.contains($0) }
        return Set(words)
    }
}
