import Combine
import SwiftUI

extension LiveActivitySettings {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() var storage: FileStorage!

        @Published var units: GlucoseUnits = .mgdL
        @Published var useLiveActivity = false
        @Published var lockScreenView: LockScreenView = .simple
        @Published var smartStackView: LockScreenView = .simple
        @Published var displayGlucoseForecasts = false
        @Published var simpleFontSize: LiveActivityFontSize = .large
        @Published var bigGlucoseFontSize: LiveActivityFontSize = .large
        @Published var bigGlucoseColorByRange = false

        var glucoseColorScheme: GlucoseColorScheme { settingsManager.settings.glucoseColorScheme }

        override func subscribe() {
            units = settingsManager.settings.units
            subscribeSetting(\.useLiveActivity, on: $useLiveActivity) { useLiveActivity = $0 }
            subscribeSetting(\.lockScreenView, on: $lockScreenView) { lockScreenView = $0 }
            subscribeSetting(\.smartStackView, on: $smartStackView) { smartStackView = $0 }
            subscribeSetting(\.displayGlucoseForecasts, on: $displayGlucoseForecasts) { displayGlucoseForecasts = $0 }
            subscribeSetting(\.liveActivitySimpleFontSize, on: $simpleFontSize) { simpleFontSize = $0 }
            subscribeSetting(\.liveActivityBigGlucoseFontSize, on: $bigGlucoseFontSize) { bigGlucoseFontSize = $0 }
            subscribeSetting(\.liveActivityBigGlucoseColorByRange, on: $bigGlucoseColorByRange) { bigGlucoseColorByRange = $0 }
        }
    }
}

extension LiveActivitySettings.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
