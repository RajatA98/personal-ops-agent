import Foundation

/// # WidgetSnapshot — the glanceable briefing headline, shared app ↔ widget
///
/// A tiny `Codable` value the Home/Lock-Screen widget renders without opening the app: today's
/// #1 priority and the slip count (PROJECT_PLAN Phase 3B). It is derived from a
/// `MorningBriefing`, written by the app after each assembly / one-tap action, and read by the
/// widget extension from a shared App Group container (see `WidgetSnapshotStore`).
///
/// Kept intentionally minimal (Foundation-only, no WidgetKit/SwiftUI) so it compiles into both
/// the package (fully unit-tested by `swift test`) and the widget extension target.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let topPriorityTitle: String?
    public let topPriorityGoalTitle: String?
    public let slipCount: Int

    public init(generatedAt: Date, topPriorityTitle: String?,
                topPriorityGoalTitle: String?, slipCount: Int) {
        self.generatedAt = generatedAt
        self.topPriorityTitle = topPriorityTitle
        self.topPriorityGoalTitle = topPriorityGoalTitle
        self.slipCount = slipCount
    }

    /// Distill a full briefing down to the widget headline.
    public static func from(_ briefing: MorningBriefing) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: briefing.date,
            topPriorityTitle: briefing.topPriority?.title,
            topPriorityGoalTitle: briefing.topPriority?.goalTitle,
            slipCount: briefing.slippedItems.count)
    }

    /// Placeholder shown before the app has ever written a snapshot (and in widget previews).
    public static let placeholder = WidgetSnapshot(
        generatedAt: Date(timeIntervalSince1970: 0),
        topPriorityTitle: "Open the app to sync",
        topPriorityGoalTitle: nil,
        slipCount: 0)

    // MARK: Rendering (pure, testable — the widget View is a thin shell over these)

    /// The primary headline line: the #1 priority, or an "all clear" fallback.
    public var headline: String {
        topPriorityTitle ?? "Nothing due — all clear"
    }

    /// The secondary line: the slip count, phrased for a glance.
    public var slipLine: String {
        switch slipCount {
        case 0: return "No slips"
        case 1: return "1 slipping"
        default: return "\(slipCount) slipping"
        }
    }
}

/// # WidgetSnapshotStore — App Group bridge for the widget
///
/// Reads/writes the `WidgetSnapshot` as JSON in a shared App Group `UserDefaults` suite. The
/// app writes; the widget reads. If the App Group is unavailable (e.g. entitlement not yet set,
/// or a `swift test` host with no suite), `read()` degrades to `WidgetSnapshot.placeholder`
/// rather than failing — so the widget always renders something.
public struct WidgetSnapshotStore {

    /// The shared App Group identifier (matches the app + widget entitlements).
    public static let appGroupID = "group.com.rajatarora.PersonalOpsAgent"
    private static let key = "morning_briefing_widget_snapshot"

    private let defaults: UserDefaults?

    public init(appGroupID: String = WidgetSnapshotStore.appGroupID) {
        self.defaults = UserDefaults(suiteName: appGroupID)
    }

    /// Test/preview seam: inject an explicit `UserDefaults` (e.g. `.standard` or a named suite).
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    /// Persist the latest snapshot for the widget to pick up.
    public func write(_ snapshot: WidgetSnapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// Read the latest snapshot, or the placeholder if none/unavailable.
    public func read() -> WidgetSnapshot {
        guard let defaults,
              let data = defaults.data(forKey: Self.key),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return .placeholder }
        return snapshot
    }
}
