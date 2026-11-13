import CoreData
import SwiftUI
import UIKit

struct GlucoseBobbleComplicationSettingsView: View {
    @ObservedObject var state: WatchConfig.StateModel

    @State private var scheduledTargetMgDl: Decimal = 100

    @FetchRequest(fetchRequest: {
        let request: NSFetchRequest<GlucoseStored> = GlucoseStored.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \GlucoseStored.date, ascending: false)]
        request.fetchLimit = 1
        return request
    }())
    private var latestGlucoseReadings: FetchedResults<GlucoseStored>

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private var liveGlucoseTintColor: Color {
        Trio.getDynamicGlucoseColor(
            glucoseValue: previewGlucoseValue,
            highGlucoseColorValue: colorHighGlucose,
            lowGlucoseColorValue: colorLowGlucose,
            targetGlucose: colorTargetGlucose,
            glucoseColorScheme: state.settingsManager.settings.glucoseColorScheme
        )
    }

    private var sampleGlucoseColor: Color {
        switch state.glucoseBobbleComplication.colorMode {
        case .glucose: return lighterSameHueGlucoseColor(liveGlucoseTintColor)
        case .white: return .white
        }
    }

    private var previewGlucoseValue: Decimal {
        if let latest = latestGlucoseReadings.first {
            let mgdl = Decimal(latest.glucose)
            return state.units == .mgdL ? mgdl : mgdl.asMmolL
        }
        let isMgdL = state.units == .mgdL
        return isMgdL ? 112 : 112.asMmolL
    }

    private var previewGlucoseText: String {
        if let latest = latestGlucoseReadings.first {
            return Decimal(latest.glucose).formatted(for: state.units)
        }
        return Decimal(112).formatted(for: state.units)
    }

    private var colorLowGlucose: Decimal {
        let settings = state.settingsManager.settings
        let isMgdL = state.units == .mgdL
        let hardCodedLow = Decimal(55)
        let low = settings.glucoseColorScheme == .dynamicColor ? hardCodedLow : settings.low
        return isMgdL ? low : low.asMmolL
    }

    private var colorHighGlucose: Decimal {
        let settings = state.settingsManager.settings
        let isMgdL = state.units == .mgdL
        let hardCodedHigh = Decimal(220)
        let high = settings.glucoseColorScheme == .dynamicColor ? hardCodedHigh : settings.high
        return isMgdL ? high : high.asMmolL
    }

    private var colorTargetGlucose: Decimal {
        let isMgdL = state.units == .mgdL
        return isMgdL ? scheduledTargetMgDl : scheduledTargetMgDl.asMmolL
    }

    private func lighterSameHueGlucoseColor(_ color: Color) -> Color {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return color
        }
        return Color(hue: Double(hue), saturation: 0.45, brightness: 1)
    }

    /// A "Loop Status" ring previews as a fresh loop (green); nil keeps the trend gradient.
    private var previewRingColor: Color? {
        state.glucoseBobbleComplication.ringStyle == .loopStatus ? .loopGreen : nil
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()

                    ZStack {
                        Circle()
                            .fill(Color.black)

                        switch state.glucoseBobbleComplication.backgroundStyle {
                        case .glucoseTint:
                            // The complication tints with the glucose colour even when the number is white.
                            Circle().fill(liveGlucoseTintColor.opacity(0.3))
                        case .system:
                            Circle().fill(Color.gray.opacity(0.25))
                        case .none:
                            EmptyView()
                        }

                        GlucoseBobbleContactView(
                            glucoseText: previewGlucoseText,
                            minutesAgoText: state.glucoseBobbleComplication.showMinutesAgo ? "3m" : nil,
                            deltaText: state.glucoseBobbleComplication.showDelta ? "+2" : nil,
                            glucoseColor: sampleGlucoseColor,
                            rotationDegrees: GlucoseBobbleContactView.rotationDegrees(forTrend: "Flat"),
                            trendArrowPlacement: .insideRing,
                            trend: "Flat",
                            ringColor: previewRingColor,
                            arrowOutlineColor: .black
                        )
                        .scaleEffect(120 / GlucoseBobbleContactView.Layout.nativeSize)
                    }
                    .frame(width: 120, height: 120)

                    Spacer()
                }
            }
            .listRowBackground(Color.chart)

            Section(header: Text("Glucose Bobble Options")) {
                Picker("Glucose Color", selection: $state.glucoseBobbleComplication.colorMode) {
                    ForEach(GlucoseBobbleComplicationSettings.ColorMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Toggle("Show Minutes Since Reading", isOn: $state.glucoseBobbleComplication.showMinutesAgo)
                Toggle("Show Delta", isOn: $state.glucoseBobbleComplication.showDelta)
            }
            .listRowBackground(Color.chart)

            Section(
                header: Text("Appearance"),
                footer: Text(
                    "Loop Status colors the ring green, yellow or red by the time since the last loop, or gray when unknown. Changes reach the watch with its next update."
                )
            ) {
                Picker("Background", selection: $state.glucoseBobbleComplication.backgroundStyle) {
                    ForEach(GlucoseBobbleComplicationSettings.BackgroundStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }

                Picker("Ring", selection: $state.glucoseBobbleComplication.ringStyle) {
                    ForEach(GlucoseBobbleComplicationSettings.RingStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
            }
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Glucose Bobble Complication")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let bgTargets = await state.provider.storage.retrieveAsync(OpenAPS.Settings.bgTargets, as: BGTargets.self)
                ?? BGTargets(from: OpenAPS.defaults(for: OpenAPS.Settings.bgTargets))
                ?? BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: [])
            if let target = bgTargets.currentTarget() {
                scheduledTargetMgDl = target
            }
        }
    }
}

private extension GlucoseBobbleComplicationSettings.ColorMode {
    var displayName: String {
        switch self {
        case .glucose: return String(localized: "Dynamic")
        case .white: return String(localized: "White")
        }
    }
}

private extension GlucoseBobbleComplicationSettings.BackgroundStyle {
    var displayName: String {
        switch self {
        case .glucoseTint: return String(localized: "Glucose Tint")
        case .system: return String(localized: "System")
        case .none: return String(localized: "None")
        }
    }
}

private extension GlucoseBobbleComplicationSettings.RingStyle {
    var displayName: String {
        switch self {
        case .trendGradient: return String(localized: "Trend Gradient")
        case .loopStatus: return String(localized: "Loop Status")
        }
    }
}
