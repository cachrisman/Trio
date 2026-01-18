import Foundation
import FirebaseCrashlytics
import UIKit
import Darwin

/// Tracks app lifecycle events to detect and report unexpected terminations.
///
/// This class monitors app state transitions to identify when the app is terminated
/// unexpectedly (e.g., by iOS due to memory pressure, watchdog timeout, etc.)
/// and logs diagnostic information to Crashlytics.
final class AppTerminationTracker {
    static let shared = AppTerminationTracker()

    private let userDefaults = UserDefaults.standard
    private let lastStateKey = "AppTerminationTracker.lastState"
    private let lastStateTimestampKey = "AppTerminationTracker.lastStateTimestamp"
    private let appLaunchTimestampKey = "AppTerminationTracker.appLaunchTimestamp"
    private let memoryWarningCountKey = "AppTerminationTracker.memoryWarningCount"
    private let memoryWarningTimestampKey = "AppTerminationTracker.memoryWarningTimestamp"

    private enum AppState: String {
        case launched = "launched"
        case active = "active"
        case inactive = "inactive"
        case background = "background"
        case terminated = "terminated"
    }

    enum TerminationReason: String {
        case normal = "normal" // applicationWillTerminate was called
        case unexpected = "unexpected" // App was killed without calling applicationWillTerminate
        case memoryPressure = "memory_pressure" // App was killed due to memory pressure
        case watchdog = "watchdog" // App was killed due to watchdog timeout
        case unknown = "unknown"
    }

    private init() {
        // Private initializer for singleton
    }

    // MARK: - Public Methods

    /// Called when app finishes launching
    func markAppLaunched(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) {
        let timestamp = Date()
        userDefaults.set(timestamp.timeIntervalSince1970, forKey: appLaunchTimestampKey)
        userDefaults.set(AppState.launched.rawValue, forKey: lastStateKey)
        userDefaults.set(timestamp.timeIntervalSince1970, forKey: lastStateTimestampKey)

        // Log launch options for diagnostics
        if let launchOptions = launchOptions, !launchOptions.isEmpty {
            let optionsDescription = launchOptions.map { "\($0.key.rawValue)" }.joined(separator: ", ")
            Crashlytics.crashlytics().log("App launched with options: \(optionsDescription)")
        }

        let message = "App launched at \(timestamp)"
        debug(.default, message)
        info(.default, message, type: .info)
    }

    /// Called when app becomes active
    func markAppBecameActive() {
        updateState(.active)
        let message = "App became active"
        debug(.default, message)
    }

    /// Called when app will resign active
    func markAppWillResignActive() {
        updateState(.inactive)
        let message = "App will resign active"
        debug(.default, message)
    }

    /// Called when app enters background
    func markAppEnteredBackground() {
        updateState(.background)
        // Save critical state before going to background
        saveDiagnosticState()
        let message = "App entered background"
        debug(.default, message)
    }

    /// Called when app will enter foreground
    func markAppWillEnterForeground() {
        updateState(.active)
        let message = "App will enter foreground"
        debug(.default, message)
    }

    /// Called when app will terminate normally
    func markAppWillTerminate(reason: TerminationReason = .normal) {
        updateState(.terminated)
        userDefaults.set(reason.rawValue, forKey: "AppTerminationTracker.lastTerminationReason")
        let message = "App will terminate (reason: \(reason.rawValue))"
        debug(.default, message)
        info(.default, message, type: .info)
    }

    /// Called when iOS sends a memory warning
    func handleMemoryWarning() {
        let count = userDefaults.integer(forKey: memoryWarningCountKey) + 1
        userDefaults.set(count, forKey: memoryWarningCountKey)
        userDefaults.set(Date().timeIntervalSince1970, forKey: memoryWarningTimestampKey)

        // Log system memory info if available
        var memoryInfoString = ""
        if let memoryInfo = getMemoryInfo() {
            memoryInfoString = " | Memory: \(memoryInfo.map { "\($0.key)=\($0.value)MB" }.joined(separator: ", "))"

            // Log to Crashlytics
            Crashlytics.crashlytics().log("Memory info: \(memoryInfo)")
            for (key, value) in memoryInfo {
                Crashlytics.crashlytics().setCustomValue(value, forKey: "memory_\(key)")
            }
        }

        // Log to Crashlytics
        Crashlytics.crashlytics().log("⚠️ Memory warning received (count: \(count))")
        Crashlytics.crashlytics().setCustomValue(count, forKey: "memory_warning_count")

        // Log to file and Better Stack with warning level
        let message = "⚠️ Memory warning received (count: \(count))\(memoryInfoString)"
        debug(.default, message)
        warning(.default, message, description: "iOS sent memory pressure warning. This may indicate the app is using too much memory and could be terminated.")
    }

    /// Checks for unexpected termination from previous session
    func checkForUnexpectedTermination() {
        guard let lastStateString = userDefaults.string(forKey: lastStateKey),
              let lastState = AppState(rawValue: lastStateString),
              let lastTimestamp = userDefaults.object(forKey: lastStateTimestampKey) as? TimeInterval else {
            // First launch or no previous state
            return
        }

        let lastStateDate = Date(timeIntervalSince1970: lastTimestamp)
        let timeSinceLastState = Date().timeIntervalSince(lastStateDate)

        // If app was active/inactive/background and didn't terminate normally, it was likely killed
        if lastState != .terminated {
            let reason = determineTerminationReason(lastState: lastState, timeSinceLastState: timeSinceLastState)
            reportUnexpectedTermination(
                lastState: lastState,
                timeSinceLastState: timeSinceLastState,
                reason: reason
            )
        } else {
            // App terminated normally, clear memory warning count
            userDefaults.removeObject(forKey: memoryWarningCountKey)
            userDefaults.removeObject(forKey: memoryWarningTimestampKey)
        }
    }

