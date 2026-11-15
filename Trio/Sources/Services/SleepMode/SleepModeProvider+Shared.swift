import Foundation

extension SleepModeProvider {
    /// App-wide instance backed by `UserDefaults.standard`, logging transitions under the watch category.
    /// The phone's watch transfer gate (TRIO-122) reads `SleepModeProvider.shared.isAsleep()`.
    static let shared = SleepModeProvider(log: { message in debug(.watch, message) })
}
