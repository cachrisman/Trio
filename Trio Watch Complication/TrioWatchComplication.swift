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

    init(
        date: Date,
        readingDate: Date? = nil,
        glucose: String,
        trend: String,
        delta: String,
        state: String? = nil,
        glucoseColor: String? = nil,
        source: TrioComplicationDataSource? = nil
    ) {
        self.date = date
        self.readingDate = readingDate ?? date
        self.glucose = glucose
        self.trend = trend
        self.delta = delta
        self.state = state
        self.glucoseColor = glucoseColor
        self.source = source
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
            source: snapshot.source
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

        guard let glucoseValue = Double(glucose) else {
            return .secondary
        }

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

        for minuteOffset in 0 ..< 30 {
            let entryDate = now.addingTimeInterval(TimeInterval(minuteOffset * 60))
            let entry = TrioWatchComplicationEntry(
                date: entryDate,
                readingDate: timelineBase.readingDate,
                glucose: timelineBase.glucose,
                trend: timelineBase.trend,
                delta: timelineBase.delta,
                state: timelineBase.state,
                glucoseColor: timelineBase.glucoseColor,
                source: timelineBase.source
            )
            entries.append(entry)
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
        default:
            Image("ComplicationIcon")
                .widgetAccentable()
        }
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
                let age = max(0, entry.date.timeIntervalSince(entry.readingDate))
                let recencyColor: Color = age < 5 * 60 ? .green :
                    age < 15 * 60 ? .yellow : .red
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
            Text(entry.trendSymbolOnly)
                .foregroundColor(.white)
        }
        .widgetAccentable()
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
            .accessoryCircular
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
