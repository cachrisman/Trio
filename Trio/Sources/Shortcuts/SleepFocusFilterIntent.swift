import AppIntents
import Foundation

/// Focus Filter the operator attaches to the Sleep Focus (Settings, Focus, Sleep, Focus Filters).
/// The system runs `perform()` when the Focus turns on (with the configured values) and when it turns off
/// (with the parameter defaults), so `sleepMode` defaults to false and is switched on in the filter setup.
/// The parameter default is not a reliable off signal (the system may re-run `perform()` with the saved
/// configured value), so `perform()` reads `SleepFocusFilterIntent.current`, the currently active values, and
/// treats `.notFound` (no active Trio filter) as off; it falls back to `self` only on other errors. What `current` does while no Focus with this filter is active is
/// not documented in the SDK interface (UNVERIFIED, needs the on-device check, AC-8); the provider's 16 h
/// staleness bound covers a missed off call either way.
/// A Focus Filter needs no `AppShortcut` entry; it appears under Focus Filters for any app that declares one.
struct SleepFocusFilterIntent: SetFocusFilterIntent {
    static var title = LocalizedStringResource("Trio sleep mode")

    static var description = IntentDescription(
        "Tells Trio when you are asleep so it can send fewer updates to the watch complication."
    )

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "Trio sleep mode",
            subtitle: sleepMode ? "On while this Focus is active" : "Off"
        )
    }

    @Parameter(title: "Sleep mode", default: false)
    var sleepMode: Bool

    func perform() async throws -> some IntentResult {
        let isOn: Bool
        do {
            isOn = try await Self.current.sleepMode
        } catch SetFocusFilterIntentError.notFound {
            isOn = false // no active Trio filter: the Focus has ended
        } catch {
            isOn = sleepMode
        }
        SleepModeProvider.shared.reportFilter(isOn: isOn)
        return .result()
    }
}
