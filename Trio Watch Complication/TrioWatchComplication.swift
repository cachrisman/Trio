import Foundation
import SwiftUI
import WidgetKit

private enum ComplicationDefaults {
    static let widgetKind = TrioComplicationDataStore.complicationKind
    static let fallbackGlucose = "--"
    static let fallbackDelta = "--"
    static let fallbackTrend = "↔︎"
}

struct TrioWatchComplicationEntry: TimelineEntry {
    let date: Date
    let readingDate: Date
    let glucose: String
    let trend: String
    let delta: String
    let state: String?
    let glucoseColor: String?
    let source: TrioComplicationDataSource?
    /// C-217 V-2b: compact [epochSeconds, mgDl] pairs (last ~2h, oldest-first) for the rectangular sparkline; nil → text-only.
    let recentReadings: [[Int]]?

    init(
        date: Date,
        readingDate: Date? = nil,
        glucose: String,
        trend: String,
        delta: String,
        state: String? = nil,
        glucoseColor: String? = nil,
        source: TrioComplicationDataSource? = nil,
        recentReadings: [[Int]]? = nil
    ) {
        self.date = date
        self.readingDate = readingDate ?? date
        self.glucose = glucose
        self.trend = trend
        self.delta = delta
        self.state = state
        self.glucoseColor = glucoseColor
        self.source = source
        self.recentReadings = recentReadings
    }

    init(snapshot: TrioComplicationSnapshot) {
        self.init(
            date: Date(),
            readingDate: snapshot.readingDate,
            glucose: snapshot.glucose,
            trend: snapshot.trend,
            delta: snapshot.delta,
            state: snapshot.state,
            glucoseColor: snapshot.glucoseColor,
            source: snapshot.source,
            recentReadings: snapshot.recentReadings
        )
    }

    var trendSymbol: String {
        TrendSymbolMapper.symbol(from: trend)
    }

    var glucoseNumber: String {
        let trimmed = glucose.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ComplicationDefaults.fallbackGlucose : trimmed
    }

    var trendSymbolOnly: String {
        trendSymbol
    }

    var statePrefix: String {
        let stateText = state ?? ""
        return stateText.isEmpty ? "" : "\(stateText) "
    }

    var deltaDisplayText: String {
        let trimmed = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ComplicationDefaults.fallbackDelta : trimmed
    }

    var hasValidReading: Bool {
        let trimmed = glucose.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != ComplicationDefaults.fallbackGlucose && state == nil
    }

    var glucoseDisplayColor: Color {
        if let hexColor = glucoseColor, let color = Color(hex: hexColor) {
            return color
        }

        // F-3b: normalize comma decimals before parsing — an unnormalized comma-locale
        // mmol value ("5,6") fails Double(_:) entirely and falls through to .secondary.
        let normalized = glucose.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let glucoseValue = Double(normalized) else {
            return .secondary
        }

        // F-3b: mg/dL and mmol/L thresholds diverge (70/180 mg/dL vs 3.9/10.0 mmol/L) — a
        // raw mmol value like 5.6 previously matched the mg/dL "<= 70" branch and rendered
        // red. This fallback path only runs when the snapshot carries no hex color.
        let isMmol = glucoseValue < 40
        let lowThreshold: Double = isMmol ? 3.9 : 70
        let highThreshold: Double = isMmol ? 10.0 : 180

        if glucoseValue <= lowThreshold {
            return .red
        } else if glucoseValue >= highThreshold {
            return .orange
        } else {
            return .green
        }
    }
}

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
        case "NONE", "NOT COMPUTABLE", "NotComputable", "RATE OUT OF RANGE": return "↔︎"
        default:
            if rawValue.contains("↑") || rawValue.contains("↓") || rawValue.contains("→") ||
                rawValue.contains("↗") || rawValue.contains("↘︎")
            {
                return rawValue
            }
            return ""
        }
    }
}

private enum ProviderProcessState {
    static let instanceID = UUID()
    static var lastSeenGeneration: Int?
    static var isFirstCall = true
}

struct TrioWatchComplicationProvider: TimelineProvider {
    private let refreshInterval: TimeInterval = 300

