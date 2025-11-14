import AppIntents
import Foundation

/// An App Intent that allows users to cancel an active temporary target through the Shortcuts app.
@available(iOS 16.0, *) struct CancelTempPresetIntent: AppIntent {
    /// The title displayed for this action in the Shortcuts app.
    static var title: LocalizedStringResource = "Cancel a Temporary Target"

    /// The description displayed for this action in the Shortcuts app.
    static var description = IntentDescription("Cancel Temporary Target.")

    /// Prevents launching the app UI when the shortcut runs.
    static var openAppWhenRun: Bool { false }

    /// Performs the intent action to cancel an active temporary target.
    ///
    /// - Returns: A confirmation dialog indicating that the temporary target has been canceled.
    /// - Throws: An error if the cancellation process fails.
    @MainActor func perform() async throws -> some ProvidesDialog {
        await TempPresetsIntentRequest().cancelTempTarget()
        return .result(
            dialog: IntentDialog(stringLiteral: String(localized: "Temporary Target canceled"))
        )
    }
}
