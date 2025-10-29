import SwiftUI
import WidgetKit

// MARK: - Timeline Entry

struct TrioWatchComplicationEntry: TimelineEntry {
    let date: Date
    let currentGlucose: String
    let currentGlucoseColor: String
    let trend: String?
    let delta: String?
    
    static func placeholder() -> TrioWatchComplicationEntry {
        TrioWatchComplicationEntry(
            date: Date(),
            currentGlucose: "--",
            currentGlucoseColor: "#ffffff",
            trend: nil,
            delta: nil
        )
    }
}

// MARK: - Provider

struct TrioWatchComplicationProvider: TimelineProvider {
    private let complicationStore = TrioComplicationDataStore.shared
    
    func placeholder(in _: Context) -> TrioWatchComplicationEntry {
        TrioWatchComplicationEntry.placeholder()
    }

    func getSnapshot(in _: Context, completion: @escaping (TrioWatchComplicationEntry) -> Void) {
        let entry = createEntry()
        completion(entry)
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<TrioWatchComplicationEntry>) -> Void) {
        let entry = createEntry()
        
        // Refresh policy: after 5 minutes to keep display fresh
        let refreshDate = Date().addingTimeInterval(5 * 60)
        let timeline = Timeline(entries: [entry], policy: .after(refreshDate))
        
        completion(timeline)
    }
    
    private func createEntry() -> TrioWatchComplicationEntry {
        guard let snapshot = complicationStore.loadSnapshot() else {
            return TrioWatchComplicationEntry.placeholder()
        }
        
        return TrioWatchComplicationEntry(
            date: snapshot.timestamp,
            currentGlucose: snapshot.currentGlucose,
            currentGlucoseColor: snapshot.currentGlucoseColor,
            trend: snapshot.trend,
            delta: snapshot.delta
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
    var entry: TrioWatchComplicationProvider.Entry
    
    private var glucoseColor: Color {
        Color(hex: entry.currentGlucoseColor) ?? .white
    }

    var body: some View {
        Text(entry.currentGlucose)
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundColor(glucoseColor)
            .widgetCurvesContent()
            .widgetLabel {
                HStack(spacing: 2) {
                    if let trend = entry.trend, !trend.isEmpty {
                        Text(trend)
                            .font(.system(size: 12))
                    }
                    if let delta = entry.delta {
                        Text(delta)
                            .font(.system(size: 12))
                    }
                }
            }
            .widgetBackground(backgroundView: Color.clear)
    }
}

/// Circular Complication
struct TrioAccessoryCircularView: View {
    var entry: TrioWatchComplicationProvider.Entry
    
    private var glucoseColor: Color {
        Color(hex: entry.currentGlucoseColor) ?? .white
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(entry.currentGlucose)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(glucoseColor)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            
            if let trend = entry.trend, !trend.isEmpty {
                Text(trend)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
            }
        }
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

// MARK: - Color Extension for Hex

extension Color {
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
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
