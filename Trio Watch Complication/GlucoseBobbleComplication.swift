import SwiftUI
import WidgetKit

// MARK: - Widget Bundle

// A widget extension has a single @main, so it is this bundle, which lists every complication
// the extension offers — including the app-icon one declared in TrioWatchComplication.swift.
@main struct TrioWatchComplicationBundle: WidgetBundle {
    var body: some Widget {
        TrioWatchComplication()
        TrioGlucoseBobbleComplication()
    }
}

// MARK: - Timeline Entry

struct GlucoseBobbleComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: GlucoseComplicationSnapshot?
    let settings: GlucoseBobbleComplicationSettings
}

// MARK: - Provider

struct GlucoseBobbleComplicationProvider: TimelineProvider {
    private static var sampleSnapshot: GlucoseComplicationSnapshot {
        GlucoseComplicationSnapshot(
            glucose: "112",
            trend: "Flat",
            delta: "+2",
            glucoseColorHex: "#4CD964",
            readingDate: Date().addingTimeInterval(-60)
        )
    }

    func placeholder(in _: Context) -> GlucoseBobbleComplicationEntry {
        GlucoseBobbleComplicationEntry(
            date: Date(),
            snapshot: Self.sampleSnapshot,
            settings: GlucoseBobbleComplicationSettings()
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (GlucoseBobbleComplicationEntry) -> Void) {
        let realSnapshot = GlucoseComplicationSnapshot.load()
        let snapshot = realSnapshot ?? Self.sampleSnapshot
        let settings = GlucoseBobbleComplicationSettings.load() ?? GlucoseBobbleComplicationSettings()
        // fork — telemetry for the circular complication's getSnapshot path; ages come from the
        // real loaded snapshot, not the sample fallback used for display.
        TrioComplicationDataStore.shared.logGlucoseBobbleProviderCall(
            call: "snapshot",
            isPreview: context.isPreview,
            hasSnapshot: realSnapshot != nil,
            dataAgeSeconds: Self.ageSeconds(since: realSnapshot?.readingDate),
            loopAgeSeconds: Self.ageSeconds(since: realSnapshot?.lastLoopDate),
            observedReloadGeneration: Self.telemetryReloadGeneration(TrioComplicationDataStore.shared),
            settingsSummary: Self.settingsSummary(settings)
        )
        completion(GlucoseBobbleComplicationEntry(date: Date(), snapshot: snapshot, settings: settings))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlucoseBobbleComplicationEntry>) -> Void) {
        // fork — record that this complication serviced the current reload generation, so
        // TrioComplicationDataStore does not treat the reload as dropped when this is the only Trio complication on the face.
        let store = TrioComplicationDataStore.shared
        // Read the generation once so the telemetry below reports the one actually recorded.
        let appGroupAvailable = store.isAppGroupAvailable()
        let currentGeneration = appGroupAvailable ? store.currentReloadGeneration() : nil
        // Record only a generation that exists. With none written there is no reload to service, and
        // writing 0 could lower a value the corner provider already recorded in the same shared key.
        if let currentGeneration {
            store.recordWidgetObservedGeneration(currentGeneration)
        }
        let observedReloadGeneration = appGroupAvailable ? (currentGeneration ?? 0) : -1

        let anchor = Self.roundedDownToMinute(Date())
        let settings = GlucoseBobbleComplicationSettings.load() ?? GlucoseBobbleComplicationSettings()

        guard let snapshot = GlucoseComplicationSnapshot.load() else {
            // fork — telemetry for the circular complication's getTimeline path (no-snapshot case).
            store.logGlucoseBobbleProviderCall(
                call: "timeline",
                isPreview: context.isPreview,
                hasSnapshot: false,
                dataAgeSeconds: -1,
                loopAgeSeconds: -1,
                observedReloadGeneration: observedReloadGeneration,
                settingsSummary: Self.settingsSummary(settings)
            )
            let entry = GlucoseBobbleComplicationEntry(date: anchor, snapshot: nil, settings: settings)
            completion(Timeline(entries: [entry], policy: .never))
            return
        }

        // fork — telemetry for the circular complication's getTimeline path.
        store.logGlucoseBobbleProviderCall(
            call: "timeline",
            isPreview: context.isPreview,
            hasSnapshot: true,
            dataAgeSeconds: Self.ageSeconds(since: snapshot.readingDate),
            loopAgeSeconds: Self.ageSeconds(since: snapshot.lastLoopDate),
            observedReloadGeneration: observedReloadGeneration,
            settingsSummary: Self.settingsSummary(settings)
        )

        // One entry per minute so the minutes-ago text advances on screen without WidgetKit
        // reloading the timeline; the watch app requests a reload once fresh data arrives.
        var entries = (0 ..< 30).map { offset in
            GlucoseBobbleComplicationEntry(
                date: anchor.addingTimeInterval(TimeInterval(offset * 60)),
                snapshot: snapshot,
                settings: settings
            )
        }
        // Entries are budget-free (only reloads cost WidgetKit budget), so extending the horizon
        // with a coarser tail keeps the reading age honest through a multi-hour reload drought
        // instead of freezing on the last dense entry once reloads are throttled.
        entries += stride(from: 30, through: 55, by: 5).map { offset in
            GlucoseBobbleComplicationEntry(
                date: anchor.addingTimeInterval(TimeInterval(offset * 60)),
                snapshot: snapshot,
                settings: settings
            )
        }
        entries += stride(from: 60, through: 240, by: 15).map { offset in
            GlucoseBobbleComplicationEntry(
                date: anchor.addingTimeInterval(TimeInterval(offset * 60)),
                snapshot: snapshot,
                settings: settings
            )
        }
        let timeline = Timeline(entries: entries, policy: .after(anchor.addingTimeInterval(60 * 60)))
        completion(timeline)
    }

