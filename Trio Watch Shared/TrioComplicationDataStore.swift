import Foundation
import os
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

/// Record of a complication reload request for instrumentation (WidgetKit budget/coalescing correlation).
/// requestedAtEpochSeconds is the reload request time, not the CGM reading time. Do not use reading_date_epoch here.
struct ComplicationReloadRecord: Codable {
    let id: UUID
    /// Reload request time (Int(Date().timeIntervalSince1970)). Not CGM reading time.
    let requestedAtEpochSeconds: Int
}

/// Ring buffer of reload records in App Group UserDefaults. Watch app writes; complication extension reads only.
/// Best-effort, not lossless: concurrent or overlapping writes can drop records; decode failure on read is treated as empty.
private enum ComplicationReloadRing {
    static let key = "complication_reload_ring"
    static let capacity = 64

    /// Appends a record to the ring (watch app only). Drops oldest if count > capacity.
    static func append(_ record: ComplicationReloadRecord, suiteName: String) {
        let defaults = UserDefaults(suiteName: suiteName)
        guard let defaults else { return }
        var list = (defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([ComplicationReloadRecord].self, from: $0) }) ?? []
        list.append(record)
        if list.count > capacity {
            list = Array(list.suffix(capacity))
        }
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: key)
        }
    }

    /// Returns the newest record (most recent reload request). Complication extension reads only.
    static func newestRecord(suiteName: String?) -> ComplicationReloadRecord? {
        guard let suiteName,
              let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([ComplicationReloadRecord].self, from: data),
              let last = list.last else { return nil }
        return last
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

        guard let trioRange = afterPrefix.range(of: ".trio") else { return nil }
        let teamID = String(afterPrefix[..<trioRange.lowerBound])
        guard !teamID.isEmpty else { return nil }
        return teamID
    }

    /// Resolves the App Group ID using multiple fallbacks, in priority order:
    /// 1) `AppGroupID` key in the chosen bundle's Info.plist
    /// 2) Derive from the watch app's `WKCompanionAppBundleIdentifier` (watchOS only)
    /// 3) Derive from the chosen bundle's bundle identifier
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
    private static let reloadGenerationKey = "TrioComplication_reloadGeneration"
    private static let lastReloadRequestEpochSecondsKey = "TrioComplication_lastReloadRequestEpochSeconds"
    static let latencyValidityWindowSeconds = 600

    /// Reused for structured log fields (reading_date); avoids per-call allocation.
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

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
            return inMemoryLastReload
        }
        set {
            if let defaults = appGroupDefaults {
                defaults.set(newValue, forKey: Self.lastReloadKey)
            }
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
            return shared.inMemoryReloadGenerationToken
        }
        set {
            if let defaults = shared.appGroupDefaults {
                defaults.set(newValue, forKey: reloadGenerationTokenKey)
            }
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

    /// In-memory cache of the last saved snapshot, used for dedup without per-save disk I/O
    private var inMemorySavedSnapshot: TrioComplicationSnapshot?
    /// Remaining cold-start seeding attempts (hydrates inMemorySavedSnapshot from disk)
    private var seedAttemptsRemaining = 2

    /// Burst window ID — increments each time a reload is triggered (Phase 2.1). In-memory only.
    private var burstWindowId = 0
    /// Number of reload calls debounced in the current burst window; reset to 0 when a reload fires (Phase 2.1).
    private var reloadSuppressionCount = 0

    /// Thread-safe one-time flags for logging (accessed from multiple threads via latestSnapshot).
    private static let flagLock = OSAllocatedUnfairLock(initialState: (appGroupUnavailable: false, diagnostics: false))

    /// Optional log forwarder (e.g. to WatchLogger). Set only by the Watch App Extension; complication extension never sets it.
    /// Guarded by logForwarderLock because log() can be called from any thread (e.g. latestSnapshot() from WidgetKit's queue).
    private static let logForwarderLock = OSAllocatedUnfairLock(initialState: LogForwarderState())
    private struct LogForwarderState {
        var forwarder: ((String) -> Void)?
    }

    /// Set from the Watch App Extension at launch so TrioComplicationDataStore logs also go to WatchLogger. Only set in Watch App Extension; complication extension has no WatchLogger so forwarder stays nil there.
    static func setLogForwarder(_ forwarder: ((String) -> Void)?) {
        logForwarderLock.withLock { $0.forwarder = forwarder }
    }

    private var snapshotFileURL: URL? {
        sharedContainerURLProvider()?.appendingPathComponent(snapshotFilename)
    }

    /// Cached at init time to avoid repeated bundle resolution, App Group ID lookup, and logging per access.
    private let cachedAppGroupDefaults: UserDefaults?

    private var appGroupDefaults: UserDefaults? {
        cachedAppGroupDefaults
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

        // Resolve appGroupDefaults once at init (avoids repeated bundle/logging overhead per access).
        self.cachedAppGroupDefaults = Self.resolveAppGroupDefaultsOnce()

        logAppGroupDiagnosticsOnce(context: "init")
    }

    /// One-shot resolution of App Group UserDefaults. Called once from init.
    private static func resolveAppGroupDefaultsOnce() -> UserDefaults? {
        var bundle: Bundle = Bundle.main
        let classBundle = Bundle(for: TrioComplicationDataStore.self)
        if classBundle.object(forInfoDictionaryKey: "AppGroupID") != nil {
            bundle = classBundle
        }

        let resolved = resolveAppGroupID(bundle: bundle)
        guard let suiteName = resolved.value else {
            flagLock.withLock { state in
                guard !state.appGroupUnavailable else { return }
                state.appGroupUnavailable = true
            }
            return nil
        }

        let defaults = UserDefaults(suiteName: suiteName)
        if defaults == nil {
            flagLock.withLock { state in
                guard !state.appGroupUnavailable else { return }
                state.appGroupUnavailable = true
            }
        }
        return defaults
    }

    /// One-line, high-signal diagnostics for App Group resolution and container access.
    /// Safe to call from any process that includes this file (watch app and complication extension).
    func diagnosticsSummary(context: String = "runtime") -> String {
        var bundle: Bundle = Bundle.main
        var bundleSource = "Bundle.main"
        let classBundle = Bundle(for: type(of: self))
        if classBundle.object(forInfoDictionaryKey: "AppGroupID") != nil {
            bundle = classBundle
            bundleSource = "Bundle(for: type(of: self))"
        }

        let bundleID = bundle.bundleIdentifier ?? "unknown"
        let resolved = Self.resolveAppGroupID(bundle: bundle)

        let suiteName = resolved.value
        let defaultsOK = suiteName.flatMap { UserDefaults(suiteName: $0) } != nil
        let containerURL = suiteName.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }

        let snapshotPath = containerURL?.appendingPathComponent(snapshotFilename).path
        let snapshotExists = snapshotPath.map { fileManager.fileExists(atPath: $0) } ?? false

        return "AppGroupDiagnostics(\(context)): bundle=\(bundleSource) id=\(bundleID) AppGroupID=\(suiteName ?? "nil") source=\(resolved.source) defaults=\(defaultsOK) container=\(containerURL?.path ?? "nil") snapshot=\(snapshotPath ?? "nil") exists=\(snapshotExists)"
    }

    private func logAppGroupDiagnosticsOnce(context: String) {
        let shouldLog = Self.flagLock.withLock { state -> Bool in
            guard !state.diagnostics else { return false }
            state.diagnostics = true
            return true
        }
        if shouldLog {
            log(diagnosticsSummary(context: context))
        }
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
    func save(_ snapshot: TrioComplicationSnapshot, triggerReload: Bool = true, minInterval: TimeInterval = 30) {
        onMain { [self] in
            saveOnMain(snapshot, triggerReload: triggerReload, minInterval: minInterval)
        }
    }

    private func saveOnMain(_ snapshot: TrioComplicationSnapshot, triggerReload: Bool, minInterval: TimeInterval = 30) {
        assert(Thread.isMainThread, "saveOnMain must be called on main thread")
        log("saveOnMain entered: glucose=\(snapshot.glucose), readingDate=\(snapshot.readingDate)")

        // Future-skew guard: reject snapshots with readingDate more than 2 minutes in the future.
        if snapshot.readingDate.timeIntervalSinceNow > 120 {
            log("⚠️ Dedup: rejected future snapshot (readingDate=\(snapshot.readingDate), now=\(Date()))")
            return
        }

        // Cold-start cache seeding: hydrate from disk on first save after process launch.
        // Allows up to 2 attempts to handle transient I/O failures; if both fail,
        // the lastValidTimestamp monotonic fallback (below) guards against recency regression.
        if inMemorySavedSnapshot == nil, seedAttemptsRemaining > 0 {
            seedAttemptsRemaining -= 1
            inMemorySavedSnapshot = latestSnapshot()
            if inMemorySavedSnapshot == nil {
                log("⚠️ Dedup seed: no persisted snapshot (attempts remaining: \(seedAttemptsRemaining))")
            }
        }

        // Dedup + newer-wins guard using in-memory cache (no per-save disk I/O)
        if let existing = inMemorySavedSnapshot {
            let timeDiff = snapshot.readingDate.timeIntervalSince(existing.readingDate)
            if timeDiff < 0.0 {
                log("⏭️ Dedup: rejected older snapshot (timeDiff=\(String(format: "%.3f", timeDiff))s)")
                return
            }
            // 1s tolerance is semantic policy: two readings within 1s with identical
            // display data are treated as duplicates. Safe for all supported CGMs (minimum
            // interval: 1 min for Libre 3, 5 min for G6/G7).
            if timeDiff < 1.0, existing.glucose == snapshot.glucose,
               existing.trend == snapshot.trend, existing.delta == snapshot.delta,
               existing.glucoseColor == snapshot.glucoseColor, existing.state == snapshot.state {
                log("⏭️ Dedup: skipped duplicate snapshot at \(snapshot.readingDate)")
                return
            }
        } else if let lastTS = Self.lastValidTimestamp {
            // Monotonic fallback: snapshot file was unreadable (seeding exhausted) but
            // lastValidTimestamp in UserDefaults records the last known good readingDate.
            if snapshot.readingDate.timeIntervalSince(lastTS) < 0.0 {
                log("⏭️ Dedup: rejected older snapshot via lastValidTimestamp fallback (readingDate=\(snapshot.readingDate), lastValid=\(lastTS))")
                return
            }
        }

        guard let fileURL = snapshotFileURL else {
            log("❌ Snapshot save FAILED: no App Group container URL")
            return
        }

        log("saveOnMain: passed dedup, writing snapshot")
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)

            let containerDir = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: containerDir,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let backupURL = containerDir.appendingPathComponent("snapshot.bak")
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try? fileManager.removeItem(at: backupURL)
                _ = try? fileManager.copyItem(at: fileURL, to: backupURL)
            }

            try data.write(to: fileURL, options: [.atomic])
            self.inMemorySavedSnapshot = snapshot
            Self.lastValidTimestamp = snapshot.readingDate
            let ageSec = max(0, Int(Date().timeIntervalSince(snapshot.readingDate)))

            log("✅ Snapshot saved: glucose=\(snapshot.glucose), trend=\(snapshot.trend), delta=\(snapshot.delta), snapshot_age_seconds=\(ageSec)")
            log("event=complication_save_age age_seconds=\(ageSec) reading_date_epoch_seconds=\(Int(snapshot.readingDate.timeIntervalSince1970)) reading_date=\(Self.iso8601Formatter.string(from: snapshot.readingDate))")

            if triggerReload {
                coalescedReloadOnMain(minInterval: minInterval, scheduleRetry: false)
            }
        } catch {
            log("❌ Snapshot save FAILED: \(error.localizedDescription) (domain: \((error as NSError).domain), code: \((error as NSError).code))")
        }
    }

    // MARK: - Load Methods

    /// Returns the most recent complication reload record, if any (for getTimeline instrumentation).
    /// Complication extension reads only; do not write from the complication.
    func newestReloadRecord() -> ComplicationReloadRecord? {
        ComplicationReloadRing.newestRecord(suiteName: appGroupID)
    }

    func currentReloadGeneration() -> Int? {
        guard let defaults = appGroupDefaults else { return nil }
        return defaults.object(forKey: Self.reloadGenerationKey) != nil
            ? defaults.integer(forKey: Self.reloadGenerationKey)
            : nil
    }

    func lastReloadRequestEpochSeconds() -> Int? {
        guard let defaults = appGroupDefaults else { return nil }
        return defaults.object(forKey: Self.lastReloadRequestEpochSecondsKey) != nil
            ? defaults.integer(forKey: Self.lastReloadRequestEpochSecondsKey)
            : nil
    }

    func isAppGroupAvailable() -> Bool {
        appGroupDefaults != nil
    }

    /// Loads the latest complication snapshot from disk.
    /// May be called from any thread. Updates `lastValidTimestamp` as a side-effect (serialized on main
    /// when App Group defaults are unavailable to protect in-memory fallback).
    func latestSnapshot() -> TrioComplicationSnapshot? {
        guard let fileURL = snapshotFileURL else {
            log("❌ Snapshot load FAILED: no App Group container URL")
            return fallbackSnapshot(state: "--")
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            log("⚠️ Snapshot file missing at \(fileURL.lastPathComponent)")
            return fallbackSnapshot(state: "!!")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        func decode(from url: URL) throws -> TrioComplicationSnapshot {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { throw NSError(domain: "EmptySnapshot", code: -1) }
            let snapshot = try decoder.decode(TrioComplicationSnapshot.self, from: data)
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

    private func coalescedReloadOnMain(minInterval: TimeInterval = 30, isRetry: Bool = false, scheduleRetry: Bool = true) {
        assert(Thread.isMainThread, "coalescedReloadOnMain must be called on main thread")
        let now = Date()
        let elapsed = now.timeIntervalSince(lastReload)

        if elapsed < minInterval {
            reloadSuppressionCount += 1
            let elapsedStr = String(format: "%.3f", elapsed)
            let minStr = String(format: "%.3f", minInterval)
            log("⏳ Reload DEBOUNCED burst_window_id=\(burstWindowId) suppressed=\(reloadSuppressionCount) elapsed=\(elapsedStr)s min=\(minStr)s")
            return
        }

        cancelPendingRetryOnMain(reason: "superseded by new reload")
        Self.reloadGenerationToken = UUID().uuidString

        let elapsedStr = String(format: "%.3f", elapsed)
        log("🔄 Reload TRIGGERED burst_window_id=\(burstWindowId) suppressed=\(reloadSuppressionCount) elapsed=\(elapsedStr)s since last reload\(isRetry ? " (retry)" : "")")
        burstWindowId += 1
        reloadSuppressionCount = 0
        lastReload = now
        reloadTimeline()

        guard scheduleRetry else {
            log("⏭️ Retry skipped: scheduleRetry=false (save path)")
            return
        }
        if !isRetry {
            scheduleRetryAfterReloadOnMain(minInterval: minInterval)
        }
    }

    /// Forces an immediate complication timeline reload, bypassing the debounce. Main-thread confined.
    /// - Parameter scheduleRetry: If true (default), schedules a retry after the reload.
    ///   Pass false for paths that fire infrequently (e.g., forceComplicationUpdate).
    func forceReload(scheduleRetry: Bool = true) {
        onMain { [self] in
            forceReloadOnMain(scheduleRetry: scheduleRetry)
        }
    }

    private func forceReloadOnMain(scheduleRetry: Bool = true) {
        assert(Thread.isMainThread, "forceReloadOnMain must be called on main thread")
        cancelPendingRetryOnMain(reason: "superseded by force reload")
        Self.reloadGenerationToken = UUID().uuidString
        log("🔄 FORCE reload triggered (bypassing debounce)")
        lastReload = Date()
        reloadTimeline()
        if scheduleRetry {
            scheduleRetryAfterReloadOnMain(minInterval: 30)
        }
    }

    #if canImport(WidgetKit)
        /// Must only be called from the Watch App; the Widget extension must not write the ring (enforced by #if !WIDGET_EXTENSION).
        private func reloadTimeline() {
            let requestedAtEpochSeconds = Int(Date().timeIntervalSince1970)
            let record = ComplicationReloadRecord(id: UUID(), requestedAtEpochSeconds: requestedAtEpochSeconds)
            var reloadGeneration: Int = -1
            #if !WIDGET_EXTENSION
            if let suiteName = appGroupID {
                ComplicationReloadRing.append(record, suiteName: suiteName)
            }
            if let defaults = appGroupDefaults {
                let current = defaults.integer(forKey: Self.reloadGenerationKey)
                reloadGeneration = current + 1
                defaults.set(reloadGeneration, forKey: Self.reloadGenerationKey)
                defaults.set(requestedAtEpochSeconds, forKey: Self.lastReloadRequestEpochSecondsKey)
            }
            #endif
            log("event=complication_reload_requested reload_generation=\(reloadGeneration) reload_requested_at_epoch_seconds=\(record.requestedAtEpochSeconds) reload_id=\(record.id.uuidString)")

            if let lastTS = Self.lastValidTimestamp {
                let ageSec = max(0, Int(Date().timeIntervalSince(lastTS)))
                log("event=complication_reload_age age_seconds=\(ageSec) reading_date_epoch_seconds=\(Int(lastTS.timeIntervalSince1970)) reading_date=\(Self.iso8601Formatter.string(from: lastTS))")
            }
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

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func cancelPendingRetryOnMain(reason: String) {
        assert(Thread.isMainThread, "cancelPendingRetryOnMain must be called on main thread")
        if pendingRetryWorkItem != nil {
            pendingRetryWorkItem?.cancel()
            pendingRetryWorkItem = nil
            pendingRetryID = nil
            log("⏹️ Retry CANCELLED: \(reason)")
        }
    }

    private func scheduleRetryAfterReloadOnMain(minInterval: TimeInterval) {
        assert(Thread.isMainThread, "scheduleRetryAfterReloadOnMain must be called on main thread")

        let tokenAtReload = Self.reloadGenerationToken
        let retryID = UUID()
        pendingRetryID = retryID

        let retryDelay = minInterval + 1.0
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.pendingRetryID == retryID else { return }

            self.pendingRetryWorkItem = nil
            self.pendingRetryID = nil

            if Self.reloadGenerationToken != tokenAtReload {
                let prefix = String(tokenAtReload.prefix(8))
                self.log("⏭️ Retry SKIPPED: newer reload occurred (token changed from '\(prefix)...')")
                return
            }

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
        var bundle: Bundle = Bundle.main
        let classBundle = Bundle(for: TrioComplicationDataStore.self)
        if classBundle.object(forInfoDictionaryKey: "AppGroupID") != nil {
            bundle = classBundle
        }

        let resolved = resolveAppGroupID(bundle: bundle)
        guard let suiteName = resolved.value else {
            return nil
        }

        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName) else {
            return nil
        }

        return containerURL
    }

    private func formatDate(_ date: Date) -> String {
        if date == .distantPast { return "distantPast" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

#if WIDGET_EXTENSION
    func logWidgetGetTimelineInvocation(
        appGroupAvailable: Bool,
        observedGenerationSource: String,
        observedReloadGeneration: Int,
        generationDelta: Int,
        providerInstanceId: String,
        providerRestart: Bool,
        latencyValid: Bool,
        latencySeconds: Int,
        reloadRequestedAtEpochSeconds: Int,
        mostRecentReloadId: String
    ) {
        log(
            "event=complication_get_timeline_called"
            + " app_group_available=\(appGroupAvailable)"
            + " observed_generation_source=\(observedGenerationSource)"
            + " observed_reload_generation=\(observedReloadGeneration)"
            + " generation_delta=\(generationDelta)"
            + " provider_instance_id=\(providerInstanceId)"
            + " provider_restart=\(providerRestart)"
            + " latency_valid=\(latencyValid)"
            + " latency_seconds=\(latencySeconds)"
            + " reload_requested_at_epoch_seconds=\(reloadRequestedAtEpochSeconds)"
            + " most_recent_reload_id=\(mostRecentReloadId)"
        )
    }
#endif

    private func log(_ message: String) {
        ComplicationLogBuffer.append(message)
        let forwarder = Self.logForwarderLock.withLock { $0.forwarder }
        forwarder?(message)
    }
}
