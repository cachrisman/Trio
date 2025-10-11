import SwiftUI
import WidgetKit

/// Default constants for complication display.
private enum ComplicationDefaults {
    static let widgetKind = TrioComplicationDataStore.complicationKind
    static let fallbackGlucose = "--"
    static let fallbackDelta = "--"
}

// MARK: - Timeline Entry

/// Represents a single data point (entry) displayed in the Trio watch complication.
/// Each entry includes the glucose value, trend, delta, and timestamp.
struct TrioWatchComplicationEntry: TimelineEntry {
    /// The date associated with this entry (usually the snapshot timestamp).
    let date: Date
    /// The glucose reading as a formatted string.
    let glucose: String
    /// The trend value ("Flat", "SingleUp", etc.).
    let trend: String
    /// The delta (change since last reading).
    let delta: String
    /// The complication state code (used for debug or error indicators).
    let state: String?

    /// Initializes a timeline entry with the given data.
    init(date: Date, glucose: String, trend: String, delta: String, state: String? = nil) {
        self.date = date
        self.glucose = glucose
        self.trend = trend
        self.delta = delta
        self.state = state
    }

    /// Initializes an entry from a saved complication snapshot.
    init(snapshot: TrioComplicationSnapshot) {
        date = snapshot.timestamp
        glucose = snapshot.glucose
        trend = snapshot.trend
        delta = snapshot.delta
        state = snapshot.state
    }

    /// Converts the raw trend string into an arrow symbol for display.
    var trendSymbol: String {
        TrendSymbolMapper.symbol(from: trend)
    }

    /// Builds the top (outer) complication line showing glucose + trend.
    /// Example: `"110 →"` or `"--"`.
    var formattedGlucoseLine: String {
        let trimmedGlucose = glucose.trimmingCharacters(in: .whitespacesAndNewlines)
        let glucoseText = trimmedGlucose.isEmpty ? ComplicationDefaults.fallbackGlucose : trimmedGlucose
        let trendText = trendSymbol
        let stateText = state ?? ""
        let statePrefix = stateText.isEmpty ? "" : "\(stateText) "
        if trendText.isEmpty {
            return "\(statePrefix)\(glucoseText)"
        }
        return "\(statePrefix)\(glucoseText) \(trendText)"
    }

    /// Builds the bottom (inner) complication line showing delta + time recency.
    /// Example: `"+2 • 5m ago"` or `"NOW"`.
    var formattedDeltaLine: String {
        let deltaText = sanitizedDelta
        let ageText = recencyDescription
        if deltaText.isEmpty || deltaText == ComplicationDefaults.fallbackDelta {
            return ageText
        }
        return "\(deltaText) • \(ageText)"
    }

    /// Cleans up delta formatting and ensures it is display-ready.
    private var sanitizedDelta: String {
        let trimmedDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDelta.isEmpty else { return ComplicationDefaults.fallbackDelta }
        return trimmedDelta
    }

    /// Calculates a human-readable relative time (e.g. `"NOW"`, `"5m ago"`, `"1h ago"`).
    /// Uses the last known valid timestamp from the data store if available.
    private var recencyDescription: String {
        let now = Date()
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 60 {
            return "NOW"
        }

        let minutes = Int(interval / 60)
        return "\(minutes)m ago"
    }
}

private enum TrendSymbolMapper {
    static func symbol(from rawValue: String) -> String {
        switch rawValue {
        case "TripleUp":
            return "↑↑↑"
        case "DoubleUp":
            return "↑↑"
        case "SingleUp":
            return "↑"
        case "FortyFiveUp":
            return "↗︎"
        case "Flat":
            return "→"
        case "FortyFiveDown":
            return "↘︎"
        case "SingleDown":
            return "↓"
        case "DoubleDown":
            return "↓↓"
        case "TripleDown":
            return "↓↓↓"
        case "NONE",
             "NOT COMPUTABLE",
             "NotComputable",
             "RATE OUT OF RANGE":
            return "↔︎"
        default:
            if rawValue.contains("↑") || rawValue.contains("↓") || rawValue.contains("→") || rawValue.contains("↗") || rawValue
                .contains("↘︎")
            {
                return rawValue
            }
            return ""
        }
    }
}

// MARK: - Provider

/// Supplies timeline entries to WidgetKit for the Trio Watch complication.
/// It defines how often the complication refreshes and what data it displays.
struct TrioWatchComplicationProvider: TimelineProvider {
    /// How often WidgetKit refreshes the complication in seconds.
    private let refreshInterval: TimeInterval = 30

