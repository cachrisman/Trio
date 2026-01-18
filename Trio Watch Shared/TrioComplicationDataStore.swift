import Foundation
import WidgetKit

struct TrioComplicationSnapshot: Equatable, Codable {
    private enum Constants {
        static let fallbackGlucose = "--"
        static let fallbackDelta = "--"
    }

    let glucose: String
    let trend: String
    let delta: String
    let date: Date
    let readingDate: Date
    let state: String?
    let glucoseColor: String?

    init(
        glucose rawGlucose: String,
        trend rawTrend: String,
        delta rawDelta: String,
        readingDate: Date,
        date: Date,
        state: String? = nil,
        glucoseColor: String? = nil
    ) {
        glucose = Self.sanitizedGlucose(from: rawGlucose)
        trend = rawTrend.trimmingCharacters(in: .whitespacesAndNewlines)
        delta = Self.sanitizedDelta(from: rawDelta)
        self.readingDate = readingDate
        self.date = date
        self.state = state
        self.glucoseColor = glucoseColor
    }

    private static func sanitizedGlucose(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Constants.fallbackGlucose }
        if trimmed == Constants.fallbackGlucose { return Constants.fallbackGlucose }

        let digitsAndSeparators = CharacterSet(charactersIn: "0123456789.")
        let numericPortion = trimmed
            .components(separatedBy: digitsAndSeparators.inverted)
            .joined()

        if let doubleValue = Double(numericPortion), doubleValue > 0 {
            let rounded = Int(doubleValue.rounded())
            return String(rounded)
        }

        return trimmed
    }

    private static func sanitizedDelta(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Constants.fallbackDelta }
        if trimmed == Constants.fallbackDelta { return Constants.fallbackDelta }

        let allowed = CharacterSet(charactersIn: "+-0123456789.,")
        let filteredScalars = trimmed.unicodeScalars.filter { allowed.contains($0) }
        let normalized = String(filteredScalars).replacingOccurrences(of: ",", with: ".")

        guard !normalized.isEmpty, let numericValue = Double(normalized) else {
            return trimmed
        }

        let magnitude = abs(numericValue)
        let roundedMagnitude = magnitude.rounded()
        if abs(roundedMagnitude - magnitude) < 0.05 {
            let signedInt = Int(roundedMagnitude) * (numericValue >= 0 ? 1 : -1)
            return String(format: "%+d", signedInt)
        }

        return String(format: "%+.1f", numericValue)
    }
}

/// Data store for watch complication snapshots and reload coordination.
/// This class is main-thread confined: all public API methods (`save`, `coalescedReload`, `forceReload`)
/// must be called from the main thread or will hop to main before executing.
final class TrioComplicationDataStore {
    static let shared = TrioComplicationDataStore()
    static let complicationKind = "TrioWatchComplication"

    // MARK: - App Group ID Resolution

    /// Canonical App Group ID format used by this project (derived from Team ID).
    private static func appGroupID(forTeamID teamID: String) -> String {
        "group.org.nightscout.\(teamID).trio.trio-app-group"
    }

    /// Attempts to extract the Team ID from a bundle identifier of the form:
    /// - `org.nightscout.<TEAM>.trio`
    /// - `org.nightscout.<TEAM>.trio.watchkitapp`
    /// - `org.nightscout.<TEAM>.trio.watchkitapp.<Something>`
    private static func extractTeamID(fromNightscoutBundleIdentifier bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        let prefix = "org.nightscout."
        guard let prefixRange = bundleIdentifier.range(of: prefix) else { return nil }
        let afterPrefix = bundleIdentifier[prefixRange.upperBound...]

        // Find the first occurrence of ".trio" after the prefix and treat the preceding segment as TEAMID.
        guard let trioRange = afterPrefix.range(of: ".trio") else { return nil }
        let teamID = String(afterPrefix[..<trioRange.lowerBound])
        guard !teamID.isEmpty else { return nil }
        return teamID
    }

