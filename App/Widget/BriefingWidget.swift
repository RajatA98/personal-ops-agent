import WidgetKit
import SwiftUI

/// # BriefingWidget — the glanceable daily headline (Phase 3B)
///
/// A Home/Lock-Screen widget that shows today's #1 priority and the slip count without opening
/// the app. The app writes a `WidgetSnapshot` (from `DailyLoop`) as JSON into the shared App
/// Group after each briefing assembly / one-tap action; this extension reads that same JSON.
///
/// The widget is deliberately **self-contained** (no linked app modules). The integration
/// boundary between app and widget is the App Group JSON contract, not a shared binary — so the
/// snapshot shape below mirrors `DailyLoop.WidgetSnapshot` field-for-field (same Codable keys,
/// same App Group id + defaults key), and the two must stay wire-compatible. Keeping the widget
/// free of the umbrella package avoids dragging extension-unsafe app code (OAuth/UI) into an
/// `-application-extension` target and keeps the app's build/test green. The canonical,
/// unit-tested `WidgetSnapshot`/`WidgetSnapshotStore` live in the `DailyLoop` package.

/// Mirror of `DailyLoop.WidgetSnapshot` — same JSON contract the app writes.
struct WidgetSnapshot: Codable, Equatable {
    let generatedAt: Date
    let topPriorityTitle: String?
    let topPriorityGoalTitle: String?
    let slipCount: Int

    static let placeholder = WidgetSnapshot(
        generatedAt: Date(timeIntervalSince1970: 0),
        topPriorityTitle: "Open the app to sync",
        topPriorityGoalTitle: nil,
        slipCount: 0)

    var headline: String { topPriorityTitle ?? "Nothing due — all clear" }

    var slipLine: String {
        switch slipCount {
        case 0: return "No slips"
        case 1: return "1 slipping"
        default: return "\(slipCount) slipping"
        }
    }

    /// Read the latest snapshot the app wrote, or the placeholder if none/unavailable.
    /// Mirrors `DailyLoop.WidgetSnapshotStore` (same suite + key).
    static func read() -> WidgetSnapshot {
        let appGroupID = "group.com.rajatarora.PersonalOpsAgent"
        let key = "morning_briefing_widget_snapshot"
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return .placeholder }
        return snapshot
    }
}

struct BriefingEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct BriefingProvider: TimelineProvider {
    func placeholder(in context: Context) -> BriefingEntry {
        BriefingEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (BriefingEntry) -> Void) {
        completion(BriefingEntry(date: Date(), snapshot: WidgetSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BriefingEntry>) -> Void) {
        let entry = BriefingEntry(date: Date(), snapshot: WidgetSnapshot.read())
        // Refresh in an hour; the app also nudges the widget after each capture.
        let next = Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct BriefingWidgetView: View {
    let entry: BriefingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Today", systemImage: "sun.max.fill")
                .font(.caption2).foregroundStyle(.secondary)
            Text(entry.snapshot.headline)
                .font(.headline)
                .lineLimit(2)
            if let goal = entry.snapshot.topPriorityGoalTitle {
                Text(goal).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(entry.snapshot.slipLine)
                .font(.caption.weight(.medium))
                .foregroundStyle(entry.snapshot.slipCount > 0 ? .orange : .secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding()
    }
}

struct BriefingWidget: Widget {
    let kind = "BriefingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BriefingProvider()) { entry in
            if #available(iOS 17.0, *) {
                BriefingWidgetView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                BriefingWidgetView(entry: entry)
            }
        }
        .configurationDisplayName("Daily Briefing")
        .description("Today's #1 priority and what's slipping.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

@main
struct PersonalOpsWidgets: WidgetBundle {
    var body: some Widget {
        BriefingWidget()
    }
}
