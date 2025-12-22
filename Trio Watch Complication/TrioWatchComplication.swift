import SwiftUI
import WidgetKit

/// Default constants for complication display.
private enum ComplicationDefaults {
    static let widgetKind = TrioComplicationDataStore.complicationKind
    static let fallbackGlucose = "--"
    static let fallbackDelta = "--"
    static let fallbackTrend = "↔︎"
}

// MARK: - Timeline Entry

/// Represents a single data point (entry) displayed in the Trio watch complication.
/// Each entry includes the glucose value, trend, delta, and timestamp.
struct TrioWatchComplicationEntry: TimelineEntry {
    /// The date associated with this entry (WidgetKit refresh marker).
    let date: Date
    /// The timestamp of the underlying glucose reading.
    let readingDate: Date
    /// The glucose reading as a formatted string.
    let glucose: String
    /// The trend value ("Flat", "SingleUp", etc.).
    let trend: String
    /// The delta (change since last reading).
    let delta: String
    /// The complication state code (used for debug or error indicators).
    let state: String?
    /// The glucose color as a hex string for proper coloring.
    let glucoseColor: String?

    /// Initializes a timeline entry with the given data.
    init(
        date: Date,
        readingDate: Date? = nil,
        glucose: String,
        trend: String,
        delta: String,
        state: String? = nil,
        glucoseColor: String? = nil
    ) {
        self.date = date
        self.readingDate = readingDate ?? date
        self.glucose = glucose
        self.trend = trend
        self.delta = delta
        self.state = state
        self.glucoseColor = glucoseColor
    }