    /// Resolves the App Group ID using multiple fallbacks, in priority order:
    /// 1) `AppGroupID` key in the chosen bundle’s Info.plist
    /// 2) Derive from the watch app’s `WKCompanionAppBundleIdentifier` (watchOS only)
    /// 3) Derive from the chosen bundle’s bundle identifier
    private static func resolveAppGroupID(bundle: Bundle) -> (value: String?, source: String) {
        if let value = bundle.object(forInfoDictionaryKey: "AppGroupID") as? String, !value.isEmpty {
            return (value, "Info.plist(AppGroupID)")
        }

        #if os(watchOS)
        if let companionBundleID = Bundle.main.object(forInfoDictionaryKey: "WKCompanionAppBundleIdentifier") as? String,
           let teamID = extractTeamID(fromNightscoutBundleIdentifier: companionBundleID) {
            return (appGroupID(forTeamID: teamID), "Derived(WKCompanionAppBundleIdentifier)")
        }
        #endif

        if let teamID = extractTeamID(fromNightscoutBundleIdentifier: bundle.bundleIdentifier) {
            return (appGroupID(forTeamID: teamID), "Derived(bundleIdentifier)")
        }

        return (nil, "Unavailable")
    }

    // MARK: - UserDefaults Keys

    private static let lastReloadKey = "TrioComplication_lastReload"
    private static let lastValidTimestampKey = "TrioComplication_lastValidTimestamp"
    private static let reloadGenerationTokenKey = "TrioComplication_reloadGenerationToken"

    // MARK: - Persisted State (shared across processes via UserDefaults in App Group)

    /// Last valid glucose reading timestamp - persisted to survive process restarts.
    /// Falls back to in-memory storage if appGroupDefaults is unavailable.
    static var lastValidTimestamp: Date? {
        get {
            if let defaults = shared.appGroupDefaults,
               let date = defaults.object(forKey: lastValidTimestampKey) as? Date {
                return date
            }
            return shared.inMemoryLastValidTimestamp
        }
        set {
            if let defaults = shared.appGroupDefaults {
                defaults.set(newValue, forKey: lastValidTimestampKey)
            } else {
                // Only update in-memory fallback when App Group defaults are unavailable
                shared.inMemoryLastValidTimestamp = newValue
            }
        }
    }

    /// Last reload timestamp - persisted to share debounce state across processes
    /// Falls back to in-memory storage if appGroupDefaults is unavailable
    private var lastReload: Date {
        get {
            if let defaults = appGroupDefaults,
               let date = defaults.object(forKey: Self.lastReloadKey) as? Date {
                return date
            }
            // Fallback to in-memory storage when App Group is unavailable
            return inMemoryLastReload
        }
        set {
            if let defaults = appGroupDefaults {
                defaults.set(newValue, forKey: Self.lastReloadKey)
            }
            // Always update in-memory fallback for per-process debounce
            inMemoryLastReload = newValue
        }
    }

    /// Reload generation token - UUID string regenerated ONLY when an actual WidgetKit reload is initiated
    /// (coalescedReload passes debounce, or forceReload). Used to detect if a newer reload attempt has
    /// occurred since a retry was scheduled. Does NOT change on saves - only on actual reload initiation.
    /// Uses UUID string (not numeric) to avoid UserDefaults type coercion issues.
    static var reloadGenerationToken: String {
        get {
            if let defaults = shared.appGroupDefaults,
               let token = defaults.string(forKey: reloadGenerationTokenKey) {
                return token
            }
            // Fallback to in-memory storage when App Group is unavailable
            return shared.inMemoryReloadGenerationToken
        }
        set {
            if let defaults = shared.appGroupDefaults {
                defaults.set(newValue, forKey: reloadGenerationTokenKey)
            }
            // Always update in-memory fallback for per-process token tracking
            shared.inMemoryReloadGenerationToken = newValue
        }
    }

    // MARK: - Private Properties

    private let sharedContainerURLProvider: () -> URL?
    private let fileManager: FileManager
    private let snapshotFilename: String