    func placeholder(in _: Context) -> TrioWatchComplicationEntry {
        TrioWatchComplicationEntry(
            date: Date(),
            readingDate: Date(),
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
        let entry = loadLatestEntry()
        let getSnapshotAtEpochSeconds = Int(Date().timeIntervalSince1970)
        let dataAgeSeconds: Int = {
            let rd = entry.readingDate
            if rd == .distantPast || rd.timeIntervalSince1970 <= 0 { return -1 }
            return max(0, Int(Date().timeIntervalSince(rd)))
        }()
        TrioComplicationDataStore.shared.logWidgetGetSnapshotInvocation(
            getSnapshotAtEpochSeconds: getSnapshotAtEpochSeconds,
            dataAgeSeconds: dataAgeSeconds
        )
        completion(entry)
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<TrioWatchComplicationEntry>) -> Void) {
        let store = TrioComplicationDataStore.shared
        let nowEpochSeconds = Int(Date().timeIntervalSince1970)
        let appGroupAvailable = store.isAppGroupAvailable()

        let observedGeneration: Int
        let generationSource: String
        if !appGroupAvailable {
            observedGeneration = -1
            generationSource = "unavailable"
        } else if let gen = store.currentReloadGeneration() {
            observedGeneration = gen
            generationSource = "set"
        } else {
            observedGeneration = 0
            generationSource = "unset"
        }

        let lastReloadEpoch = store.lastReloadRequestEpochSeconds()

        let isRestart = ProviderProcessState.isFirstCall
        ProviderProcessState.isFirstCall = false

        let generationDelta: Int
        if !appGroupAvailable {
            generationDelta = -1
        } else if let lastSeen = ProviderProcessState.lastSeenGeneration {
            generationDelta = observedGeneration - lastSeen
        } else {
            generationDelta = -1
        }

        if appGroupAvailable {
            ProviderProcessState.lastSeenGeneration = observedGeneration
            // C-209-7 (review 5.9): persist the serviced generation so the app side can detect
            // reloads WidgetKit dropped and re-request once. Widget-owned key, app reads only.
            store.recordWidgetObservedGeneration(observedGeneration)
        }

        let latencyValid: Bool
        let latencySeconds: Int
        if let epoch = lastReloadEpoch {
            let elapsed = nowEpochSeconds - epoch
            latencyValid = elapsed >= 0 && elapsed <= TrioComplicationDataStore.latencyValidityWindowSeconds
            latencySeconds = latencyValid ? elapsed : -1
        } else {
            latencyValid = false
            latencySeconds = -1
        }

        let reloadId = store.newestReloadRecord()?.id.uuidString ?? "none"

        let timelineBase = loadLatestEntry()
        let getTimelineAtEpochSeconds = Int(Date().timeIntervalSince1970)
        let dataAgeSeconds: Int = {
            let rd = timelineBase.readingDate
            if rd == .distantPast || rd.timeIntervalSince1970 <= 0 { return -1 }
            return max(0, Int(Date().timeIntervalSince(rd)))
        }()

        store.logWidgetGetTimelineInvocation(
            appGroupAvailable: appGroupAvailable,
            observedGenerationSource: generationSource,
            observedReloadGeneration: observedGeneration,
            generationDelta: generationDelta,
            providerInstanceId: ProviderProcessState.instanceID.uuidString,
            providerRestart: isRestart,
            latencyValid: latencyValid,
            latencySeconds: latencySeconds,
            reloadRequestedAtEpochSeconds: lastReloadEpoch ?? -1,
            mostRecentReloadId: reloadId,
            getTimelineAtEpochSeconds: getTimelineAtEpochSeconds,
            dataAgeSeconds: dataAgeSeconds
        )
        var entries: [TrioWatchComplicationEntry] = []
        let now = Date().roundedDownToMinute

        func makeEntry(at entryDate: Date) -> TrioWatchComplicationEntry {
            TrioWatchComplicationEntry(
                date: entryDate,
                readingDate: timelineBase.readingDate,
                glucose: timelineBase.glucose,
                trend: timelineBase.trend,
                delta: timelineBase.delta,
                state: timelineBase.state,
                glucoseColor: timelineBase.glucoseColor,
                source: timelineBase.source,
                recentReadings: timelineBase.recentReadings
            )
        }

        for minuteOffset in 0 ..< 30 {
            entries.append(makeEntry(at: now.addingTimeInterval(TimeInterval(minuteOffset * 60))))
        }

        // F-1: coarser entries beyond the 30-minute dense window, carrying the SAME reading
        // data as timelineBase. Entries are budget-free (only reloads cost WidgetKit budget),
        // so extending the horizon here keeps the staleness display honest through a
        // multi-hour reload drought instead of freezing on the last dense entry ("30m" stale).
        for minuteOffset in stride(from: 35, through: 55, by: 5) {
            entries.append(makeEntry(at: now.addingTimeInterval(TimeInterval(minuteOffset * 60))))
        }
        for minuteOffset in stride(from: 60, through: 240, by: 15) {
            entries.append(makeEntry(at: now.addingTimeInterval(TimeInterval(minuteOffset * 60))))
        }

        let nextRefresh = now.addingTimeInterval(refreshInterval)
        completion(Timeline(entries: entries, policy: .after(nextRefresh)))
    }

