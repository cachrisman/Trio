import SwiftUI
import WidgetKit

private enum ComplicationDefaults {
    static let widgetKind = TrioComplicationDataStore.complicationKind
    static let fallbackGlucose = "--"
    static let fallbackDelta = "--"
}

// MARK: - Timeline Entry

struct TrioWatchComplicationEntry: TimelineEntry {
    let date: Date
    let glucose: String
    let trend: String
    let delta: String
    let state: String?

    init(date: Date, glucose: String, trend: String, delta: String, state: String? = nil) {
        self.date = date
        self.glucose = glucose
        self.trend = trend
        self.delta = delta
        self.state = state
    }

    init(snapshot: TrioComplicationSnapshot) {
        date = snapshot.timestamp
        glucose = snapshot.glucose
        trend = snapshot.trend
        delta = snapshot.delta
        state = snapshot.state
    }

    var trendSymbol: String {
        TrendSymbolMapper.symbol(from: trend)
    }

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

    var formattedDeltaLine: String {
        let deltaText = sanitizedDelta
        let ageText = recencyDescription
        if deltaText.isEmpty || deltaText == ComplicationDefaults.fallbackDelta {
            return ageText
        }
        return "\(deltaText) • \(ageText)"
    }

    private var sanitizedDelta: String {
        let trimmedDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDelta.isEmpty else { return ComplicationDefaults.fallbackDelta }
        return trimmedDelta
    }

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

struct TrioWatchComplicationProvider: TimelineProvider {
    private let refreshInterval: TimeInterval = 30

    func placeholder(in _: Context) -> TrioWatchComplicationEntry {
        TrioWatchComplicationEntry(
            date: Date(),
            glucose: "110",
            trend: "Flat",
            delta: "+1"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TrioWatchComplicationEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }

        completion(loadLatestEntry())
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<TrioWatchComplicationEntry>) -> Void) {
        let entry = loadLatestEntry()
        let nextRefresh = Date().addingTimeInterval(refreshInterval)

        // Create multiple entries for more frequent updates
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

    private func loadLatestEntry() -> TrioWatchComplicationEntry {
        if let snapshot = TrioComplicationDataStore.shared.latestSnapshot() {
            return TrioWatchComplicationEntry(snapshot: snapshot)
        }
        // Should never hit here, as latestSnapshot returns a "--" snapshot if no data.
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

//// Displayed View Wrapper
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

/// Corner Complication
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

/// Circular Complication
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

@main struct TrioWatchComplication: Widget {
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
