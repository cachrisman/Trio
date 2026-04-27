import Foundation
import WatchConnectivity

/// Forwards errors from watchOS to iOS via WatchConnectivity for logging to Crashlytics.
/// This is the recommended approach since Crashlytics isn't fully supported on watchOS.
actor WatchErrorReporter {
    static let shared = WatchErrorReporter()

    private let session = WCSession.default
    private static let watchLastRunWasForegroundKey = "watchLastRunWasForeground"
    private let crashContextKey = "watchAppCrashContext"
    private let firstLaunchKey = "watchAppHasLaunchedBefore"
    private let pendingPayloadsKey = "watchPendingPayloads"

    // TTL and caps
    private let savedContextMaxEntries = 5
    private let savedContextMaxAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    private let valueLengthCap = 512
    private let recentLogsSizeCap = 16 * 1024 // 16 KB

    private var hasCheckedForCrash = false
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {
        // No automatic crash check - must call startup() explicitly
    }

    /// Startup method - safe to call multiple times (idempotent).
    /// Checks for previous crash and marks the session as checked.
    func startup() async {
        guard !hasCheckedForCrash else { return }
        hasCheckedForCrash = true
        await checkForPreviousCrash()
    }

    /// Checks if the app crashed on the previous launch and reports it.
    private func checkForPreviousCrash() async {
        let userDefaults = UserDefaults.standard
        let hasLaunchedBefore = userDefaults.bool(forKey: firstLaunchKey)

        // First launch
        if !hasLaunchedBefore {
            userDefaults.set(true, forKey: firstLaunchKey)
            userDefaults.set(false, forKey: Self.watchLastRunWasForegroundKey)
            return
        }

        // Subsequent launches - check if previous run was foreground
        let lastRunWasForeground = userDefaults.bool(forKey: Self.watchLastRunWasForegroundKey)

        if lastRunWasForeground {
            // Previous run was foreground and didn't transition to background - likely crashed
            await reportPotentialCrash()
            // Clear the marker to prevent repeated reporting in the same session
            userDefaults.set(false, forKey: Self.watchLastRunWasForegroundKey)
        }
    }

    /// Reports a potential crash from the previous session.
    private func reportPotentialCrash() async {
        var crashInfo: [String: Any] = [
            "type": "potentialCrash",
            "platform": "watchOS",
            "detectedAt": Self.dateFormatter.string(from: Date())
        ]

        // Add version info
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            crashInfo["appVersion"] = "\(version) (\(build))"
        }

        // Try to read persisted logs for context (with size cap)
        if let logContext = await readRecentLogs() {
            crashInfo["recentLogs"] = logContext
        }

        // Read any saved crash context from UserDefaults (with TTL/cap enforcement)
        if let savedContext = await getSavedCrashContext() {
            crashInfo["savedContext"] = savedContext
        }

        await sendErrorToPhone(crashInfo)

        await WatchLogger.shared.log("⌚️ Detected potential crash from previous session, reported to iOS")
    }

    /// Gets saved crash context with TTL and cap enforcement.
    private func getSavedCrashContext() async -> [String: String]? {
        guard let contextDict = UserDefaults.standard.dictionary(forKey: crashContextKey) as? [String: String] else {
            return nil
        }

        // Apply TTL - remove entries older than maxAge
        let now = Date()
        var validContext: [String: String] = [:]
        var contextMetadata: [String: TimeInterval] = [:]

        // Try to get metadata if it exists
        if let metadata = UserDefaults.standard.dictionary(forKey: "\(crashContextKey)_metadata") as? [String: TimeInterval] {
            contextMetadata = metadata
        }

        for (key, value) in contextDict {
            // Check TTL
            if let createdAt = contextMetadata[key] {
                let age = now.timeIntervalSince1970 - createdAt
                if age > savedContextMaxAge {
                    continue // Skip expired entries
                }
            }

            // Apply value length cap
            let cappedValue = String(value.prefix(valueLengthCap))
            validContext[key] = cappedValue
        }

        // Enforce max entries (keep most recent)
        if validContext.count > savedContextMaxEntries {
            // Sort by creation time and keep most recent
            let sortedKeys = validContext.keys.sorted { key1, key2 in
                let time1 = contextMetadata[key1] ?? 0
                let time2 = contextMetadata[key2] ?? 0
                return time1 > time2
            }
            let keysToKeep = Array(sortedKeys.prefix(savedContextMaxEntries))
            validContext = Dictionary(uniqueKeysWithValues: keysToKeep.compactMap { key in
                guard let value = validContext[key] else { return nil }
                return (key, value)
            })
        }

        return validContext.isEmpty ? nil : validContext
    }

    /// Reads recent log entries from persisted logs for crash context (with size cap).
    private func readRecentLogs() async -> String? {
        let logDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("logs", isDirectory: true)

        // Try to read from daily log file
        let dailyLogFile = logDir.appendingPathComponent("watch_log_daily.txt")

        guard let data = try? Data(contentsOf: dailyLogFile),
              let logString = String(data: data, encoding: .utf8),
              !logString.isEmpty
        else { return nil }

        // Apply size cap
        let cappedString: String
        if logString.utf8.count > recentLogsSizeCap {
            // Take last N bytes that fit within cap
            let cappedData = data.suffix(recentLogsSizeCap)
            cappedString = String(data: cappedData, encoding: .utf8) ?? String(logString.suffix(recentLogsSizeCap))
        } else {
            cappedString = logString
        }

        // Return last 50 lines for context
        let lines = cappedString.components(separatedBy: .newlines)
        let recentLines = Array(lines.suffix(50))
        return recentLines.joined(separator: "\n")
    }

    /// Marks the app as having become active (foreground).
    static func markBecameActiveImmediately() {
        UserDefaults.standard.set(true, forKey: Self.watchLastRunWasForegroundKey)
    }

    func markBecameActive() async {
        Self.markBecameActiveImmediately()
    }

    /// Marks the app as having entered background or inactive state.
    static func markEnteredBackgroundOrInactiveImmediately() {
        UserDefaults.standard.set(false, forKey: Self.watchLastRunWasForegroundKey)
    }

    func markEnteredBackgroundOrInactive() async {
        Self.markEnteredBackgroundOrInactiveImmediately()
    }

    /// Saves context that should be included if the app crashes.
    /// Useful for saving state before operations that might crash.
    func saveCrashContext(_ context: [String: String]) async {
        // Apply value length cap
        var cappedContext: [String: String] = [:]
        var metadata: [String: TimeInterval] = [:]
        let now = Date().timeIntervalSince1970

        for (key, value) in context.prefix(savedContextMaxEntries) {
            let cappedValue = String(value.prefix(valueLengthCap))
            cappedContext[key] = cappedValue
            metadata[key] = now
        }

        UserDefaults.standard.set(cappedContext, forKey: crashContextKey)
        UserDefaults.standard.set(metadata, forKey: "\(crashContextKey)_metadata")
    }

    /// Clears saved context for a specific payloadId after ACK.
    func clearSavedContextForPayload(_ payloadId: String) async {
        // Context is cleared when payload is acknowledged
        // This is called from ACK handler
        UserDefaults.standard.removeObject(forKey: crashContextKey)
        UserDefaults.standard.removeObject(forKey: "\(crashContextKey)_metadata")
    }

    /// Reports a non-fatal error from the watch app to iOS for Crashlytics logging.
    /// - Parameters:
    ///   - error: The error to report
    ///   - context: Optional context information (e.g., function name, file name)
    func reportError(_ error: Error, context: [String: String]? = nil) async {
        var errorInfo: [String: Any] = [
            "errorDomain": (error as NSError).domain,
            "errorCode": (error as NSError).code,
            "errorDescription": error.localizedDescription,
            "platform": "watchOS"
        ]

        // Add version info
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            errorInfo["appVersion"] = "\(version) (\(build))"
        }

        // Add context if provided (with caps)
        if let context = context {
            var cappedContext: [String: String] = [:]
            for (key, value) in context.prefix(10) {
                cappedContext[key] = String(value.prefix(valueLengthCap))
            }
            errorInfo["context"] = cappedContext
        }

        // Add stack trace info if available (renamed to reportingStackTrace)
        let stackSymbols = Thread.callStackSymbols
        if !stackSymbols.isEmpty {
            errorInfo["reportingStackTrace"] = Array(stackSymbols.prefix(10)) // Limit to first 10 frames
        }

        await sendErrorToPhone(errorInfo)
    }

    /// Reports a non-fatal issue with a custom message.
    /// - Parameters:
    ///   - message: Description of the issue
    ///   - context: Optional context information
    func reportNonFatalIssue(_ message: String, context: [String: String]? = nil) async {
        var errorInfo: [String: Any] = [
            "message": message,
            "platform": "watchOS",
            "type": "nonFatalIssue"
        ]

        // Add version info
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            errorInfo["appVersion"] = "\(version) (\(build))"
        }

        // Add context if provided (with caps)
        if let context = context {
            var cappedContext: [String: String] = [:]
            for (key, value) in context.prefix(10) {
                cappedContext[key] = String(value.prefix(valueLengthCap))
            }
            errorInfo["context"] = cappedContext
        }

        await sendErrorToPhone(errorInfo)
    }

    /// Stores a pending payload record for later ACK matching.
    func storePendingPayload(payloadId: String, type: String, filePath: String?) async {
        var pendingPayloads = UserDefaults.standard.array(forKey: pendingPayloadsKey) as? [[String: Any]] ?? []

        var record: [String: Any] = [
            "payloadId": payloadId,
            "type": type,
            "createdAtEpoch": Date().timeIntervalSince1970
        ]
        if let filePath { record["filePath"] = filePath }

        pendingPayloads.append(record)

        // Clean up old records (older than 7 days)
        let now = Date().timeIntervalSince1970
        pendingPayloads = pendingPayloads.filter { record in
            if let createdAt = record["createdAtEpoch"] as? TimeInterval {
                return (now - createdAt) < (7 * 24 * 60 * 60)
            }
            return true
        }
        guard JSONSerialization.isValidJSONObject(pendingPayloads) else {
            UserDefaults.standard.removeObject(forKey: pendingPayloadsKey)
            return
        }

        UserDefaults.standard.set(pendingPayloads, forKey: pendingPayloadsKey)
    }

    /// Removes a pending payload record after ACK.
    func removePendingPayload(_ payloadId: String) async {
        var pendingPayloads = UserDefaults.standard.array(forKey: pendingPayloadsKey) as? [[String: Any]] ?? []
        pendingPayloads.removeAll { record in
            record["payloadId"] as? String == payloadId
        }
        guard JSONSerialization.isValidJSONObject(pendingPayloads) else {
            UserDefaults.standard.removeObject(forKey: pendingPayloadsKey)
            return
        }
        UserDefaults.standard.set(pendingPayloads, forKey: pendingPayloadsKey)
    }

    /// Gets all pending payload records.
    func getPendingPayloads() async -> [[String: Any]] {
        return UserDefaults.standard.array(forKey: pendingPayloadsKey) as? [[String: Any]] ?? []
    }

    private func sendErrorToPhone(_ errorInfo: [String: Any]) async {
        // Don't block if WatchConnectivity isn't supported (shouldn't happen on watchOS, but be safe)
        guard WCSession.isSupported() else {
            await WatchLogger.shared.log("⌚️ WatchConnectivity not supported, cannot send error to phone")
            return
        }

        // Generate payloadId
        let payloadId = UUID().uuidString

        // Wrap in envelope structure
        let envelope: [String: Any] = [
            "type": "watchError",
            "payloadId": payloadId,
            "data": errorInfo
        ]

        // Do NOT activate session - WatchState owns activation
        // If session is not activated or reachable, use transferUserInfo or persist locally

        if session.isReachable && session.activationState == .activated {
            // Use sendMessage with replyHandler for immediate ACK
            session.sendMessage(
                envelope,
                replyHandler: { reply in
                    Task {
                        // Check if ACK received
                        if let ackType = reply["type"] as? String,
                           ackType == "ack",
                           let ackPayloadId = reply["payloadId"] as? String,
                           ackPayloadId == payloadId {
                            // ACK received - clear saved context for this payloadId
                            await WatchErrorReporter.shared.clearSavedContextForPayload(payloadId)
                            await WatchErrorReporter.shared.removePendingPayload(payloadId)
                            await WatchLogger.shared.log("⌚️ Error ACK received from phone for payloadId: \(payloadId)")
                        }
                    }
                },
                errorHandler: { error in
                    Task {
                        await WatchLogger.shared.log("⌚️ Failed to send error to phone: \(error.localizedDescription)")
                        // Store as pending for retry
                        await WatchErrorReporter.shared.storePendingPayload(payloadId: payloadId, type: "watchError", filePath: nil)
                    }
                }
            )
        } else {
            // Fallback to transferUserInfo for background delivery
            _ = session.transferUserInfo(envelope)
            // Store as pending - will need ACK later
            await storePendingPayload(payloadId: payloadId, type: "watchError", filePath: nil)
            await WatchLogger.shared.log("⌚️ Error queued for background delivery to phone (payloadId: \(payloadId))")
        }
    }
}
