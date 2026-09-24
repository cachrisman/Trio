import SwiftUI

struct GlucoseBobbleComplicationSettingsView: View {
    @ObservedObject var state: WatchConfig.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private var sampleGlucoseColor: Color {
        switch state.glucoseBobbleComplication.colorMode {
        case .glucose: return .green
        case .white: return .white
        }
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
                            Circle().fill(Color.green.opacity(0.3))
                        case .system:
                            Circle().fill(Color.gray.opacity(0.25))
                        case .none:
                            EmptyView()
                        }

                        GlucoseBobbleContactView(
                            glucoseText: "112",
                            minutesAgoText: state.glucoseBobbleComplication.showMinutesAgo ? "3m" : nil,
                            deltaText: state.glucoseBobbleComplication.showDelta ? "+2" : nil,
                            glucoseColor: sampleGlucoseColor,
                            rotationDegrees: GlucoseBobbleContactView.rotationDegrees(forTrend: "Flat"),
                            trendArrowPlacement: .insideRing,
                            ringColor: previewRingColor
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