    /// Pending retry work item - cancelled only when a new reload is actually initiated
    /// All access must be on main queue to avoid race conditions
    private var pendingRetryWorkItem: DispatchWorkItem?

    /// Unique ID of the currently pending retry (used to identify stale retries without capturing work item)
    private var pendingRetryID: UUID?

    /// In-memory fallback for lastReload when appGroupDefaults is nil (per-process debounce)
    private var inMemoryLastReload: Date = .distantPast

    /// In-memory fallback for reloadGenerationToken when appGroupDefaults is nil (per-process token)
    private var inMemoryReloadGenerationToken: String = UUID().uuidString

    /// In-memory fallback for lastValidTimestamp when appGroupDefaults is nil
    private var inMemoryLastValidTimestamp: Date?

    /// One-time flag to log appGroupDefaults unavailability
    private static var hasLoggedAppGroupUnavailable = false

    private var snapshotFileURL: URL? {
        sharedContainerURLProvider()?.appendingPathComponent(snapshotFilename)
    }

    private var appGroupDefaults: UserDefaults? {
        // Prefer the extension’s bundle (if present) because that is where Info.plist keys
        // like AppGroupID are expected to live for the complication extension.
        var bundle: Bundle = Bundle.main
        var bundleSource = "Bundle.main"

        let classBundle = Bundle(for: type(of: self))
        if classBundle.object(forInfoDictionaryKey: "AppGroupID") != nil {
            bundle = classBundle
            bundleSource = "Bundle(for: type(of: self))"
        }

        let bundleID = bundle.bundleIdentifier ?? "unknown"
        log("🔍 appGroupDefaults: Using bundle: \(bundleSource) (ID: \(bundleID))")

        let resolved = Self.resolveAppGroupID(bundle: bundle)
        guard let suiteName = resolved.value else {
            // Log once when App Group is unavailable
            if !Self.hasLoggedAppGroupUnavailable {
                Self.hasLoggedAppGroupUnavailable = true
                log("⚠️ AppGroupID unavailable (bundle: \(bundleSource), ID: \(bundleID)); using in-memory fallbacks for debounce/token")
            }
            return nil
        }

        log("✓ appGroupDefaults: Resolved AppGroupID: \(suiteName) (\(resolved.source))")
        let defaults = UserDefaults(suiteName: suiteName)
        if defaults == nil {
            if !Self.hasLoggedAppGroupUnavailable {
                Self.hasLoggedAppGroupUnavailable = true
                log("⚠️ App Group UserDefaults unavailable for suite: \(suiteName); using in-memory fallbacks for debounce/token")
            }
            return nil
        }
        log("✓ appGroupDefaults: UserDefaults created successfully for suite: \(suiteName)")
        return defaults
    }

    // MARK: - Debug Properties (for ComplicationDebugView)

    var lastReloadTimestamp: Date {
        lastReload
    }

    var secondsSinceLastReload: TimeInterval {
        Date().timeIntervalSince(lastReload)
    }

    var secondsUntilNextReloadAllowed: TimeInterval {
        max(0, 30 - secondsSinceLastReload)
    }

    var isDebounceActive: Bool {
        secondsSinceLastReload < 30
    }

    var appGroupContainerPath: String? {
        snapshotFileURL?.deletingLastPathComponent().path
    }

    // MARK: - Debug Properties for ComplicationDebugView

    var appGroupID: String? {
        // Mirror the same resolution logic used for persistence so the debug UI reflects reality.
        var bundle: Bundle = Bundle.main
        let classBundle = Bundle(for: type(of: self))
        if classBundle.object(forInfoDictionaryKey: "AppGroupID") != nil {
            bundle = classBundle
        }
        return Self.resolveAppGroupID(bundle: bundle).value
    }

    var appGroupContainerURL: URL? {
        guard let suiteName = appGroupID else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
    }