    // Absolute arithmetic, not calendar components: rebuilding a date from local components is
    // ambiguous in the repeated hour when DST ends and can land an hour early.
    static func roundedDownToMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    // fork — telemetry helper: the current reload generation, read only. 0 when the App Group is
    // available but no generation has been written yet (as the corner provider reports it); -1 only
    // when the App Group itself is unavailable.
    private static func telemetryReloadGeneration(_ store: TrioComplicationDataStore) -> Int {
        guard store.isAppGroupAvailable() else { return -1 }
        return store.currentReloadGeneration() ?? 0
    }

    // fork — telemetry helper: whole seconds from `date` to now, floored at 0; -1 when `date` is nil.
    private static func ageSeconds(since date: Date?) -> Int {
        guard let date else { return -1 }
        return max(0, Int(Date().timeIntervalSince(date)))
    }

    // fork — telemetry helper: compact settings summary for logGlucoseBobbleProviderCall.
    private static func settingsSummary(_ settings: GlucoseBobbleComplicationSettings) -> String {
        "color_mode=\(settings.colorMode.rawValue)"
            + " show_minutes=\(settings.showMinutesAgo)"
            + " show_delta=\(settings.showDelta)"
            + " background=\(settings.backgroundStyle.rawValue)"
            + " ring=\(settings.ringStyle.rawValue)"
    }
}

// MARK: - Widget Configuration

struct TrioGlucoseBobbleComplication: Widget {
    let kind: String = "TrioGlucoseBobbleComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GlucoseBobbleComplicationProvider()) { entry in
            GlucoseBobbleComplicationView(entry: entry)
        }
        .configurationDisplayName("Trio Glucose Bobble")
        .description("Current glucose, trend, delta and reading age.")
        .supportedFamilies([.accessoryCircular])
    }
}

// MARK: - View

struct GlucoseBobbleComplicationView: View {
    let entry: GlucoseBobbleComplicationEntry

    @Environment(\.widgetRenderingMode) private var renderingMode

    // Matches the 12-minute CGM freshness window the phone uses elsewhere.
    private static let staleAfter: TimeInterval = 12 * 60

    private var isStale: Bool {
        guard let snapshot = entry.snapshot else { return false }
        return entry.date.timeIntervalSince(snapshot.readingDate) > Self.staleAfter
    }

    // The raw glucose colour from the snapshot, independent of colorMode: the glucoseTint
    // background always uses this, even when the number itself is forced white.
    private var snapshotGlucoseColor: Color {
        guard let snapshot = entry.snapshot, !isStale, let color = Self.color(fromHex: snapshot.glucoseColorHex) else {
            return .gray
        }
        return color
    }

    private var valueColor: Color {
        guard entry.settings.colorMode == .white, entry.snapshot != nil, !isStale else {
            return snapshotGlucoseColor
        }
        return .white
    }

    private var ringColor: Color? {
        guard entry.settings.ringStyle == .loopStatus else { return nil }
        guard let lastLoopDate = entry.snapshot?.lastLoopDate else { return Self.loopGray }

        let age = entry.date.timeIntervalSince(lastLoopDate) - 30
        if age <= 5 * 60 {
            return Self.loopGreen
        } else if age <= 10 * 60 {
            return Self.loopYellow
        } else {
            return Self.loopRed
        }
    }

    // This target has no loop colour assets, so the phone's loop status colours are inlined here.
    private static let loopGreen = Color(red: 0.435, green: 0.812, blue: 0.592)
    private static let loopYellow = Color(red: 1.0, green: 0.757, blue: 0.271)
    private static let loopRed = Color(red: 0.922, green: 0.341, blue: 0.341)
    private static let loopGray = Color(red: 0.741, green: 0.741, blue: 0.741)

    // Derived from entry.date, not Date(): timeline entries are rendered ahead of time, so the
    // wall clock at render time isn't the entry's intended "now" — only entry.date is.
    private var minutesAgoText: String? {
        guard let snapshot = entry.snapshot else { return nil }
        return Self.ageText(readingDate: snapshot.readingDate, entryDate: entry.date)
    }