    // MARK: - Private Methods

    private func updateState(_ newState: AppState) {
        userDefaults.set(newState.rawValue, forKey: lastStateKey)
        userDefaults.set(Date().timeIntervalSince1970, forKey: lastStateTimestampKey)
    }

    private func saveDiagnosticState() {
        // Save current diagnostic state that might be useful if app is killed
        let memoryInfo = getMemoryInfo() ?? [:]
        userDefaults.set(memoryInfo, forKey: "AppTerminationTracker.lastMemoryInfo")

        // Save scene phase info if available
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let isActive = windowScene.activationState == .foregroundActive
            userDefaults.set(isActive, forKey: "AppTerminationTracker.wasActiveBeforeBackground")
        }
    }

    private func determineTerminationReason(lastState: AppState, timeSinceLastState: TimeInterval) -> TerminationReason {
        // Check if we had recent memory warnings
        if let memoryWarningTimestamp = userDefaults.object(forKey: memoryWarningTimestampKey) as? TimeInterval {
            let timeSinceWarning = Date().timeIntervalSince1970 - memoryWarningTimestamp
            if timeSinceWarning < 60 { // Memory warning within last minute
                return .memoryPressure
            }
        }

        // If app was active and killed quickly, might be watchdog
        if lastState == .active && timeSinceLastState < 10 {
            return .watchdog
        }

        // If app was in background and killed, likely memory pressure
        if lastState == .background {
            return .memoryPressure
        }

        return .unexpected
    }

    private func reportUnexpectedTermination(
        lastState: AppState,
        timeSinceLastState: TimeInterval,
        reason: TerminationReason
    ) {
        // Build detailed message
        var details: [String] = [
            "Last state: \(lastState.rawValue)",
            "Time since last state: \(Int(timeSinceLastState))s",
            "Reason: \(reason.rawValue)"
        ]

        // Add memory info if available
        var memoryInfoString = ""
        if let memoryInfo = userDefaults.dictionary(forKey: "AppTerminationTracker.lastMemoryInfo") as? [String: Any] {
            let memoryDetails = memoryInfo.compactMap { key, value -> String? in
                if let numValue = value as? NSNumber {
                    return "\(key)=\(numValue.intValue)MB"
                }
                return nil
            }
            if !memoryDetails.isEmpty {
                memoryInfoString = " | Last memory: \(memoryDetails.joined(separator: ", "))"
                details.append("Last memory: \(memoryDetails.joined(separator: ", "))")
            }
        }

        // Add memory warning count
        let memoryWarningCount = userDefaults.integer(forKey: memoryWarningCountKey)
        if memoryWarningCount > 0 {
            details.append("Memory warnings before termination: \(memoryWarningCount)")
        }

        let fullMessage = "🔴 App was unexpectedly terminated. \(details.joined(separator: ", "))"
        let shortMessage = "App was unexpectedly terminated. Last state: \(lastState.rawValue), Time since: \(Int(timeSinceLastState))s, Reason: \(reason.rawValue)\(memoryInfoString)"

        // Log to file and Better Stack with error level
        debug(.default, fullMessage)
        warning(
            .default,
            shortMessage,
            description: "The app was terminated unexpectedly by iOS. This may indicate memory pressure, watchdog timeout, or other system-level issues.",
            error: NSError(
                domain: "AppTerminationTracker",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: shortMessage,
                    "termination_reason": reason.rawValue,
                    "last_state": lastState.rawValue,
                    "time_since_last_state": timeSinceLastState
                ]
            )
        )

        // Log to Crashlytics
        Crashlytics.crashlytics().log("🔴 Unexpected termination detected: \(fullMessage)")
        Crashlytics.crashlytics().setCustomValue(reason.rawValue, forKey: "termination_reason")
        Crashlytics.crashlytics().setCustomValue(lastState.rawValue, forKey: "last_app_state")
        Crashlytics.crashlytics().setCustomValue(Int(timeSinceLastState), forKey: "time_since_last_state_seconds")

        // Add memory info to Crashlytics
        if let memoryInfo = userDefaults.dictionary(forKey: "AppTerminationTracker.lastMemoryInfo") as? [String: Any] {
            for (key, value) in memoryInfo {
                if let numValue = value as? NSNumber {
                    Crashlytics.crashlytics().setCustomValue(numValue.intValue, forKey: "last_memory_\(key)")
                }
            }
        }

        // Add memory warning count to Crashlytics
        if memoryWarningCount > 0 {
            Crashlytics.crashlytics().setCustomValue(memoryWarningCount, forKey: "memory_warning_count_before_termination")
        }

        // Create a non-fatal error to represent the termination
        let terminationError = NSError(
            domain: "AppTerminationTracker",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: shortMessage,
                "termination_reason": reason.rawValue,
                "last_state": lastState.rawValue,
                "time_since_last_state": timeSinceLastState
            ]
        )
        Crashlytics.crashlytics().record(error: terminationError)
    }

    private func getMemoryInfo() -> [String: Int]? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        guard kerr == KERN_SUCCESS else {
            return nil
        }

        let usedMemoryMB = Int(info.resident_size / 1024 / 1024)
        let virtualMemoryMB = Int(info.virtual_size / 1024 / 1024)

        return [
            "used_mb": usedMemoryMB,
            "virtual_mb": virtualMemoryMB
        ]
    }
}