    var appGroupContainerAccessible: Bool {
        guard let url = appGroupContainerURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    var snapshotFileExists: Bool {
        guard let fileURL = snapshotFileURL else { return false }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    var snapshotFileSize: Int64? {
        guard let fileURL = snapshotFileURL,
              FileManager.default.fileExists(atPath: fileURL.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? Int64 else {
            return nil
        }
        return size
    }

    var snapshotFileAge: TimeInterval? {
        guard let fileURL = snapshotFileURL,
              FileManager.default.fileExists(atPath: fileURL.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        return Date().timeIntervalSince(modificationDate)
    }

    // MARK: - Initialization

    init(
        sharedContainerURLProvider: @escaping () -> URL? = TrioComplicationDataStore.defaultSharedContainerURL,
        fileManager: FileManager = .default,
        snapshotFilename: String = "snapshot.json"
    ) {
        self.sharedContainerURLProvider = sharedContainerURLProvider
        self.fileManager = fileManager
        self.snapshotFilename = snapshotFilename
    }

    // MARK: - Save Methods

    func save(
        glucose: String,
        trend: String?,
        delta: String?,
        readingDate: Date,
        date: Date,
        glucoseColor: String? = nil,
        triggerReload: Bool = true
    ) {
        let snapshot = TrioComplicationSnapshot(
            glucose: glucose,
            trend: trend ?? "",
            delta: delta ?? "",
            readingDate: readingDate,
            date: date,
            glucoseColor: glucoseColor
        )
        save(snapshot, triggerReload: triggerReload)
    }

    /// Saves a snapshot to disk. Main-thread confined.
    /// - Parameters:
    ///   - snapshot: The snapshot to save
    ///   - triggerReload: If true (default), triggers a coalesced reload after saving.
    ///                    Set to false to skip reload (e.g., if you plan to call `forceReload()` separately).
    ///                    Note: pending retries are preserved regardless of this flag; they are only
    ///                    cancelled when an actual reload is initiated.
    func save(_ snapshot: TrioComplicationSnapshot, triggerReload: Bool = true) {
        onMain { [self] in
            saveOnMain(snapshot, triggerReload: triggerReload)
        }
    }

    private func saveOnMain(_ snapshot: TrioComplicationSnapshot, triggerReload: Bool) {
        assert(Thread.isMainThread, "saveOnMain must be called on main thread")
        guard let fileURL = snapshotFileURL else {
            log("❌ Snapshot save FAILED: no App Group container URL")
            // Enhanced diagnostics
            let containerURL = sharedContainerURLProvider()
            log("🔍 Debug: sharedContainerURLProvider returned: \(containerURL?.path ?? "nil")")
            log("🔍 Debug: snapshotFilename: \(snapshotFilename)")
            return
        }

        log("💾 Saving snapshot: glucose=\(snapshot.glucose), trend=\(snapshot.trend), " +
            "delta=\(snapshot.delta), readingDate=\(formatDate(snapshot.readingDate))")
        log("🔍 Debug: Target file URL: \(fileURL.path)")

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            log("🔍 Debug: Encoded snapshot size: \(data.count) bytes")

            let containerDir = fileURL.deletingLastPathComponent()
            log("🔍 Debug: Container directory: \(containerDir.path)")
            log("🔍 Debug: Container directory exists: \(fileManager.fileExists(atPath: containerDir.path))")

            try fileManager.createDirectory(
                at: containerDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            log("🔍 Debug: Container directory created/verified")

            let backupURL = containerDir.appendingPathComponent("snapshot.bak")
            if fileManager.fileExists(atPath: fileURL.path) {
                log("🔍 Debug: Existing snapshot file found, creating backup")
                _ = try? fileManager.removeItem(at: backupURL)
                _ = try? fileManager.copyItem(at: fileURL, to: backupURL)
            } else {
                log("🔍 Debug: No existing snapshot file (first save or was deleted)")
            }

            try data.write(to: fileURL, options: [.atomic])
            log("🔍 Debug: File written successfully, verifying...")

            // Verify file was written
            if fileManager.fileExists(atPath: fileURL.path) {
                if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                   let fileSize = attributes[.size] as? Int64 {
                    log("🔍 Debug: File verified - size: \(fileSize) bytes")
                }
            } else {
                log("⚠️ WARNING: File write reported success but file doesn't exist!")
            }

            Self.lastValidTimestamp = snapshot.readingDate

            // Note: reloadGenerationToken is NOT updated here. It only changes when an actual reload
            // is initiated. This ensures pending retries remain valid even after saves with triggerReload=false.

            log("✅ Snapshot saved successfully")

            if triggerReload {
                coalescedReloadOnMain()
            }
        } catch {
            log("❌ Snapshot save FAILED: \(error.localizedDescription)")
            log("🔍 Debug: Error type: \(type(of: error))")
            log("🔍 Debug: Error domain: \((error as NSError).domain), code: \((error as NSError).code)")
            if let underlyingError = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError {
                log("🔍 Debug: Underlying error: \(underlyingError.localizedDescription)")
            }
            // Check file permissions
            let containerDir = fileURL.deletingLastPathComponent()
            if fileManager.fileExists(atPath: containerDir.path) {
                if let attributes = try? fileManager.attributesOfItem(atPath: containerDir.path),
                   let permissions = attributes[.posixPermissions] as? Int {
                    log("🔍 Debug: Container directory permissions: \(String(permissions, radix: 8))")
                }
            }
        }
    }

    // MARK: - Load Methods

    /// Loads the latest complication snapshot from disk.
    /// May be called from any thread. Updates `lastValidTimestamp` as a side-effect (serialized on main
    /// when App Group defaults are unavailable to protect in-memory fallback).
    func latestSnapshot() -> TrioComplicationSnapshot? {
        guard let fileURL = snapshotFileURL else {
            log("❌ Snapshot load FAILED: no App Group container URL")
            // Enhanced diagnostics
            let containerURL = sharedContainerURLProvider()
            log("🔍 Debug: sharedContainerURLProvider returned: \(containerURL?.path ?? "nil")")
            log("🔍 Debug: snapshotFilename: \(snapshotFilename)")
            return fallbackSnapshot(state: "--")
        }

        log("🔍 Debug: Attempting to load snapshot from: \(fileURL.path)")
        log("🔍 Debug: File exists: \(fileManager.fileExists(atPath: fileURL.path))")

        guard fileManager.fileExists(atPath: fileURL.path) else {
            log("⚠️ Snapshot file missing at \(fileURL.lastPathComponent)")
            // Check if container directory exists
            let containerDir = fileURL.deletingLastPathComponent()
            log("🔍 Debug: Container directory exists: \(fileManager.fileExists(atPath: containerDir.path))")
            if fileManager.fileExists(atPath: containerDir.path) {
                // List files in container
                if let files = try? fileManager.contentsOfDirectory(atPath: containerDir.path) {
                    log("🔍 Debug: Files in container: \(files.joined(separator: ", "))")
                }
            }
            return fallbackSnapshot(state: "!!")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        func decode(from url: URL) throws -> TrioComplicationSnapshot {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { throw NSError(domain: "EmptySnapshot", code: -1) }
            let snapshot = try decoder.decode(TrioComplicationSnapshot.self, from: data)
            // Update lastValidTimestamp; only hop to main when in-memory fallback is used
            let readingDate = snapshot.readingDate
            if appGroupDefaults == nil {
                onMain { Self.lastValidTimestamp = readingDate }
            } else {
                Self.lastValidTimestamp = readingDate
            }
            return snapshot
        }

        do {
            let snapshot = try decode(from: fileURL)
            let age = Int(Date().timeIntervalSince(snapshot.readingDate))
            log("📖 Loaded snapshot: glucose=\(snapshot.glucose), age=\(age)s")
            return snapshot
        } catch {
            let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent("snapshot.bak")
            if fileManager.fileExists(atPath: backupURL.path),
               let snapshot = try? decode(from: backupURL) {
                log("⚠️ Snapshot decode failed, using backup")
                return snapshot
            }
            log("❌ Snapshot decode FAILED: \(error.localizedDescription)")
            return fallbackSnapshot(state: "??")
        }
    }

    // MARK: - Reload Methods

    /// Triggers a complication timeline reload with 30-second debouncing. Main-thread confined.
    /// - Parameters:
    ///   - minInterval: Minimum time interval between reloads (default: 30 seconds)
    ///   - isRetry: If true, this is a retry attempt and should not schedule another retry
    func coalescedReload(minInterval: TimeInterval = 30, isRetry: Bool = false) {
        onMain { [self] in
            coalescedReloadOnMain(minInterval: minInterval, isRetry: isRetry)
        }
    }

    private func coalescedReloadOnMain(minInterval: TimeInterval = 30, isRetry: Bool = false) {
        assert(Thread.isMainThread, "coalescedReloadOnMain must be called on main thread")
        let now = Date()
        let elapsed = now.timeIntervalSince(lastReload)

        if elapsed < minInterval {
            log("⏳ Reload DEBOUNCED: \(Int(elapsed))s elapsed (min: \(Int(minInterval))s)")
            return
        }

        // Cancel any pending retry since we're initiating a new reload
        cancelPendingRetryOnMain(reason: "superseded by new reload")

        // Generate new reload generation token (only changes when actual reload occurs)
        Self.reloadGenerationToken = UUID().uuidString

        log("🔄 Reload TRIGGERED: \(Int(elapsed))s since last reload\(isRetry ? " (retry)" : "")")
        lastReload = now
        reloadTimeline()

        // Schedule a single bounded retry after the debounce window, unless this is already a retry.
        // WidgetKit reloads can be dropped/delayed; we do one bounded retry after the debounce window
        // unless a newer reload occurs.
        if !isRetry {
            scheduleRetryAfterReloadOnMain(minInterval: minInterval)
        }
    }

    /// Forces an immediate complication timeline reload, bypassing the debounce. Main-thread confined.
    func forceReload() {
        onMain { [self] in
            forceReloadOnMain()
        }
    }

    private func forceReloadOnMain() {
        assert(Thread.isMainThread, "forceReloadOnMain must be called on main thread")

        // Cancel any pending retry since we're initiating a new reload
        cancelPendingRetryOnMain(reason: "superseded by force reload")

        // Generate new reload generation token (only changes when actual reload occurs)
        Self.reloadGenerationToken = UUID().uuidString

        log("🔄 FORCE reload triggered (bypassing debounce)")
        lastReload = Date()
        reloadTimeline()

        // Schedule a single bounded retry after the debounce window.
        // WidgetKit reloads can be dropped/delayed; we do one bounded retry after the debounce window
        // unless a newer reload occurs.
        scheduleRetryAfterReloadOnMain(minInterval: 30)
    }

    #if canImport(WidgetKit)
        private func reloadTimeline() {
            log("🔔 Calling WidgetCenter.reloadTimelines(ofKind: \(Self.complicationKind))")

            let reloadBlock = {
                if #available(watchOS 10.0, *) {
                    WidgetCenter.shared.reloadTimelines(ofKind: Self.complicationKind)
                } else {
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }

            if Thread.isMainThread {
                reloadBlock()
            } else {
                DispatchQueue.main.async(execute: reloadBlock)
            }
        }
    #endif

    // MARK: - Private Helpers (Main-Thread Confined)

    /// Executes a block on the main thread. If already on main, runs inline; otherwise dispatches
    /// asynchronously. Callers must NOT assume the work has completed when this method returns.
    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    /// Cancels any pending retry work item. Must be called on main queue.
    /// - Parameter reason: Reason for cancellation (for logging)
    private func cancelPendingRetryOnMain(reason: String) {
        assert(Thread.isMainThread, "cancelPendingRetryOnMain must be called on main thread")
        if pendingRetryWorkItem != nil {
            pendingRetryWorkItem?.cancel()
            pendingRetryWorkItem = nil
            pendingRetryID = nil
            log("⏹️ Retry CANCELLED: \(reason)")
        }
    }

    /// Schedules a single bounded retry after the debounce window. Must be called on main queue.
    /// - Parameter minInterval: The debounce interval used for the reload (default: 30 seconds)
    /// The retry will be skipped if a newer reload has been initiated (reloadGenerationToken changes).
    private func scheduleRetryAfterReloadOnMain(minInterval: TimeInterval) {
        assert(Thread.isMainThread, "scheduleRetryAfterReloadOnMain must be called on main thread")

        // Capture the reload generation token at the time of this reload
        let tokenAtReload = Self.reloadGenerationToken

        // Generate unique ID for this retry (used to detect stale retries without self-referential capture)
        let retryID = UUID()
        pendingRetryID = retryID

        // Schedule retry after minInterval + 1s cushion to ensure it's outside the debounce window
        let retryDelay = minInterval + 1.0
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            // Check if this retry is still current (may have been replaced or cancelled)
            guard self.pendingRetryID == retryID else { return }

            // Clear pending retry state now that we're executing
            self.pendingRetryWorkItem = nil
            self.pendingRetryID = nil

            // Check if a newer reload has occurred (token changes only on actual reload initiation)
            if Self.reloadGenerationToken != tokenAtReload {
                let prefix = String(tokenAtReload.prefix(8))
                self.log("⏭️ Retry SKIPPED: newer reload occurred (token changed from '\(prefix)...')")
                return
            }

            // Retry the reload, but mark it as a retry so it doesn't schedule another retry
            self.log("🔄 Retry reload triggered after \(Int(retryDelay))s")
            self.coalescedReloadOnMain(minInterval: minInterval, isRetry: true)
        }

        pendingRetryWorkItem = workItem
        log("⏰ Retry scheduled: delay=\(Int(retryDelay))s, token='\(tokenAtReload.prefix(8))...'")
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: workItem)
    }

    private func fallbackSnapshot(state: String) -> TrioComplicationSnapshot {
        TrioComplicationSnapshot(
            glucose: "--",
            trend: "",
            delta: "--",
            readingDate: Self.lastValidTimestamp ?? .distantPast,
            date: Date(),
            state: state,
            glucoseColor: nil
        )
    }

    private static func defaultSharedContainerURL() -> URL? {
        // In Widget Extensions, Bundle.main should be the extension bundle, but try multiple approaches
        var bundle: Bundle = Bundle.main
        var bundleSource = "Bundle.main"

        // Try to find the extension bundle by looking for the class's bundle
        let classBundle = Bundle(for: TrioComplicationDataStore.self)
        // Check if this bundle has the AppGroupID key
        if classBundle.object(forInfoDictionaryKey: "AppGroupID") != nil {
            bundle = classBundle
            bundleSource = "Bundle(for: TrioComplicationDataStore.self)"
        }

        let bundleID = bundle.bundleIdentifier ?? "unknown"
        NSLog("[ComplicationDataStore] 🔍 defaultSharedContainerURL: Using bundle: %@ (ID: %@)", bundleSource, bundleID)

        let resolved = resolveAppGroupID(bundle: bundle)
        guard let suiteName = resolved.value else {
            NSLog("[ComplicationDataStore] ❌ AppGroupID unresolved (bundle: %@, ID: %@)", bundleSource, bundleID)
            return nil
        }

        NSLog("[ComplicationDataStore] ✓ Resolved AppGroupID (%@): %@", resolved.source, suiteName)
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName) else {
            NSLog("[ComplicationDataStore] ❌ Failed to get container URL for AppGroupID: %@", suiteName)
            return nil
        }

        NSLog("[ComplicationDataStore] ✓ Container URL: %@", containerURL.path)
        return containerURL
    }

    private func formatDate(_ date: Date) -> String {
        if date == .distantPast { return "distantPast" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func log(_ message: String) {
        NSLog("[ComplicationDataStore] %@", message)
    }
}
