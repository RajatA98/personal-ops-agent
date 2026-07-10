import AppIntents
import SwiftData
import Foundation
import Core
import Data
import Proposals

/// # IngestMessageIntent — the Shortcuts / iMessage intake entry point (Phase 4C)
///
/// This is the app-exposed App Intent a user's **"When I get a message" personal automation**
/// runs (see `docs/SHORTCUTS_SETUP.md`). Shortcuts passes the message's text (and, optionally,
/// its received date); the intent hands it to `ShortcutIntakeService`, which — at most — creates
/// a *pending* Proposal in the Ops Inbox. It can never write to a calendar or memory directly
/// (Safety Rule #1: only user approval in the Ops Inbox executes anything).
///
/// ## Why an App Intent (not a URL scheme)
/// An App Intent is the Apple-sanctioned, modern way Shortcuts invokes app functionality:
///   • It takes a **typed `String` parameter** natively, so the automation just maps the
///     message's *Content* to it — no URL-encoding of untrusted text, no percent-escaping bugs.
///   • `openAppWhenRun = false` lets it run **in the background** without foregrounding the app,
///     so a forwarded text quietly becomes a pending Proposal the user reviews later.
///   • It returns a result/dialog Shortcuts can surface.
/// A custom URL scheme (`personalops://ingest?text=…`) was the alternative; it forces the app to
/// open, needs fragile URL-encoding of arbitrary message text, and is clumsier to wire in the
/// Shortcuts editor. The App Intent avoids all three. (A URL scheme remains a possible fallback
/// if a future automation can only produce a URL; the same `ShortcutIntakeService` would back it.)
///
/// No pbxproj change is required: the app target uses file-system-synchronized groups, so this
/// file is picked up automatically, and App Intents are discovered at build time by the
/// AppIntents metadata processor — there is no Info.plist registration to add.
struct IngestMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Send a message to Personal Ops"
    static var description = IntentDescription(
        "Hands a forwarded message to Personal Ops Agent, which turns it into a pending item in your Ops Inbox to review. Nothing is scheduled or remembered without your approval.")

    /// Runs in the background — a forwarded message should not yank the app open.
    static var openAppWhenRun = false

    @Parameter(title: "Message text")
    var messageText: String

    /// Optional: when the message arrived. A stale/delayed automation is dropped, not guessed.
    @Parameter(title: "Received at")
    var receivedAt: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try DataStore.makeContainer()
        let context = ModelContext(container)
        let engine = ProposalEngine(context: context)
        let service = ShortcutIntakeService(engine: engine)

        let outcome = try service.ingest(text: messageText, receivedAt: receivedAt, now: Date())
        switch outcome {
        case .enqueued:
            return .result(dialog: "Added to your Ops Inbox for review.")
        case .dropped:
            // Best-effort by design: a malformed/empty/late message simply produces nothing.
            return .result(dialog: "Nothing to add from that message.")
        }
    }
}

/// Surfaces the intake intent to Shortcuts/Spotlight so it is discoverable when the user builds
/// their "When I get a message" automation.
struct PersonalOpsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: IngestMessageIntent(),
            phrases: [
                "Send a message to \(.applicationName)",
                "Forward to \(.applicationName)"
            ],
            shortTitle: "Forward message",
            systemImageName: "tray.and.arrow.down")
    }
}