    private func loadLatestEntry() -> TrioWatchComplicationEntry {
        if let snapshot = TrioComplicationDataStore.shared.latestSnapshot() {
            return TrioWatchComplicationEntry(snapshot: snapshot)
        }
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

struct TrioWatchComplicationEntryView: View {
    var entry: TrioWatchComplicationEntry

    @Environment(\.widgetFamily) private var widgetFamily

    @ViewBuilder var body: some View {
        switch widgetFamily {
        case .accessoryCircular:
            TrioAccessoryCircularView(entry: entry)
        case .accessoryCorner:
            TrioAccessoryCornerView(entry: entry)
        case .accessoryInline:
            TrioAccessoryInlineView(entry: entry)
        case .accessoryRectangular:
            TrioAccessoryRectangularView(entry: entry)
        default:
            Image("ComplicationIcon")
                .widgetAccentable()
        }
    }
}

// F-2: single source of truth for the staleness/recency color used across complication
// families (corner's widgetLabel, circular's trend text, rectangular's relative-time text).
// Returns nil for a fresh reading (< 5 min) so callers keep their own fresh-state color.
private func recencyColor(for entry: TrioWatchComplicationEntry) -> Color? {
    let age = max(0, entry.date.timeIntervalSince(entry.readingDate))
    if age < 5 * 60 {
        return nil
    } else if age < 15 * 60 {
        return .yellow
    } else {
        return .red
    }
}

struct TrioAccessoryCornerView: View {
    var entry: TrioWatchComplicationEntry

    var body: some View {
        Text(attributedGlucoseLine)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .minimumScaleFactor(0.6)
            .widgetAccentable()
            .widgetCurvesContent()
            .widgetLabel {
                let recencyColor = recencyColor(for: entry) ?? .green
                let deltaText = entry.deltaDisplayText
                let timeText = shortRelativeTime(from: entry.readingDate, now: entry.date)
                let hasDelta = !deltaText.isEmpty && deltaText != ComplicationDefaults.fallbackDelta
                let hasReading = entry.hasValidReading

                Text(attributedSecondLine(
                    deltaText: deltaText,
                    timeText: timeText,
                    recencyColor: recencyColor,
                    hasDelta: hasDelta,
                    hasReading: hasReading,
                    snapshotSource: entry.source
                ))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .truncationMode(.tail)
            }
    }

    private var attributedGlucoseLine: AttributedString {
        var result = AttributedString()

        if !entry.statePrefix.isEmpty {
            var stateAttr = AttributedString(entry.statePrefix)
            stateAttr.foregroundColor = .white
            result.append(stateAttr)
        }

        var glucoseAttr = AttributedString(entry.glucoseNumber)
        glucoseAttr.foregroundColor = entry.glucoseDisplayColor
        result.append(glucoseAttr)

        if !entry.trendSymbolOnly.isEmpty {
            var spaceAttr = AttributedString(" ")
            spaceAttr.foregroundColor = .white
            result.append(spaceAttr)
        }

        if !entry.trendSymbolOnly.isEmpty {
            var trendAttr = AttributedString(entry.trendSymbolOnly)
            trendAttr.foregroundColor = .white
            result.append(trendAttr)
        }

        return result
    }

    private func attributedSecondLine(
        deltaText: String,
        timeText: String,
        recencyColor: Color,
        hasDelta: Bool,
        hasReading: Bool,
        snapshotSource: TrioComplicationDataSource?
    ) -> AttributedString {
        var result = AttributedString()

        if hasReading && hasDelta {
            var deltaAttr = AttributedString(deltaText)
            deltaAttr.foregroundColor = .white
            result.append(deltaAttr)

            var separatorAttr = AttributedString(" • ")
            separatorAttr.foregroundColor = .white
            result.append(separatorAttr)

            var timeAttr = AttributedString(timeText)
            timeAttr.foregroundColor = recencyColor
            result.append(timeAttr)
        } else if hasReading {
            var timeAttr = AttributedString(timeText)
            timeAttr.foregroundColor = recencyColor
            result.append(timeAttr)
        } else {
            var fallbackAttr = AttributedString(ComplicationDefaults.fallbackDelta)
            fallbackAttr.foregroundColor = .white
            result.append(fallbackAttr)
        }

        if snapshotSource == .g7DirectBLE {
            var bleAttr = AttributedString(" · BLE")
            bleAttr.foregroundColor = .white
            result.append(bleAttr)
        }

        return result
    }
}

struct TrioAccessoryCircularView: View {
    var entry: TrioWatchComplicationEntry

    var body: some View {
        VStack {
            Text(entry.glucoseNumber)
                .font(.headline)
                .foregroundColor(entry.glucoseDisplayColor)
            // F-2: trend carries the shared recency color instead of a fixed .white, so a
            // stale reading is visible even when WidgetKit defers reloads.
            Text(entry.trendSymbolOnly)
                .foregroundColor(recencyColor(for: entry) ?? .white)
        }
        .widgetAccentable()
    }
}

// V-1: accessoryInline renders a single line of text (no layout control beyond that), so
// this is intentionally a plain, short Text; color styling is not honored in this family.
struct TrioAccessoryInlineView: View {
    var entry: TrioWatchComplicationEntry

    var body: some View {
        let deltaText = entry.deltaDisplayText
        let hasDelta = !deltaText.isEmpty && deltaText != ComplicationDefaults.fallbackDelta
        Text(hasDelta
            ? "\(entry.glucoseNumber) \(entry.trendSymbolOnly) \(deltaText)"
            : "\(entry.glucoseNumber) \(entry.trendSymbolOnly)")
    }
}

// C-217 V-2b: glucose + trend + delta + age line, with a 2h sparkline beneath when the snapshot
// carries `recentReadings` (bridged from the extension's WatchGlucoseHistoryStore via the saved
// snapshot). Falls back to text-only when the series is nil / < 2 points.
struct TrioAccessoryRectangularView: View {
    var entry: TrioWatchComplicationEntry

    var body: some View {
        VStack(alignment: .leading) {
            HStack(spacing: 4) {
                Text(entry.glucoseNumber)
                    .font(.headline)
                    .foregroundColor(entry.glucoseDisplayColor)
                    .widgetAccentable()
                Text(entry.trendSymbolOnly)
                    .foregroundColor(.white)
                Text(entry.deltaDisplayText)
                    .font(.subheadline)
                    .foregroundColor(.white)
            }

            let timeText = shortRelativeTime(from: entry.readingDate, now: entry.date)
            let bleSuffix = entry.source == .g7DirectBLE ? " · BLE" : ""
            Text("\(timeText)\(bleSuffix)")
                .foregroundColor(recencyColor(for: entry) ?? .white)

            if let stateText = entry.state, !stateText.isEmpty {
                Text(stateText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let readings = entry.recentReadings, readings.count >= 2 {
                rectangularSparkline(readings)
                    .frame(height: 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// C-217 V-2b: lightweight Path polyline (no Charts — widget memory/launch budget). X = fixed 2h
    /// window ending at entry.date; a gap > 15 min renders as a line break (a gap IS information, not
    /// interpolated). Y = window min/max padded ±20 mg/dL, clamped to a >= 40 span so a flat trace
    /// isn't dramatic noise. Colour reuses the recency convention (dims when the newest point is stale).
    private func rectangularSparkline(_ readings: [[Int]]) -> some View {
        let nowT = entry.date.timeIntervalSince1970
        let windowStart = nowT - 2 * 60 * 60
        let points: [(t: Double, v: Double)] = readings.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return (t: Double(pair[0]), v: Double(pair[1]))
        }
        .filter { $0.t >= windowStart }
        .sorted { $0.t < $1.t }
        let values = points.map { $0.v }
        let rawMin = values.min() ?? 0
        let rawMax = values.max() ?? 0
        var lo = rawMin - 20
        var hi = rawMax + 20
        if hi - lo < 40 { let mid = (hi + lo) / 2; lo = mid - 20; hi = mid + 20 }
        let span = max(hi - lo, 1)
        let color = recencyColor(for: entry) ?? .white
        return GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                var started = false
                var lastT: Double?
                for p in points {
                    let x = CGFloat((p.t - windowStart) / (nowT - windowStart)) * w
                    let y = h - CGFloat((p.v - lo) / span) * h
                    let pt = CGPoint(x: x, y: y)
                    if let lt = lastT, p.t - lt > 15 * 60 { started = false } // gap > 15 min → break
                    if started { path.addLine(to: pt) } else { path.move(to: pt); started = true }
                    lastT = p.t
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

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
            .accessoryCircular,
            .accessoryInline,
            .accessoryRectangular
        ])
    }
}

private func shortRelativeTime(from readingDate: Date, now: Date = Date()) -> String {
    if readingDate == .distantPast { return "--" }

    let interval = max(0, now.timeIntervalSince(readingDate))
    if interval < 60 { return "NOW" }

    // Use floor division to avoid rounding up (e.g., 61 minutes should show "1h", not "2h")
    let totalMinutes = Int(interval / 60)

    if totalMinutes < 60 {
        return "\(totalMinutes)m"
    } else if totalMinutes < 1440 {
        // For times between 1 hour and 24 hours, show hours
        // Use integer division (not ceil) to avoid showing "2h" for 61 minutes
        let hours = totalMinutes / 60
        return "\(hours)h"
    } else {
        let days = totalMinutes / 1440
        return "\(days)d"
    }
}

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
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

extension Date {
    var roundedDownToMinute: Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: self)
        return calendar.date(from: components) ?? self
    }
}
