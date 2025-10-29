import SwiftUI
import WidgetKit

// MARK: - Timeline Entry

struct TrioWatchComplicationEntry: TimelineEntry {
    let date: Date
    let currentGlucose: String
    let colorHex: String
    let trend: String
}

// MARK: - Provider

struct TrioWatchComplicationProvider: TimelineProvider {
    private func loadSnapshot() -> [String: Any]? {
        if let suiteName = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
           let shared = UserDefaults(suiteName: suiteName) {
            return shared.dictionary(forKey: "trio.complication.snapshot")
        }
        return UserDefaults.standard.dictionary(forKey: "trio.complication.snapshot")
    }

    func placeholder(in _: Context) -> TrioWatchComplicationEntry {
        TrioWatchComplicationEntry(date: Date(), currentGlucose: "--", colorHex: "#ffffff", trend: "")
    }

    func getSnapshot(in _: Context, completion: @escaping (TrioWatchComplicationEntry) -> Void) {
        let snap = loadSnapshot()
        let entry = TrioWatchComplicationEntry(
            date: Date(),
            currentGlucose: (snap?[WatchMessageKeys.currentGlucose] as? String) ?? "--",
            colorHex: (snap?[WatchMessageKeys.currentGlucoseColorString] as? String) ?? "#ffffff",
            trend: (snap?[WatchMessageKeys.trend] as? String) ?? ""
        )
        completion(entry)
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<TrioWatchComplicationEntry>) -> Void) {
        let snap = loadSnapshot()
        let entry = TrioWatchComplicationEntry(
            date: Date(),
            currentGlucose: (snap?[WatchMessageKeys.currentGlucose] as? String) ?? "--",
            colorHex: (snap?[WatchMessageKeys.currentGlucoseColorString] as? String) ?? "#ffffff",
            trend: (snap?[WatchMessageKeys.trend] as? String) ?? ""
        )
        // Ensure periodic refresh ~ every 5 minutes
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(5 * 60)))
        completion(timeline)
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
    var entry: TrioWatchComplicationProvider.Entry

    var body: some View {
        Text("")
            .widgetCurvesContent()
            .widgetLabel {
                Text("Trio")
            }
            .widgetBackground(backgroundView: Color.clear)
    }
}

/// Circular Complication
struct TrioAccessoryCircularView: View {
    var entry: TrioWatchComplicationProvider.Entry

    var body: some View {
        ZStack {
            // Use accent color based on glucose color
            if let color = Color(hex: entry.colorHex) {
                Circle().fill(color.opacity(0.2))
            }
            Text(entry.currentGlucose)
                .font(.system(size: 14, weight: .semibold))
                .minimumScaleFactor(0.6)
        }
        .widgetAccentable()
        .widgetBackground(backgroundView: Color.clear)
    }
}

// MARK: - Widget Configuration

@main struct TrioWatchComplication: Widget {
    let kind: String = "TrioWatchComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TrioWatchComplicationProvider()) { entry in
            TrioWatchComplicationEntryView(entry: entry)
        }
        .configurationDisplayName("Trio")
        .description("Displays Trio app icon as complication")
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

// MARK: - Color helper
private extension Color {
    init?(hex: String) {
        var hexString = hex
        if hexString.hasPrefix("#") { hexString.removeFirst() }
        guard hexString.count == 6, let value = Int(hexString, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self = Color(red: red, green: green, blue: blue)
    }
}