    /// Provides placeholder data shown in the complication preview in the Watch face selector.
    func placeholder(in _: Context) -> TrioWatchComplicationEntry {
        TrioWatchComplicationEntry(
            date: Date(),
            glucose: "110",
            trend: "Flat",
            delta: "+1"
        )
    }

    /// Provides the latest snapshot data used in preview or quick refresh contexts.
    func getSnapshot(in context: Context, completion: @escaping (TrioWatchComplicationEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        completion(loadLatestEntry())
    }

    /// Builds the timeline of entries for the complication.
    /// WidgetKit uses these to decide when and how to refresh data.
    func getTimeline(in _: Context, completion: @escaping (Timeline<TrioWatchComplicationEntry>) -> Void) {
        let entry = loadLatestEntry()
        let nextRefresh = Date().addingTimeInterval(refreshInterval)
        // Create a couple of entries for smoother refresh experience.
        let entries = [
            entry,
            TrioWatchComplicationEntry(
                date: Date().addingTimeInterval(15),
                glucose: entry.glucose,
                trend: entry.trend,
                delta: entry.delta
            )
        ]
        completion(Timeline(entries: entries, policy: .after(nextRefresh)))
    }

    /// Loads the most recent complication snapshot from shared storage.
    private func loadLatestEntry() -> TrioWatchComplicationEntry {
        if let snapshot = TrioComplicationDataStore.shared.latestSnapshot() {
            return TrioWatchComplicationEntry(snapshot: snapshot)
        }
        // Fallback if no data available.
        return TrioWatchComplicationEntry(
            date: Date(),
            glucose: ComplicationDefaults.fallbackGlucose,
            trend: "",
            delta: ComplicationDefaults.fallbackDelta,
            state: "--"
        )
    }
}

// MARK: - Views

/// Wraps the main complication view to choose the correct layout
/// (corner, circular, etc.) depending on the widget family.
struct TrioWatchComplicationEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    var entry: TrioWatchComplicationEntry

    var body: some View {
        switch widgetFamily {
        case .accessoryCircular:
            TrioAccessoryCircularView(entry: entry)
        case .accessoryCorner:
            TrioAccessoryCornerView(entry: entry)
        default:
            Image("ComplicationIcon")
                .widgetAccentable()
                .widgetBackground(backgroundView: Color.clear)
        }
    }
}

/// Displays the corner-style complication (text curved around the watch face).
/// Shows glucose and trend on the main line and delta/age below.
struct TrioAccessoryCornerView: View {
    var entry: TrioWatchComplicationEntry

    var body: some View {
        ZStack(alignment: .leading) {
            if #available(watchOS 10.0, *) {
                AccessoryWidgetBackground()
            }

            Text(entry.formattedGlucoseLine)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.6)
                .widgetAccentable()
                .widgetCurvesContent()
        }
        .widgetLabel {
            Text(entry.formattedDeltaLine)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.6)
        }
        .widgetBackground(backgroundView: Color.clear)
    }
}

/// Displays the circular-style complication, which is icon-only.
struct TrioAccessoryCircularView: View {
    var entry: TrioWatchComplicationEntry

    var body: some View {
        Image("ComplicationIcon")
            .resizable()
            .widgetAccentable()
            .widgetBackground(backgroundView: Color.clear)
    }
}

// MARK: - Widget Configuration

/// Defines the main WidgetKit configuration for the Trio complication.
/// Declares supported families and metadata used in the watch face picker.
@main
struct TrioWatchComplication: Widget {
    let kind: String = ComplicationDefaults.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TrioWatchComplicationProvider()) { entry in
            TrioWatchComplicationEntryView(entry: entry)
        }
        .configurationDisplayName(String(localized: "Trio Glucose"))
        .description(String(localized: "Shows current glucose, delta, and trend data."))
        .supportedFamilies([
            .accessoryCorner,
            .accessoryCircular
        ])
    }
}

extension View {
    /// Applies the appropriate background modifier for widgets based on platform and OS version.
    func widgetBackground(backgroundView: some View) -> some View {
        if #available(watchOS 10.0, iOSApplicationExtension 17.0, iOS 17.0, *) {
            return containerBackground(for: .widget) {
                backgroundView
            }
        } else {
            return background(backgroundView)
        }
    }
}
