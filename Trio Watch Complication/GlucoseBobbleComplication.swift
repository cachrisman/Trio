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
        GlucoseBobbleComplicationEntry(date: Date(), snapshot: Self.sampleSnapshot)
    }

    func getSnapshot(in _: Context, completion: @escaping (GlucoseBobbleComplicationEntry) -> Void) {
        let snapshot = GlucoseComplicationSnapshot.load() ?? Self.sampleSnapshot
        completion(GlucoseBobbleComplicationEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<GlucoseBobbleComplicationEntry>) -> Void) {
        let now = Date()

        guard let snapshot = GlucoseComplicationSnapshot.load() else {
            let entry = GlucoseBobbleComplicationEntry(date: now, snapshot: nil)
            completion(Timeline(entries: [entry], policy: .never))
            return
        }

        // One entry per minute so the minutes-ago text advances on screen without WidgetKit
        // reloading the timeline; the watch app requests a reload once fresh data arrives.
        let entries = (0 ..< 60).map { offset in
            GlucoseBobbleComplicationEntry(date: now.addingTimeInterval(TimeInterval(offset * 60)), snapshot: snapshot)
        }
        let timeline = Timeline(entries: entries, policy: .after(now.addingTimeInterval(60 * 60)))
        completion(timeline)
    }
}

// MARK: - Widget Configuration

struct TrioGlucoseBobbleComplication: Widget {
    let kind: String = "TrioGlucoseBobbleComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GlucoseBobbleComplicationProvider()) { entry in
            GlucoseBobbleComplicationView(entry: entry)
        }
        .configurationDisplayName("Trio Glucose")
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

    private var valueColor: Color {
        guard let snapshot = entry.snapshot, !isStale, let color = Self.color(fromHex: snapshot.glucoseColorHex) else {
            return .gray
        }
        return color
    }

    // Derived from entry.date, not Date(): timeline entries are rendered ahead of time, so the
    // wall clock at render time isn't the entry's intended "now" — only entry.date is.
    private var minutesAgoText: String? {
        guard let snapshot = entry.snapshot else { return nil }
        let minutes = Int(entry.date.timeIntervalSince(snapshot.readingDate) / 60)
        if minutes < 1 {
            return "<\u{00A0}1\u{00A0}m"
        }
        return "\(minutes)\u{00A0}m"
    }

    private var accessibilityLabelText: String {
        guard let snapshot = entry.snapshot else { return "No glucose data" }
        var parts = [snapshot.glucose]
        if let delta = snapshot.delta { parts.append(delta) }
        if let minutesAgoText { parts.append(minutesAgoText) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var background: some View {
        if renderingMode == .fullColor, entry.snapshot != nil, !isStale {
            valueColor.opacity(0.3)
        } else {
            AccessoryWidgetBackground()
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)

            GlucoseBobbleContactView(
                glucoseText: entry.snapshot?.glucose ?? "--",
                minutesAgoText: entry.snapshot == nil ? nil : minutesAgoText,
                deltaText: entry.snapshot?.delta,
                glucoseColor: valueColor,
                rotationDegrees: GlucoseBobbleContactView.rotationDegrees(forTrend: entry.snapshot?.trend)
            )
            .scaleEffect(side / GlucoseBobbleContactView.Layout.nativeSize)
            .frame(width: side, height: side)
            .opacity(isStale ? 0.55 : 1)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .widgetBackground(backgroundView: background)
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
        )
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
        )
    )
}

#Preview("No Data", as: .accessoryCircular) {
    TrioGlucoseBobbleComplication()
} timeline: {
    GlucoseBobbleComplicationEntry(date: Date(), snapshot: nil)
}
