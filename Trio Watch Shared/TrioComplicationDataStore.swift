import Foundation
import os
#if os(watchOS)
import WatchConnectivity
#endif
import WidgetKit

enum TrioComplicationDataSource: String, Codable, Equatable {
    case watchConnectivity = "watch_connectivity"
    case healthKit = "healthkit"
    case g7DirectBLE = "g7_direct_ble"
    case unknown = "unknown"

    var shortLabel: String {
        switch self {
        case .watchConnectivity: return "Phone"
        case .healthKit: return "HK"
        case .g7DirectBLE: return "BLE"
        case .unknown: return "?"
        }
    }

    /// Tie-break priority when the same CGM reading arrives via multiple channels. Higher wins.
    /// Used by both `TrioComplicationDataStore.shouldUpdate` (complication-store dedup) and
    /// `WatchState.tryAttributeDisplayedReadingSource` (live UI attribution) so the two paths
    /// agree about which source should win on a sequence tie.
    var priority: Int {
        switch self {
        case .g7DirectBLE: return 3
        case .watchConnectivity: return 2
        case .healthKit: return 1
        case .unknown: return 0
        }
    }
}

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
    let source: TrioComplicationDataSource?
    /// G7 EGV sequence when known; optional same-reading identity alongside `readingDate`.
    let sequence: Int?

    // INVARIANT (Phase 3.4): All display-field sanitization here.
    // Dedup always compares sanitized values.
    init(
        glucose rawGlucose: String,
        trend rawTrend: String,
        delta rawDelta: String,
        readingDate: Date,
        date: Date,
        state: String? = nil,
        glucoseColor: String? = nil,
        source: TrioComplicationDataSource? = nil,
        sequence: Int? = nil
    ) {
        glucose = Self.sanitizedGlucose(from: rawGlucose)
        trend = rawTrend.trimmingCharacters(in: .whitespacesAndNewlines)
        delta = Self.sanitizedDelta(from: rawDelta)
        self.readingDate = readingDate
        self.date = date
        self.state = state
        self.glucoseColor = glucoseColor
        self.source = source
        self.sequence = sequence
    }

    private static func sanitizedGlucose(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Constants.fallbackGlucose }
        if trimmed == Constants.fallbackGlucose { return Constants.fallbackGlucose }

        // C-209-6 (review 1.10): normalize comma decimals BEFORE extracting the numeric
        // portion — without this, comma-locale mmol "5,6" concatenated to "56". Mirrors
        // sanitizedDelta, which always had this normalization.
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        let digitsAndSeparators = CharacterSet(charactersIn: "0123456789.")
        let numericPortion = normalized
            .components(separatedBy: digitsAndSeparators.inverted)
            .joined()

        if let doubleValue = Double(numericPortion), doubleValue > 0 {
            // C-209-6 (review 1.10): mmol/L-range values keep one decimal — integer rounding
            // turned "5.6" into "6". mg/dL values (≥ 40 by CGM display floor) keep integer
            // rounding, and whole-number mmol values still collapse to the bare integer.
            if doubleValue < 40 {
                let tenths = (doubleValue * 10).rounded() / 10
                return tenths == tenths.rounded()
                    ? String(Int(tenths))
                    : String(format: "%.1f", tenths)
            }
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

// Phase 3.0 — pre-dispatch dedup. saveOnMain is authoritative.
// glucoseColor excluded: see shouldUpdate comment (Phase 3.2) for rationale.
struct ComplicationSnapshotFingerprint: Codable, Equatable {
    let readingDateEpoch: Int
    let glucose: String
    let trend: String
    let delta: String
    let state: String
    let source: String
}

extension ComplicationSnapshotFingerprint {
    init(from snapshot: TrioComplicationSnapshot) {
        readingDateEpoch = Int(snapshot.readingDate.timeIntervalSince1970)
        glucose = snapshot.glucose
        trend = snapshot.trend
        delta = snapshot.delta
        // Sentinel for nil: state is always optional in the model; sentinel ensures
        // nil and non-nil are always distinguishable in Equatable comparison.
        state = snapshot.state ?? "<nil>"
        source = snapshot.source?.rawValue ?? "<nil>"
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
    /// C-209-7 (review 5.9): the generation the widget last serviced at getTimeline.
    /// Widget-owned key — the app only reads it (the no-widget-writes rule is ring-specific).
    private static let widgetObservedGenerationKey = "TrioComplication_widgetObservedReloadGeneration"
    private static let fingerprintKey = "complication_last_saved_fingerprint"
    // R5d — last time any data channel delivered data to the watch (persisted for sleep-gap detection)
    private static let lastDataReceivedAtKey = "TrioComplication_lastDataReceivedAt"
    private static let lastWidgetReloadAtKey = "TrioComplication_lastWidgetReloadAt"

    // R6.1 — HealthKit anchored query state (watch app extension only)
    private static let hkGlucoseAnchorKey = "TrioComplication_hkGlucoseAnchor"
    private static let hkLastReceivedGlucoseEpochKey = "TrioComplication_hkLastReceivedGlucoseEpoch"
    private static let hkLastReceivedGlucoseValueMgDlKey = "TrioComplication_hkLastReceivedGlucoseValueMgDl"
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
    // Eventually consistent. Monotonic guard reduces but does not eliminate TOCTOU.
    // Accepted. Do not use NSFileCoordinator (blocks provider) or flock (invalid
    // cross-process on Darwin). Phase 3.3.
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

    // Phase 3.0 — serial queue for fingerprint dedup decisions. Decision-only; save dispatched outside.
    private let dedupQueue = DispatchQueue(label: "com.trio.complication.dedup", qos: .utility)

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

    /// C-209-8 (6.10): saves since the last `.bak` refresh. Starts ≥10 so the first save of
    /// each process refreshes the backup.
    private var savesSinceBackup = 10

    /// C-209-7 (review 5.9): unserviced-reload detector state. Main-thread confined, like the
    /// retry machinery. The rate limit bounds the retry chain to one extra reload request per
    /// window during a true WidgetKit budget blackout (or when no complication is on the face).
    private var unservicedCheckWorkItem: DispatchWorkItem?
    private var lastUnservicedRetryAt: Date = .distantPast
    private static let unservicedCheckDelay: TimeInterval = 120
    private static let unservicedRetryMinInterval: TimeInterval = 15 * 60

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

    // MARK: - R6.1 HealthKit anchor and previous-sample persistence

    /// R6.1 — Persisted HKQueryAnchor (encoded Data). Used by watch app extension only.
    func hkGlucoseAnchor() -> Data? {
        appGroupDefaults?.data(forKey: Self.hkGlucoseAnchorKey)
    }

    /// R6.1 — Save encoded anchor after successful anchored query.
    func saveHKGlucoseAnchor(_ data: Data) {
        appGroupDefaults?.set(data, forKey: Self.hkGlucoseAnchorKey)
    }

    /// R6.1 — Epoch (startDate.timeIntervalSince1970) of last processed glucose sample.
    func hkLastReceivedGlucoseEpoch() -> TimeInterval {
        appGroupDefaults?.double(forKey: Self.hkLastReceivedGlucoseEpochKey) ?? 0
    }

    func setHKLastReceivedGlucoseEpoch(_ epoch: TimeInterval) {
        appGroupDefaults?.set(epoch, forKey: Self.hkLastReceivedGlucoseEpochKey)
    }

    /// R6.1 — Glucose value (mg/dL) of last processed sample (for delta/trend derivation).
    func hkLastReceivedGlucoseValueMgDl() -> Double {
        appGroupDefaults?.double(forKey: Self.hkLastReceivedGlucoseValueMgDlKey) ?? 0
    }

    func setHKLastReceivedGlucoseValueMgDl(_ value: Double) {
        appGroupDefaults?.set(value, forKey: Self.hkLastReceivedGlucoseValueMgDlKey)
    }

    // MARK: - R5d Sleep-Gap State

    /// Epoch of last data delivery from any channel. Returns nil if never set.
    func lastDataReceivedAt() -> Date? {
        guard let defaults = appGroupDefaults else { return nil }
        let epoch = defaults.double(forKey: Self.lastDataReceivedAtKey)
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }

    func setLastDataReceivedAt(_ date: Date) {
        appGroupDefaults?.set(date.timeIntervalSince1970, forKey: Self.lastDataReceivedAtKey)
    }

    /// Epoch of last forced widget reload. Returns nil if never set.
    func lastWidgetReloadAt() -> Date? {
        guard let defaults = appGroupDefaults else { return nil }
        let epoch = defaults.double(forKey: Self.lastWidgetReloadAtKey)
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }

    func setLastWidgetReloadAt(_ date: Date) {
        appGroupDefaults?.set(date.timeIntervalSince1970, forKey: Self.lastWidgetReloadAtKey)
    }

    // MARK: - Phase 3.2 Canonical Comparator

    // Phase 3.2 — canonical comparator. Use shouldUpdate everywhere.
    // Field set matches ComplicationSnapshotFingerprint (Phase 3.0):
    // glucose, trend, delta, state.
    //
    // glucoseColor excluded: depends on user settings (low/high thresholds,
    // glucoseColorScheme, glucose target) — not purely computed from glucose.
    // Safe to exclude because glucoseColor is stable within a single watch state
    // update cycle; the ±1s window only deduplicates the same CGM reading arriving
    // via two paths (userInfo + message). A settings change triggers a new cycle
    // with a new readingDate, which always passes the >1s check.
    // Must stay excluded from BOTH here and ComplicationSnapshotFingerprint to
    // preserve the invariant: pre-dispatch never suppresses a payload saveOnMain
    // would accept.
    //
    // 1s tolerance is semantic policy: two readings within 1s with identical
    // display data are treated as duplicates. Safe for all supported CGMs (minimum
    // interval: 1 min for Libre 3, 5 min for G6/G7).
    //
    // Test cases:
    //   Same timestamp, same content     → false
    //   Same timestamp, different glucose → true
    //   Newer timestamp (>1s)            → true
    //   Older timestamp (<-1s)           → false
    //   Within ±1s, same glucose+trend, higher-priority source → true (MOD-D synthesis)
    //   Within ±1s, same g7Sequence (regardless of display fields), lower-priority source → false
    //   Within ±1s, barer payload (empty trend / "--" delta) vs complete    → keep the complete one
    //   Within ±1s, equal completeness, lower-priority source               → false (higher wins)
    func shouldUpdate(new: TrioComplicationSnapshot, current: TrioComplicationSnapshot) -> Bool {
        let timeDiff = new.readingDate.timeIntervalSince(current.readingDate)
        if timeDiff > 1.0  { return true }
        if timeDiff < -1.0 { return false }
        // Sequence-equality guard for the BLE/phone race. When both snapshots carry a G7 sequence
        // and the values match, they are the *same* sensor reading even if their derived display
        // fields disagree (trend mapping in particular can differ across channels — direct BLE
        // uses the 5-min trend rate, phone uses its own delta-window logic, and they can land on
        // different `hkTrendString` buckets for the same underlying reading). Without this check
        // the fallthrough OR below treats trend/delta inequality as "different reading" and lets
        // a lower-priority channel (e.g. `.watchConnectivity`, priority 2) overwrite a higher-
        // priority one (`.g7DirectBLE`, priority 3) that already saved this sequence.
        if let newSeq = new.sequence, let curSeq = current.sequence, newSeq == curSeq {
            let newP = Self.sourcePriority(new.source)
            let curP = Self.sourcePriority(current.source)
            if newP > curP { return true }
            if newP < curP { return false }
            // Equal priority + same sequence + within ±1s → same reading from the same channel,
            // no-op even if display fields differ (shouldn't happen in practice but defensive).
            return false
        }
        // C-210-2 (scan #2): within the +/-1s window the two snapshots are the SAME CGM reading
        // arriving via different channels (distinct readings are >= 1 min apart for every supported
        // CGM). Decide by completeness, then source priority - recency is already a tie. This stops
        // a barer payload (empty trend / "--" delta) from overwriting a more complete one, and stops
        // a lower-priority channel from overwriting a higher-priority one for the same reading.
        let newP = Self.sourcePriority(new.source)
        let curP = Self.sourcePriority(current.source)
        let newComplete = Self.isComplete(new)
        let curComplete = Self.isComplete(current)
        // 1) Completeness wins (prefer the populated representation).
        if newComplete != curComplete { return newComplete }
        // 2) Equal completeness -> higher-priority source wins (direct BLE > WC > HealthKit).
        if newP != curP { return newP > curP }
        // 3) Equal completeness and priority -> same representation; accept only on a real change.
        return new.glucose != current.glucose
            || new.trend   != current.trend
            || new.delta   != current.delta
            || new.state   != current.state
            || new.source  != current.source
    }

    /// Tie-break when two channels race within the ±1s dedup window (direct BLE preferred).
    /// Delegates to `TrioComplicationDataSource.priority` so the same ordering is used by the
    /// live UI attribution path in `WatchState.tryAttributeDisplayedReadingSource`.
    private static func sourcePriority(_ source: TrioComplicationDataSource?) -> Int {
        source?.priority ?? 0
    }

    /// A snapshot is "complete" when it carries real (non-fallback) display fields. Used by
    /// `shouldUpdate` so a barer payload never clobbers a populated one within the dedup window.
    /// Fallbacks: glucose/delta sanitize to "--", trend trims to "" (see TrioComplicationSnapshot).
    private static func isComplete(_ s: TrioComplicationSnapshot) -> Bool {
        s.glucose != "--" && !s.trend.isEmpty && s.delta != "--"
    }

    // MARK: - Phase 3.0 Pre-dispatch Dedup

    private func storedFingerprint(defaults: UserDefaults) -> ComplicationSnapshotFingerprint? {
        guard let data = defaults.data(forKey: Self.fingerprintKey),
              let fp = try? JSONDecoder().decode(ComplicationSnapshotFingerprint.self, from: data)
        else { return nil }
        return fp
    }

    /// Phase 3.0 — pre-dispatch dedup. Decision-only (no save inside).
    /// Returns true if the snapshot is a duplicate of the last saved fingerprint and should be skipped.
    /// Cold-start (no stored fingerprint): always returns false (dispatch).
    func shouldSkipPreDispatch(for snapshot: TrioComplicationSnapshot, handler: String) -> Bool {
        let incoming = ComplicationSnapshotFingerprint(from: snapshot)
        var skip = false
        var messageToLog: String?

        dedupQueue.sync {
            guard let defaults = appGroupDefaults else { return }
            if let stored = storedFingerprint(defaults: defaults), stored == incoming {
                messageToLog = "⏭️ Pre-dispatch dedup: skipped reading_date_epoch=\(incoming.readingDateEpoch)" + " via \(handler)"
                skip = true
                return
            }
            messageToLog = "✅ Pre-dispatch: dispatching reading_date_epoch=\(incoming.readingDateEpoch)" + " via \(handler)"
        }

        if let message = messageToLog {
            log(message)
        }
        return skip
    }

    // MARK: - Save Methods

    // C-209-8 (6.11): the source-less convenience `save(glucose:trend:...)` was deleted — it
    // had zero callers and built `source: nil` (priority 0) snapshots that lose every ±1s
    // arbitration. Construct a TrioComplicationSnapshot with an explicit `source` instead.

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

        // saveOnMain invariants (Phase 3.1):
        // (a) future-skew  (b) cold-start  (c) newer-wins  (d) duplicate skip
        // Authoritative dedup gate. Phase 3.0 pre-dispatch is optimization only.
        if let existing = inMemorySavedSnapshot {
            if !shouldUpdate(new: snapshot, current: existing) {
                let timeDiff = snapshot.readingDate.timeIntervalSince(existing.readingDate)
                if timeDiff < -1.0 {
                    log("⏭️ saveOnMain: rejected older snapshot (timeDiff=\(String(format: "%.3f", timeDiff))s)")
                } else {
                    log("⏭️ saveOnMain: duplicate skipped (same reading, same content)")
                }
                return
            }
        } else if let lastTS = Self.lastValidTimestamp {
            // Monotonic write guard (Bug #5): authoritative monotonic check lives on the write
            // path. `<` is a genuine backward-in-time write — log it. `==` is a normal duplicate
            // (same reading seen twice) and is silenced so it doesn't masquerade as an anomaly
            // in telemetry / log streams. The read path (`latestSnapshot`) no longer logs this.
            if snapshot.readingDate < lastTS {
                log("⏭️ lastValidTimestamp: skipped non-monotonic write (\(snapshot.readingDate) < \(lastTS))")
                return
            } else if snapshot.readingDate == lastTS {
                // C-209-8 (5.10): same timestamp is only a duplicate if the CONTENT matches —
                // the primary shouldUpdate path accepts same-ts-different-glucose (corrected
                // readings); this rare fallback (failed seed) now agrees. The disk read happens
                // only on the cold-start-equal-timestamp path.
                if let existing = latestSnapshot(), shouldUpdate(new: snapshot, current: existing) {
                    inMemorySavedSnapshot = existing
                } else {
                    return
                }
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

            // C-209-8 (6.10): .bak refresh every 10th save — the per-save remove+copy was two
            // extra file ops per reading guarding a corruption mode the atomic write already
            // mostly prevents. Counter starts ≥10 so the first save of each process refreshes.
            savesSinceBackup += 1
            let backupURL = containerDir.appendingPathComponent("snapshot.bak")
            if savesSinceBackup >= 10, fileManager.fileExists(atPath: fileURL.path) {
                _ = try? fileManager.removeItem(at: backupURL)
                _ = try? fileManager.copyItem(at: fileURL, to: backupURL)
                savesSinceBackup = 0
            }

            try data.write(to: fileURL, options: [.atomic])
            self.inMemorySavedSnapshot = snapshot
            Self.lastValidTimestamp = snapshot.readingDate
            log("✅ lastValidTimestamp updated: \(snapshot.readingDate)")

            // Phase 3.0: fingerprint written here and ONLY here.
            // Not written in didReceiveUserInfo or didReceiveMessage.
            if let fpData = try? JSONEncoder().encode(ComplicationSnapshotFingerprint(from: snapshot)) {
                appGroupDefaults?.set(fpData, forKey: Self.fingerprintKey)
                log(
                    "✅ Fingerprint written: reading_date_epoch="
                    + "\(Int(snapshot.readingDate.timeIntervalSince1970))"
                )
            }

            let ageSec = max(0, Int(Date().timeIntervalSince(snapshot.readingDate)))

            log("✅ Snapshot saved: glucose=\(snapshot.glucose), trend=\(snapshot.trend), delta=\(snapshot.delta), snapshot_age_seconds=\(ageSec)")
            log("event=complication_save_age age_seconds=\(ageSec) reading_date_epoch_seconds=\(Int(snapshot.readingDate.timeIntervalSince1970)) reading_date=\(Self.iso8601Formatter.string(from: snapshot.readingDate))")

            #if os(watchOS)
            if WCSession.isSupported(), WCSession.default.activationState == .activated {
                do {
                    try WCSession.default.updateApplicationContext([
                        "complicationLastValidTimestamp": snapshot.readingDate.timeIntervalSince1970
                    ])
                    log("event=complication_age_report_sent epoch=\(Int(snapshot.readingDate.timeIntervalSince1970))")
                } catch {
                    log("⚠️ complication_age_report_failed error=\(error.localizedDescription)")
                }
            } else if WCSession.isSupported() {
                log("event=complication_age_report_skipped activation_state=\(WCSession.default.activationState.rawValue)")
            }
            #endif

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

    /// C-209-7 (review 5.9): widget-side write at getTimeline — records the generation the
    /// provider actually serviced, so the app can detect dropped reloads.
    func recordWidgetObservedGeneration(_ generation: Int) {
        appGroupDefaults?.set(generation, forKey: Self.widgetObservedGenerationKey)
    }

    /// C-209-7: app-side read of the widget's last serviced generation.
    func widgetObservedGeneration() -> Int? {
        guard let defaults = appGroupDefaults else { return nil }
        return defaults.object(forKey: Self.widgetObservedGenerationKey) != nil
            ? defaults.integer(forKey: Self.widgetObservedGenerationKey)
            : nil
    }

    func isAppGroupAvailable() -> Bool {
        appGroupDefaults != nil
    }

    /// Loads the latest complication snapshot from disk.
    ///
    /// May be called from any thread.
    ///
    /// **Invariant (Bug #5):** the monotonic write guard lives on `saveOnMain`, **not** here.
    /// This read path no longer logs `lastValidTimestamp: skipped non-monotonic write` — that
    /// message previously fired on every poll of an unchanged snapshot (e.g., the 1Hz debug-view
    /// task) and on every legitimate dedup, masquerading as an anomaly. The only timestamp
    /// side-effect retained here is **cold-start hydration** when `lastValidTimestamp` has not
    /// yet been seeded in this process / App Group; that path is silent unless it actually fires.
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
            if Self.lastValidTimestamp == nil {
                // C-209-8 (6.9): always hop to main — the old direct-write branch (taken in the
                // common appGroupDefaults-present case) raced saveOnMain's main-thread writes;
                // the onMain wrap was on the wrong branch. Re-check nil inside the hop so a
                // save that lands first isn't overwritten by stale disk state.
                onMain {
                    if Self.lastValidTimestamp == nil {
                        Self.lastValidTimestamp = readingDate
                        self.log("✅ lastValidTimestamp hydrated from disk (main): \(readingDate)")
                    }
                }
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

        burstWindowId += 1
        reloadSuppressionCount = 0
        let elapsedStr = String(format: "%.3f", elapsed)
        log("🔄 Reload TRIGGERED burst_window_id=\(burstWindowId) suppressed=\(reloadSuppressionCount) elapsed=\(elapsedStr)s since last reload\(isRetry ? " (retry)" : "")")
        lastReload = now
        reloadTimeline()

        guard scheduleRetry else {
            log("⏭️ Retry skipped: scheduleRetry=false (save path)")
            return
        }
        if !isRetry {
            let freshnessThreshold: TimeInterval = 60
            // C-209-8 (6.10): use the in-memory snapshot — this was a disk read + JSON decode
            // on the main thread per reload, just to decide retry-skip.
            let freshDate = inMemorySavedSnapshot?.readingDate ?? Self.lastValidTimestamp
            if let freshDate, Date().timeIntervalSince(freshDate) < freshnessThreshold {
                let age = String(format: "%.1f", Date().timeIntervalSince(freshDate))
                log("⏭️ Retry skipped: snapshot fresh (age=\(age)s < \(Int(freshnessThreshold))s)")
                return
            }
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
            // C-209-7 (review 5.9): a reload WidgetKit drops on budget grounds was previously
            // invisible and never re-asked (save-path reloads skip retries; fresh snapshots skip
            // the coalesced retry). Check the widget's serviced generation after a grace period
            // and re-request once, rate-limited.
            scheduleUnservicedReloadCheck(generation: reloadGeneration)
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

        /// C-209-7 (review 5.9): re-request once if the widget hasn't serviced `generation`
        /// within `unservicedCheckDelay`. Each new reload supersedes the pending check, so the
        /// check always covers the most recent generation. Rate-limited so a true WidgetKit
        /// budget blackout (or an empty watch face) costs at most one extra request per
        /// `unservicedRetryMinInterval`.
        private func scheduleUnservicedReloadCheck(generation: Int) {
            guard generation > 0 else { return } // -1/0 = no app-group defaults; nothing to compare
            unservicedCheckWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.unservicedCheckWorkItem = nil
                let observed = self.widgetObservedGeneration() ?? -1
                guard observed < generation else { return } // serviced — the common, silent case
                guard Date().timeIntervalSince(self.lastUnservicedRetryAt) >= Self.unservicedRetryMinInterval else {
                    self.log("event=complication_reload_unserviced generation=\(generation) observed=\(observed) action=rate_limited")
                    return
                }
                self.lastUnservicedRetryAt = Date()
                self.log("event=complication_reload_unserviced generation=\(generation) observed=\(observed) action=re_request")
                self.forceReloadOnMain(scheduleRetry: false)
            }
            unservicedCheckWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.unservicedCheckDelay, execute: work)
        }
    #endif

    #if !WIDGET_EXTENSION
    /// C-210-9 (scan #3): launch/resume reconciliation. The in-memory unserviced-reload timer
    /// (`scheduleUnservicedReloadCheck`) dies if the app is suspended before its grace period fires,
    /// so an unserviced reload could otherwise never recover. Both generations are persisted in the
    /// App Group, so compare them on launch/foreground and re-request once (rate-limited) when the
    /// widget never serviced the most recent reload. Watch-app only (never the widget process).
    func reconcileUnservicedReloadOnLaunch() {
        guard let defaults = appGroupDefaults else { return }
        let requested = defaults.integer(forKey: Self.reloadGenerationKey)
        guard requested > 0 else { return }
        let observed = widgetObservedGeneration() ?? -1
        guard observed < requested else { return } // serviced — the common case
        guard Date().timeIntervalSince(lastUnservicedRetryAt) >= Self.unservicedRetryMinInterval else {
            log("event=complication_reload_unserviced_launch requested=\(requested) observed=\(observed) action=rate_limited")
            return
        }
        lastUnservicedRetryAt = Date()
        log("event=complication_reload_unserviced_launch requested=\(requested) observed=\(observed) action=re_request")
        forceReload(scheduleRetry: false)
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
        mostRecentReloadId: String,
        getTimelineAtEpochSeconds: Int,
        dataAgeSeconds: Int
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
            + " get_timeline_at_epoch_seconds=\(getTimelineAtEpochSeconds)"
            + " data_age_seconds=\(dataAgeSeconds)"
        )
    }

    /// R5f — Snapshot path visible-recency observability.
    func logWidgetGetSnapshotInvocation(getSnapshotAtEpochSeconds: Int, dataAgeSeconds: Int) {
        log(
            "event=complication_get_snapshot_called"
            + " get_snapshot_at_epoch_seconds=\(getSnapshotAtEpochSeconds)"
            + " data_age_seconds=\(dataAgeSeconds)"
        )
    }
#endif

    private func log(_ message: String) {
        ComplicationLogBuffer.append(message)
        let forwarder = Self.logForwarderLock.withLock { $0.forwarder }
        forwarder?(message)
    }
}