    /// Initializes an entry from a saved complication snapshot.
    init(snapshot: TrioComplicationSnapshot) {
        self.init(
            date: Date(),
            readingDate: snapshot.readingDate,
            glucose: snapshot.glucose,
            trend: snapshot.trend,
            delta: snapshot.delta,
            state: snapshot.state,
            glucoseColor: snapshot.glucoseColor
        )
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

    /// Returns just the glucose number for separate coloring
    var glucoseNumber: String {
        let trimmedGlucose = glucose.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedGlucose.isEmpty ? ComplicationDefaults.fallbackGlucose : trimmedGlucose
    }

    /// Returns the trend symbol for separate coloring
    var trendSymbolOnly: String {
        trendSymbol
    }

    /// Returns the state prefix for separate coloring
    var statePrefix: String {
        let stateText = state ?? ""
        return stateText.isEmpty ? "" : "\(stateText) "
    }

    /// The delta text cleaned for display.
    var deltaDisplayText: String {
        sanitizedDelta
    }

    /// Indicates whether the entry contains a valid glucose reading.
    var hasValidReading: Bool {
        let trimmedGlucose = glucose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGlucose.isEmpty else { return false }
        return trimmedGlucose != ComplicationDefaults.fallbackGlucose && state == nil
    }

    /// Cleans up delta formatting and ensures it is display-ready.
    private var sanitizedDelta: String {
        let trimmedDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDelta.isEmpty else { return ComplicationDefaults.fallbackDelta }
        return trimmedDelta
    }

    /// Determines the appropriate color for the glucose value based on standard ranges.
    /// Uses the same logic as the iOS app for consistency.
    var glucoseDisplayColor: Color {
        // If we have a specific color from the data, use it
        if let hexColor = glucoseColor, let color = Color(hex: hexColor) {
            return color
        }

        // Otherwise, determine color based on glucose value
        guard let glucoseValue = Double(glucose) else {
            return .secondary // Gray for invalid values
        }

        // Standard glucose ranges (mg/dL)
        let lowThreshold: Double = 70
        let highThreshold: Double = 180

        if glucoseValue <= lowThreshold {
            return .red
        } else if glucoseValue >= highThreshold {
            return .orange
        } else {
            return .green
        }
    }
}

/// Maps trend strings (e.g. `"DoubleUp"`, `"Flat"`) to display arrow symbols.
private enum TrendSymbolMapper {
    static func symbol(from rawValue: String) -> String {
        switch rawValue {
        case "TripleUp": return "↑↑↑"
        case "DoubleUp": return "↑↑"
        case "SingleUp": return "↑"
        case "FortyFiveUp": return "↗︎"
        case "Flat": return "→"
        case "FortyFiveDown": return "↘︎"
        case "SingleDown": return "↓"
        case "DoubleDown": return "↓↓"
        case "TripleDown": return "↓↓↓"
        case "NONE",
             "NOT COMPUTABLE",
             "NotComputable",
             "RATE OUT OF RANGE":
            return "↔︎"
        default:
            // Return existing symbol if already contains arrows.
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
    private let refreshInterval: TimeInterval = 300

    /// Provides placeholder data shown in the complication preview in the Watch face selector.
    func placeholder(in _: Context) -> TrioWatchComplicationEntry {
        TrioWatchComplicationEntry(
            date: Date(),
            readingDate: Date(),
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
        let snapshot = loadLatestEntry()
        var entries: [TrioWatchComplicationEntry] = []
        let now = Date().roundedDownToMinute

        // Generate one entry per minute for the next 15 minutes.
        for minuteOffset in 0 ..< 30 {
            let entryDate = now.addingTimeInterval(TimeInterval(minuteOffset * 60))
            let entry = TrioWatchComplicationEntry(
                date: entryDate,
                readingDate: snapshot.readingDate,
                glucose: snapshot.glucose,
                trend: snapshot.trend,
                delta: snapshot.delta,
                state: snapshot.state
            )
            entries.append(entry)
        }
        let nextRefresh = now.addingTimeInterval(refreshInterval)
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
            readingDate: .distantPast,
            glucose: ComplicationDefaults.fallbackGlucose,
            trend: ComplicationDefaults.fallbackTrend,
            delta: ComplicationDefaults.fallbackDelta,
            state: "--"
        )
    }
}

// MARK: - Views

/// Wraps the main complication view to choose the correct layout
/// (corner, circular, etc.) depending on the widget family.
struct TrioWatchComplicationEntryView: View {
    var entry: TrioWatchComplicationEntry

    // This allows the view to adapt to different complication sizes.
    @Environment(\.widgetFamily) private var widgetFamily

    @ViewBuilder var body: some View {
        switch widgetFamily {
        case .accessoryCircular:
            TrioAccessoryCircularView(entry: entry)
        case .accessoryCorner:
            TrioAccessoryCornerView(entry: entry)
        default:
            Image("ComplicationIcon")
                .widgetAccentable()
        }
    }
}

/// Displays the corner-style complication (text curved around the watch face).
/// Shows glucose and trend on the main line and delta/age below.
struct TrioAccessoryCornerView: View {
    var entry: TrioWatchComplicationEntry

    var body: some View {
        Text(attributedGlucoseLine)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .minimumScaleFactor(0.6)
            .widgetAccentable()
            .widgetCurvesContent()
            .widgetLabel {
                let age = max(0, entry.date.timeIntervalSince(entry.readingDate))
                let recencyColor: Color = age < 5 * 60 ? .green :
                    age < 15 * 60 ? .yellow : .red
                let deltaText = entry.deltaDisplayText

                // Calculate relative time against the entry's display time (when WidgetKit shows this entry)
                let timeText = shortRelativeTime(from: entry.readingDate, now: entry.date)
                let hasDelta = !deltaText.isEmpty && deltaText != ComplicationDefaults.fallbackDelta
                let hasReading = entry.hasValidReading

                Text(attributedSecondLine(
                    deltaText: deltaText,
                    timeText: timeText,
                    recencyColor: recencyColor,
                    hasDelta: hasDelta,
                    hasReading: hasReading
                ))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .truncationMode(.tail)
            }
    }

    /// Creates an attributed string for the main glucose line with differentiated colors
    private var attributedGlucoseLine: AttributedString {
        var result = AttributedString()

        // State prefix (if any) - white
        if !entry.statePrefix.isEmpty {
            var stateAttr = AttributedString(entry.statePrefix)
            stateAttr.foregroundColor = .white
            result.append(stateAttr)
        }

        // Glucose number - colored
        var glucoseAttr = AttributedString(entry.glucoseNumber)
        glucoseAttr.foregroundColor = entry.glucoseDisplayColor
        result.append(glucoseAttr)

        // Space between glucose and trend (if trend exists)
        if !entry.trendSymbolOnly.isEmpty {
            var spaceAttr = AttributedString(" ")
            spaceAttr.foregroundColor = .white
            result.append(spaceAttr)
        }

        // Trend symbol - white
        if !entry.trendSymbolOnly.isEmpty {
            var trendAttr = AttributedString(entry.trendSymbolOnly)
            trendAttr.foregroundColor = .white
            result.append(trendAttr)
        }

        return result
    }

    /// Creates an attributed string for the second line with differentiated colors
    private func attributedSecondLine(
        deltaText: String,
        timeText: String,
        recencyColor: Color,
        hasDelta: Bool,
        hasReading: Bool
    ) -> AttributedString {
        var result = AttributedString()

        if hasReading && hasDelta {
            // Delta text - white
            var deltaAttr = AttributedString(deltaText)
            deltaAttr.foregroundColor = .white
            result.append(deltaAttr)

            // Space around dot separator - white
            var spaceDotAttr = AttributedString(" • ")
            spaceDotAttr.foregroundColor = .white
            result.append(spaceDotAttr)

            // Time text - recency color
            var timeAttr = AttributedString(timeText)
            timeAttr.foregroundColor = recencyColor
            result.append(timeAttr)
        } else if hasReading {
            // Only time text - recency color
            var timeAttr = AttributedString(timeText)
            timeAttr.foregroundColor = recencyColor
            result.append(timeAttr)
        } else {
            // Fallback - white
            var fallbackAttr = AttributedString(ComplicationDefaults.fallbackDelta)
            fallbackAttr.foregroundColor = .white
            result.append(fallbackAttr)
        }

        return result
    }
}

/// Displays the circular-style complication, which is icon-only.
struct TrioAccessoryCircularView: View {
    var entry: TrioWatchComplicationEntry

    var body: some View {
        VStack {
            Text(entry.glucoseNumber)
                .font(.headline)
                .foregroundColor(entry.glucoseDisplayColor) // Apply glucose color
            Text(entry.trendSymbolOnly)
                .foregroundColor(.white) // Trend symbol stays white
        }
        .widgetAccentable()
    }
}

// MARK: - Widget Configuration

/// Defines the main WidgetKit configuration for the Trio complication.
/// Declares supported families and metadata used in the watch face picker.
@main struct TrioWatchComplication: Widget {
    let kind: String = ComplicationDefaults.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TrioWatchComplicationProvider()) { entry in
            TrioWatchComplicationEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(String(localized: "Trio Glucose"))
        .description(String(localized: "Shows current glucose, delta, and trend data."))
        .supportedFamilies([
            .accessoryCorner,
            .accessoryCircular
        ])
    }
}

// MARK: - Compact Relative Time Helper

private let compactFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.minute, .hour, .day]
    formatter.unitsStyle = .abbreviated // "5m", "2h", "1d"
    formatter.maximumUnitCount = 1
    return formatter
}()

/// Returns a short-form relative time string for the given date.
/// - Example: "NOW", "5m", "2h", "1d"
private func shortRelativeTime(from readingDate: Date, now: Date = Date()) -> String {
    // If the readingDate is very old, don't show a huge relative time.
    if readingDate == .distantPast { return "--" }

    let interval = max(0, now.timeIntervalSince(readingDate))
    if interval < 60 { return "NOW" }

    // Round up to the next minute for more accurate recency display
    let minutes = Int(ceil(interval / 60))
    if minutes < 60 {
        return "\(minutes)m"
    } else if minutes < 1440 { // Less than 24 hours
        let hours = Int(ceil(Double(minutes) / 60))
        return "\(hours)h"
    } else {
        let days = Int(ceil(Double(minutes) / 1440))
        return "\(days)d"
    }
}

// MARK: - Color Extensions

extension Color {
    /// Creates a Color from a hex string (e.g., "#FF0000" or "FF0000").
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            return nil
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Date Extensions

extension Date {
    /// Returns a new Date with seconds set to 0 (rounded down to the nearest minute).
    /// Example: 13:44:15 becomes 13:44:00
    var roundedDownToMinute: Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: self)
        return calendar.date(from: components) ?? self
    }
}