    private var accessibilityLabelText: String {
        guard let snapshot = entry.snapshot else { return "No glucose data" }
        var parts = [snapshot.glucose]
        if let delta = snapshot.delta { parts.append(delta) }
        if let minutesAgoText { parts.append(minutesAgoText) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var background: some View {
        switch entry.settings.backgroundStyle {
        case .glucoseTint:
            if renderingMode == .fullColor, entry.snapshot != nil, !isStale {
                Circle().fill(snapshotGlucoseColor.opacity(0.3))
            } else {
                AccessoryWidgetBackground()
            }
        case .system:
            AccessoryWidgetBackground()
        case .none:
            EmptyView()
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)

            ZStack {
                background

                GlucoseBobbleContactView(
                    glucoseText: entry.snapshot?.glucose ?? "--",
                    minutesAgoText: entry.settings.showMinutesAgo ? minutesAgoText : nil,
                    deltaText: entry.settings.showDelta ? entry.snapshot?.delta : nil,
                    glucoseColor: valueColor,
                    rotationDegrees: GlucoseBobbleContactView.rotationDegrees(forTrend: entry.snapshot?.trend),
                    trendArrowPlacement: .insideRing,
                    ringColor: ringColor
                )
                .scaleEffect(side / GlucoseBobbleContactView.Layout.nativeSize)
                .frame(width: side, height: side)
                .opacity(isStale ? 0.55 : 1)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        // containerBackground(for: .widget) (what widgetBackground(backgroundView:) becomes) doesn't
        // paint on watch faces here, so the background is drawn as content instead; Color.clear still
        // satisfies watchOS 10's containerBackground requirement.
        .widgetBackground(backgroundView: Color.clear)
        .accessibilityLabel(accessibilityLabelText)
    }
}

private extension GlucoseBobbleComplicationView {
    static func color(fromHex hex: String) -> Color? {
        var sanitized = hex
        if sanitized.hasPrefix("#") {
            sanitized.removeFirst()
        }
        guard sanitized.count == 6, let rgb = UInt32(sanitized, radix: 16) else { return nil }

        let red = Double((rgb >> 16) & 0xFF) / 255
        let green = Double((rgb >> 8) & 0xFF) / 255
        let blue = Double(rgb & 0xFF) / 255
        return Color(red: red, green: green, blue: blue)
    }

    // readingDate == .distantPast means no reading has ever been recorded; interval is clamped to
    // 0 so a slightly-ahead entry.date (e.g. from timeline rounding) never prints a negative age.
    static func ageText(readingDate: Date, entryDate: Date) -> String {
        if readingDate == .distantPast { return "--" }

        let interval = max(0, entryDate.timeIntervalSince(readingDate))
        if interval < 60 { return "NOW" }

        // Floor division throughout so e.g. 61 minutes reads "1h", never rounds up to "2h".
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }
}

// MARK: - Previews

#Preview("Fresh", as: .accessoryCircular) {
    TrioGlucoseBobbleComplication()
} timeline: {
    let now = Date()
    GlucoseBobbleComplicationEntry(
        date: now,
        snapshot: GlucoseComplicationSnapshot(
            glucose: "112",
            trend: "Flat",
            delta: "+2",
            glucoseColorHex: "#4CD964",
            readingDate: now.addingTimeInterval(-60)
        ),
        settings: GlucoseBobbleComplicationSettings()
    )
}

#Preview("Stale", as: .accessoryCircular) {
    TrioGlucoseBobbleComplication()
} timeline: {
    let now = Date()
    GlucoseBobbleComplicationEntry(
        date: now,
        snapshot: GlucoseComplicationSnapshot(
            glucose: "98",
            trend: "FortyFiveDown",
            delta: "-4",
            glucoseColorHex: "#4CD964",
            readingDate: now.addingTimeInterval(-20 * 60)
        ),
        settings: GlucoseBobbleComplicationSettings()
    )
}

#Preview("No Data", as: .accessoryCircular) {
    TrioGlucoseBobbleComplication()
} timeline: {
    GlucoseBobbleComplicationEntry(date: Date(), snapshot: nil, settings: GlucoseBobbleComplicationSettings())
}

#Preview("Loop status, white", as: .accessoryCircular) {
    TrioGlucoseBobbleComplication()
} timeline: {
    let now = Date()
    GlucoseBobbleComplicationEntry(
        date: now,
        snapshot: GlucoseComplicationSnapshot(
            glucose: "112",
            trend: "Flat",
            delta: "+2",
            glucoseColorHex: "#4CD964",
            readingDate: now.addingTimeInterval(-60),
            lastLoopDate: now.addingTimeInterval(-7 * 60)
        ),
        settings: GlucoseBobbleComplicationSettings(colorMode: .white, ringStyle: .loopStatus)
    )
}
