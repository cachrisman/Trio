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
    /// C-217 V-2b: compact recent readings for the accessoryRectangular sparkline — [epochSeconds, mgDl]
    /// pairs, last ~2h (<=24 points), oldest-first. Optional for clean Codable evolution (older widget
    /// reading a newer snapshot ignores it; newer widget reading an older snapshot decodes nil →
    /// text-only fallback). `var` so the store can enrich it on save. Deliberately excluded from
    /// ComplicationSnapshotFingerprint, so it never affects dedup.
    var recentReadings: [[Int]]?
    /// fork — the reading's chart/scheme colour (same math as the phone's getDynamicGlucoseColor,
    /// coloured in range too), as opposed to `glucoseColor` which is the white-in-range bubble
    /// colour. Optional for clean Codable evolution, same reasoning as `recentReadings`.
    /// Deliberately excluded from ComplicationSnapshotFingerprint, so it never affects dedup.
    /// Used by the circular Glucose Bobble complication.
    var chartGlucoseColor: String?

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
        sequence: Int? = nil,
        recentReadings: [[Int]]? = nil,
        // fork — the chart/scheme colour, distinct from `glucoseColor` (the bubble colour).
        chartGlucoseColor: String? = nil
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
        self.recentReadings = recentReadings
        self.chartGlucoseColor = chartGlucoseColor
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
            // F-3a (fable5 finding 1.10): mmol/L-range values (< 40, plausible mmol ceiling)
            // always keep one decimal, including whole numbers — integer rounding previously
            // turned "5.6" into "6" and collapsed "5.0" to "5", losing the mmol/mg-dL visual
            // distinction. mg/dL values (>= 40 by CGM display floor) keep integer rounding.
            if doubleValue < 40 {
                return String(format: "%.1f", doubleValue)
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
    /// Must match the kind declared in GlucoseBobbleComplication.swift; repeated here because this file is also compiled into targets that cannot see that type.
    static let glucoseBobbleComplicationKind = "TrioGlucoseBobbleComplication"
    /// Every complication kind this app ships; `reloadTimeline()` reloads all of them together.
    static let allComplicationKinds = [complicationKind, glucoseBobbleComplicationKind]

    /// C-217 V-2b: set once by the watch extension (ExtensionDelegate) to supply the rolling 2h
    /// sparkline series from the extension-local WatchGlucoseHistoryStore, which the Shared target
    /// cannot import directly. nil in the widget process (which only reads snapshots, never saves).
    var recentReadingsProvider: (() -> [[Int]]?)?

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
    /// TRIO-120: per-kind observed generation (suffix = kind). The legacy key above is still
    /// written by every provider run, so anything reading it keeps working.
    private static let widgetObservedGenerationKeyPrefix = "TrioComplication_widgetObservedReloadGeneration."
    /// TRIO-120: content key of each kind as of the last `reloadTimeline()` request (suffix = kind),
    /// and the reading epoch of the snapshot at that request.
    private static let lastRequestedContentKeyPrefix = "TrioComplication_lastRequestedContentKey."
    private static let lastRequestedReadingEpochKey = "TrioComplication_lastRequestedReadingEpoch"
    /// TRIO-120: per-kind provider-run telemetry written by the complication extension (suffix = kind).
    private static let lastProviderRunAtKeyPrefix = "TrioComplication_lastProviderRunAt."
    private static let lastProviderRunReadingKeyPrefix = "TrioComplication_lastProviderRunReadingEpoch."
    private static let lastProviderRunNewerKeyPrefix = "TrioComplication_lastProviderRunNewerReading."
    /// TRIO-126: content key of the snapshot each kind's provider last rendered (suffix = kind). Unlike
    /// the requested key, a dropped or deferred reload never advances it.
    private static let lastProviderRunContentKeyPrefix = "TrioComplication_lastProviderRunContentKey."
    /// TRIO-126: when the watch app was last opened (epoch seconds), and per kind the open the provider
    /// already logged its open-to-run latency for. Written by the app, read by the provider process.
    private static let lastOpenAtKey = "TrioComplication_lastOpenAtEpoch"
    private static let openLatencyLoggedKeyPrefix = "TrioComplication_openLatencyLoggedForOpen."
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

    /// TRIO-118: trailing reload after a debounced save. Main-thread confined. At most one is
    /// pending; `trailingReloadID` is the generation token that makes stale firings no-ops.
    private var pendingTrailingWorkItem: DispatchWorkItem?
    private var trailingReloadID: UUID?
    private static let trailingReloadMargin: TimeInterval = 0.5

    /// Reading date of the newest snapshot this process saved (nil until the first save).
    private var newestSavedReadingDate: Date?
    /// Reading date of the newest saved snapshot at the moment the last reload fired. A reload
    /// covers the newest stored reading only when this is >= `newestSavedReadingDate`.
    private var lastReloadCoveredReadingDate: Date?

    // Test seams (internal, default to production behaviour).
    /// Clock used for debounce decisions and trailing-reload delays.
    var nowProvider: () -> Date = { Date() }
    /// Delayed-work scheduler for the trailing reload (delay in seconds, work item to run on main).
    var scheduleDelayedWork: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    /// When set, replaces `reloadTimeline()` (no WidgetKit in tests).
    var reloadSink: (() -> Void)?
    /// When set, replaces the single-kind WidgetKit reload used by `reloadGlucoseBobbleKind` (no WidgetKit in tests).
    var kindReloadSink: ((String) -> Void)?
    /// TRIO-120: learns which complication kinds are on a watch face. Default asks
    /// `WidgetCenter.getCurrentConfigurations`; nil means unknown. Tests inject a stub.
    var installedKindsSource: (@escaping (Set<String>?) -> Void) -> Void = TrioComplicationDataStore.widgetCenterInstalledKinds
    /// TRIO-120: the snapshot the content keys are computed from. nil uses the newest saved snapshot
    /// (memory, then disk). Tests inject one to change a field the save path's dedup would swallow.
    var gateSnapshotOverride: (() -> TrioComplicationSnapshot?)?
    /// TRIO-120: Bobble inputs that live outside the snapshot. The settings type is not visible to every
    /// target this file is compiled into, so WatchState supplies its canonical string.
    var bobbleSettingsKeyProvider: () -> String = { "" }
    /// The iOS app target compiles this file without `GlucoseComplicationSnapshot.swift`; the phone
    /// never reloads watch complications, so the Bobble inputs exist only off iOS.
    #if os(iOS)
    var bobbleLastLoopDateProvider: () -> Date? = { nil }
    #else
    var bobbleLastLoopDateProvider: () -> Date? = { GlucoseComplicationSnapshot.storedLastLoopDate() }
    #endif

    /// TRIO-120: cached result of the last `refreshInstalledKinds()`; nil until known. Main-thread confined.
    private var cachedInstalledKinds: Set<String>?
    /// TRIO-120: in-memory mirrors of the persisted last-request state (app-group defaults may be nil).
    private var inMemoryRequestedContentKeys: [String: String] = [:]
    private var inMemoryRequestedReadingEpoch: Int?
    /// TRIO-120: who asked for the reload in flight and why it went ahead; read by the request log line.
    private var currentRequestCaller = "unspecified"
    private var currentRequestReason = "bypass"

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

    /// TRIO-126: one foreground session = one open request and at most one close request. Main-thread
    /// confined; the scene-phase and `ExtensionDelegate` paths both call in, so the flags make it idempotent.
    private var openSessionActive = false
    /// When this session's open requested a reload; nil when the open found every kind current.
    private var openRequestedAt: Date?
    /// Kinds this session's open check has evaluated (or requested), so the installed-kinds refresh
    /// that arrives later evaluates each remaining kind once. Reset by every open.
    private var openEvaluatedKinds: Set<String> = []
    private var openRequestedKinds: Set<String> = []
    private var openSessionToken = UUID()
    /// Counts reload requests issued by this process; lets a caller tell whether one happened meanwhile.
    private var reloadRequestSequence = 0

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

    // MARK: - Debug Properties (for WatchDiagnosticsView)

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

    // MARK: - Debug Properties for WatchDiagnosticsView

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
        snapshotFilename: String = "snapshot.json",
        appGroupDefaultsProvider: () -> UserDefaults? = TrioComplicationDataStore.resolveAppGroupDefaultsOnce
    ) {
        self.sharedContainerURLProvider = sharedContainerURLProvider
        self.fileManager = fileManager
        self.snapshotFilename = snapshotFilename

        // Resolve appGroupDefaults once at init (avoids repeated bundle/logging overhead per access).
        self.cachedAppGroupDefaults = appGroupDefaultsProvider()

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
        var snapshot = snapshot
        // C-217 V-2b: enrich with the rolling 2h sparkline series (widget can't read the history
        // store; the snapshot is the bridge). Provider is nil in the widget process. Not part of the
        // dedup fingerprint, so this never forces extra reloads.
        if snapshot.recentReadings == nil, let provider = recentReadingsProvider {
            snapshot.recentReadings = provider()
        }
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
            newestSavedReadingDate = snapshot.readingDate
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
                coalescedReloadOnMain(minInterval: minInterval, scheduleRetry: false, scheduleTrailing: true, gateCaller: "save")
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
    /// provider actually serviced, so the app can detect dropped reloads. TRIO-120: also recorded
    /// per kind; the legacy shared key is still written so existing readers keep working.
    func recordWidgetObservedGeneration(_ generation: Int, kind: String) {
        appGroupDefaults?.set(generation, forKey: Self.widgetObservedGenerationKey)
        appGroupDefaults?.set(generation, forKey: Self.widgetObservedGenerationKeyPrefix + kind)
    }

    /// TRIO-120: app-side read of the generation one kind last serviced.
    func widgetObservedGeneration(kind: String) -> Int? {
        guard let defaults = appGroupDefaults else { return nil }
        let key = Self.widgetObservedGenerationKeyPrefix + kind
        return defaults.object(forKey: key) != nil ? defaults.integer(forKey: key) : nil
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

    // MARK: - TRIO-120 Per-kind servicing, content keys and the reload gate

    /// `getCurrentConfigurations` result for the kinds this app ships; nil when unknown.
    private static func widgetCenterInstalledKinds(_ completion: @escaping (Set<String>?) -> Void) {
        if #available(watchOS 9.0, *) {
            WidgetCenter.shared.getCurrentConfigurations { result in
                switch result {
                case let .success(infos): completion(Set(infos.map(\.kind)))
                case .failure: completion(nil)
                }
            }
        } else {
            completion(nil)
        }
    }

    /// Refreshes the cached set of installed kinds. Called at launch, on foreground and when the
    /// unserviced check runs. The completion may arrive on any thread; the cache is set on main.
    /// When the installed set changed (including unknown or empty to known), the servicing of the
    /// last requested generation is re-evaluated: an earlier evaluation against the old or nil
    /// cache may have fallen back to the any-kind rule and wrongly counted it serviced.
    /// `completion` runs on main once the cache is set and any servicing re-evaluation is done; its
    /// argument says whether that evaluation requested a reload.
    func refreshInstalledKinds(completion: ((_ reloadRequested: Bool) -> Void)? = nil) {
        installedKindsSource { [weak self] kinds in
            self?.onMain {
                guard let self else { return }
                let old = self.cachedInstalledKinds
                self.cachedInstalledKinds = kinds
                let requestsBefore = self.reloadRequestSequence
                if old != kinds {
                    #if canImport(WidgetKit)
                    if let requested = self.appGroupDefaults?.integer(forKey: Self.reloadGenerationKey), requested > 0 {
                        self.evaluateUnservicedOnMain(generation: requested, trigger: "installed_kinds_changed")
                    }
                    #endif
                }
                completion?(self.reloadRequestSequence != requestsBefore)
            }
        }
    }

    /// Installed kinds among the ones this app ships; nil when unknown or empty.
    private func installedKnownKinds() -> [String]? {
        guard let installed = cachedInstalledKinds else { return nil }
        let known = Self.allComplicationKinds.filter(installed.contains)
        return known.isEmpty ? nil : known
    }

    /// True while this session's open request is younger than the unserviced grace period. The 120 s
    /// check owns its recovery; the launch reconcile and the installed-kinds re-evaluation (which run
    /// right after the open) must not re-request it at once.
    private func openRequestIsPending() -> Bool {
        guard let requestedAt = openRequestedAt else { return false }
        return nowProvider().timeIntervalSince(requestedAt) < Self.unservicedCheckDelay
    }

    /// True when `generation` has been serviced: every installed kind has observed it. With the
    /// installed set unknown or empty it falls back to the legacy rule (any kind observing counts).
    func isGenerationServiced(_ generation: Int) -> Bool {
        if let kinds = installedKnownKinds() {
            return kinds.allSatisfy { (widgetObservedGeneration(kind: $0) ?? -1) >= generation }
        }
        return (widgetObservedGeneration() ?? -1) >= generation
    }

    private func perKindObservedSummary() -> String {
        Self.allComplicationKinds
            .map { "\($0)=\(widgetObservedGeneration(kind: $0).map(String.init) ?? "nil")" }
            .joined(separator: ",")
    }

    /// Canonical content key of the main complication: every field any of its families displays.
    /// The source counts only as the BLE marker the face prints. IOB/COB are not displayed.
    static func mainContentKey(for snapshot: TrioComplicationSnapshot?) -> String {
        guard let s = snapshot else { return "main|none" }
        let readings = (s.recentReadings ?? [])
            .map { $0.map(String.init).joined(separator: ":") }
            .joined(separator: ",")
        return [
            "main",
            "g=\(s.glucose)",
            "t=\(s.trend)",
            "d=\(s.delta)",
            "rd=\(Int(s.readingDate.timeIntervalSince1970))",
            "st=\(s.state ?? "<nil>")",
            "c=\(s.glucoseColor ?? "<nil>")",
            "ble=\(s.source == .g7DirectBLE)",
            "rr=\(readings)"
        ].joined(separator: "|")
    }

    #if !os(iOS)
    /// The Bobble key of the snapshot its provider rendered (`nil` when it rendered the empty state).
    /// Same format as `bobbleContentKey(for:lastLoopDate:settingsKey:)`.
    static func bobbleRenderedContentKey(_ rendered: GlucoseComplicationSnapshot?, settingsKey: String) -> String {
        rendered?.contentKey(settingsKey: settingsKey) ?? "bobble|none|s=\(settingsKey)"
    }
    #endif

    /// Canonical content key of the Glucose Bobble: what `GlucoseComplicationSnapshot.load()` hands
    /// it (including the chart colour), the last loop date and the Bobble settings.
    static func bobbleContentKey(
        for snapshot: TrioComplicationSnapshot?,
        lastLoopDate: Date?,
        settingsKey: String
    ) -> String {
        #if os(iOS)
        return "bobble|none|s=\(settingsKey)"
        #else
        guard let bobble = snapshot.flatMap({ GlucoseComplicationSnapshot.make(from: $0, lastLoopDate: lastLoopDate) }) else {
            return "bobble|none|s=\(settingsKey)"
        }
        return bobble.contentKey(settingsKey: settingsKey)
        #endif
    }

    func contentKey(forKind kind: String, snapshot: TrioComplicationSnapshot?) -> String {
        if kind == Self.glucoseBobbleComplicationKind {
            return Self.bobbleContentKey(
                for: snapshot,
                lastLoopDate: bobbleLastLoopDateProvider(),
                settingsKey: bobbleSettingsKeyProvider()
            )
        }
        return Self.mainContentKey(for: snapshot)
    }

    private func gateSnapshotOnMain() -> TrioComplicationSnapshot? {
        if let gateSnapshotOverride { return gateSnapshotOverride() }
        return inMemorySavedSnapshot ?? latestSnapshot()
    }

    private func lastRequestedContentKey(_ kind: String) -> String? {
        inMemoryRequestedContentKeys[kind]
            ?? appGroupDefaults?.string(forKey: Self.lastRequestedContentKeyPrefix + kind)
    }

    private func lastRequestedReadingEpoch() -> Int? {
        if let inMemoryRequestedReadingEpoch { return inMemoryRequestedReadingEpoch }
        guard let defaults = appGroupDefaults, defaults.object(forKey: Self.lastRequestedReadingEpochKey) != nil else {
            return nil
        }
        return defaults.integer(forKey: Self.lastRequestedReadingEpochKey)
    }

    /// Remembers what every kind showed as of this reload request. Runs for gated and bypassing
    /// requests alike, so a bypassing reload never leaves a stale key behind.
    private func recordRequestedContentOnMain() {
        let snapshot = gateSnapshotOnMain()
        for kind in Self.allComplicationKinds {
            let key = contentKey(forKind: kind, snapshot: snapshot)
            inMemoryRequestedContentKeys[kind] = key
            appGroupDefaults?.set(key, forKey: Self.lastRequestedContentKeyPrefix + kind)
        }
        let epoch = snapshot.map { Int($0.readingDate.timeIntervalSince1970) }
        inMemoryRequestedReadingEpoch = epoch
        if let epoch {
            appGroupDefaults?.set(epoch, forKey: Self.lastRequestedReadingEpochKey)
        } else {
            appGroupDefaults?.removeObject(forKey: Self.lastRequestedReadingEpochKey)
        }
    }

    private func lastRequestIsUnserviced() -> Bool {
        guard let defaults = appGroupDefaults else { return false }
        let requested = defaults.integer(forKey: Self.reloadGenerationKey)
        return requested > 0 && !isGenerationServiced(requested)
    }

    private struct ReloadGateDecision {
        let proceed: Bool
        let reason: String
    }

    /// Decides a gated reload request. `requireNewerEpoch` is the sleep-gap rule: content changes
    /// alone do not count, only a newer reading epoch than the last request, or an unserviced request.
    private func evaluateReloadGateOnMain(caller: String, requireNewerEpoch: Bool = false) -> ReloadGateDecision {
        let snapshot = gateSnapshotOnMain()
        let unserviced = lastRequestIsUnserviced()
        let currentEpoch = snapshot.map { Int($0.readingDate.timeIntervalSince1970) }
        let requestedEpoch = lastRequestedReadingEpoch()

        var changedKinds: [String] = []
        let decision: ReloadGateDecision
        if unserviced, !openRequestIsPending() { // TRIO-126: the open's own 120 s recheck covers its reload
            decision = ReloadGateDecision(proceed: true, reason: "unserviced")
        } else if requireNewerEpoch {
            if let currentEpoch, requestedEpoch.map({ currentEpoch > $0 }) ?? true {
                decision = ReloadGateDecision(proceed: true, reason: "newer_epoch")
            } else {
                decision = ReloadGateDecision(proceed: false, reason: "no_newer_epoch")
            }
        } else {
            // Unknown or empty installed set: compare every shipped kind (more reloads, never fewer).
            let kinds = installedKnownKinds() ?? Self.allComplicationKinds
            changedKinds = kinds.filter { contentKey(forKind: $0, snapshot: snapshot) != lastRequestedContentKey($0) }
            if !changedKinds.isEmpty {
                decision = ReloadGateDecision(proceed: true, reason: "content_changed")
            } else {
                let sinceLast = nowProvider().timeIntervalSince(lastReload)
                decision = ReloadGateDecision(proceed: false, reason: sinceLast < 30 ? "already_requested" : "no_new_content")
            }
        }

        if !decision.proceed {
            let sinceLast = nowProvider().timeIntervalSince(lastReload)
            let sinceLastStr = lastReload == .distantPast ? "never" : "\(Int(sinceLast))"
            log(
                "event=complication_reload_skipped reason=\(decision.reason) caller=\(caller)"
                    + " last_request_age_s=\(sinceLastStr)"
                    + " reading_epoch=\(currentEpoch.map(String.init) ?? "nil")"
                    + " last_requested_epoch=\(requestedEpoch.map(String.init) ?? "nil")"
                    + " unserviced=\(unserviced)"
            )
        } else {
            currentRequestReason = changedKinds.isEmpty ? decision.reason : "\(decision.reason):\(changedKinds.joined(separator: "+"))"
        }
        return decision
    }

    /// `forceComplicationUpdate`: saves the snapshot (no reload of its own), then reloads only when
    /// what the face shows changed since the last request, or the last request is unserviced.
    func forceComplicationReload(_ snapshot: TrioComplicationSnapshot, caller: String = "force_update") {
        onMain { [self] in
            saveOnMain(snapshot, triggerReload: false)
            guard evaluateReloadGateOnMain(caller: caller).proceed else { return }
            forceReloadOnMain(scheduleRetry: false, caller: caller, reason: currentRequestReason)
        }
    }

    /// Sleep-gap reload: goes ahead only when the store holds a newer reading epoch than the last
    /// request, or the last request is unserviced. `onFired` runs just before the reload.
    func requestSleepGapReload(caller: String = "sleep_gap", onFired: @escaping () -> Void = {}) {
        onMain { [self] in
            guard evaluateReloadGateOnMain(caller: caller, requireNewerEpoch: true).proceed else { return }
            onFired()
            forceReloadOnMain(scheduleRetry: false, caller: caller, reason: currentRequestReason)
        }
    }

    // MARK: - TRIO-126 Open and close refresh

    private static let kindLabels = [complicationKind: "main", glucoseBobbleComplicationKind: "bobble"]

    private func lastProviderRunReadingEpoch(_ kind: String) -> Int? {
        appGroupDefaults?.object(forKey: Self.lastProviderRunReadingKeyPrefix + kind) as? Int
    }

    private func lastProviderRunContentKey(_ kind: String) -> String? {
        appGroupDefaults?.string(forKey: Self.lastProviderRunContentKeyPrefix + kind)
    }

    /// True when the kind's last provider run rendered an older reading or other content than
    /// `snapshot` holds. A kind with no recorded run counts as behind.
    private func kindIsBehind(_ kind: String, snapshot: TrioComplicationSnapshot?) -> (behind: Bool, renderedEpoch: Int?) {
        let rendered = lastProviderRunReadingEpoch(kind)
        let storeEpoch = snapshot.map { Int($0.readingDate.timeIntervalSince1970) }
        let olderReading = storeEpoch.map { store in rendered.map { $0 < store } ?? true } ?? false
        let renderedKey = lastProviderRunContentKey(kind)
        let keyChanged = renderedKey.map { $0 != contentKey(forKind: kind, snapshot: snapshot) } ?? true
        return (olderReading || keyChanged, rendered)
    }

    private func lastProviderRunAtEpoch(_ kind: String) -> Double? {
        appGroupDefaults?.object(forKey: Self.lastProviderRunAtKeyPrefix + kind) as? Double
    }

    /// The watch app became active. Saves the newest reading it holds (`snapshot`, no reload of its own),
    /// then requests a reload at once, bypassing the 5 s debounce, when an installed kind's last provider
    /// run carried an older reading than the store's newest or its content key differs from the last
    /// request. With every installed kind current it logs a skip and requests nothing. Once per
    /// foreground session; `requestCloseRefresh` ends the session.
    func requestOpenRefresh(newest snapshot: TrioComplicationSnapshot? = nil, caller: String = "open_refresh") {
        onMain { [self] in
            guard !openSessionActive else { return }
            openSessionActive = true
            openSessionToken = UUID()
            openRequestedAt = nil
            if let snapshot { saveOnMain(snapshot, triggerReload: false) }

            let now = nowProvider()
            appGroupDefaults?.set(now.timeIntervalSince1970, forKey: Self.lastOpenAtKey)

            let current = gateSnapshotOnMain()
            let storeEpoch = current.map { Int($0.readingDate.timeIntervalSince1970) }
            var behind: [String] = []
            var perKind: [String] = []
            let atOpenKinds = installedKnownKinds()
            for kind in atOpenKinds ?? Self.allComplicationKinds {
                let state = kindIsBehind(kind, snapshot: current)
                let label = Self.kindLabels[kind] ?? kind
                if state.behind { behind.append(label) }
                perKind.append("\(label)_rendered_epoch=\(state.renderedEpoch.map(String.init) ?? "nil") \(label)_key_changed=\(state.behind)")
            }
            // Kinds the open check has handled: a refreshed installed set evaluates only the others.
            openEvaluatedKinds = Set(atOpenKinds ?? [])
            openRequestedKinds = Set((atOpenKinds ?? Self.allComplicationKinds).filter { kindIsBehind($0, snapshot: current).behind })
            let action = behind.isEmpty ? "skipped" : "requested"
            log(
                "event=complication_open_refresh caller=\(caller) open_at_epoch=\(Int(now.timeIntervalSince1970))"
                    + " store_epoch=\(storeEpoch.map(String.init) ?? "nil") \(perKind.joined(separator: " "))"
                    + " action=\(action) behind=\(behind.isEmpty ? "none" : behind.joined(separator: "+"))"
            )
            if behind.isEmpty {
                log(
                    "event=complication_reload_skipped reason=all_kinds_current caller=\(caller)"
                        + " reading_epoch=\(storeEpoch.map(String.init) ?? "nil")"
                )
            } else {
                openRequestedAt = now
                // A first request: if WidgetKit services neither provider, the 120 s unserviced check
                // runs and may re-request once under its usual rules.
                forceReloadOnMain(scheduleRetry: false, caller: caller, reason: "open:\(behind.joined(separator: "+"))")
            }

            // The installed set may be stale (a Bobble added while the app was inactive) or unknown:
            // refresh it and evaluate the kinds the open check did not consider.
            let token = openSessionToken
            refreshInstalledKinds { [weak self] reloadRequested in
                self?.recheckOpenForNewlyInstalledKinds(token: token, caller: caller, reloadRequested: reloadRequested)
            }
        }
    }

    private func recheckOpenForNewlyInstalledKinds(token: UUID, caller: String, reloadRequested: Bool) {
        guard openSessionActive, openSessionToken == token else { return }
        let current = gateSnapshotOnMain()
        let fresh = (installedKnownKinds() ?? Self.allComplicationKinds).filter { !openEvaluatedKinds.contains($0) }
        guard !fresh.isEmpty else { return }
        openEvaluatedKinds.formUnion(fresh)
        // Kinds already requested at open are not requested twice; a reload this refresh just made
        // for an unserviced request covers every kind.
        let behind = fresh
            .filter { !openRequestedKinds.contains($0) && kindIsBehind($0, snapshot: current).behind }
            .map { Self.kindLabels[$0] ?? $0 }
        let evaluated = fresh.map { Self.kindLabels[$0] ?? $0 }.joined(separator: "+")
        // The open's own reload already reloaded every kind, newly discovered ones included.
        let coveredByOpen = openRequestedAt != nil
        let action = behind.isEmpty ? "skipped" : (reloadRequested || coveredByOpen ? "covered" : "requested")
        log(
            "event=complication_open_refresh caller=\(caller) trigger=installed_kinds evaluated=\(evaluated)"
                + " action=\(action) behind=\(behind.isEmpty ? "none" : behind.joined(separator: "+"))"
        )
        if coveredByOpen { openRequestedKinds.formUnion(fresh) }
        if reloadRequested, !behind.isEmpty, !coveredByOpen {
            // The refresh's own reload covered a behind new kind: the close must still be able to recheck it.
            openRequestedKinds.formUnion(fresh)
            openRequestedAt = nowProvider()
        }
        guard !behind.isEmpty, !reloadRequested, !coveredByOpen else { return }
        openRequestedKinds.formUnion(fresh)
        if openRequestedAt == nil { openRequestedAt = nowProvider() }
        forceReloadOnMain(scheduleRetry: false, caller: caller, reason: "open:\(behind.joined(separator: "+"))")
    }

    /// The watch app resigned active or moved to background. When the open requested a reload and an
    /// installed kind has had no provider run since, requests once more (watchOS draws the face as the
    /// app closes). At most once per foreground session.
    func requestCloseRefresh(caller: String = "close_refresh") {
        onMain { [self] in
            guard openSessionActive else { return }
            openSessionActive = false
            guard let requestedAt = openRequestedAt else { return }
            openRequestedAt = nil
            let since = requestedAt.timeIntervalSince1970
            let current = gateSnapshotOnMain()
            // A run after the request counts only if it rendered the current content: a provider that
            // loaded the old snapshot just before the open saved the new one can record its run later.
            let pending = (installedKnownKinds() ?? Self.allComplicationKinds)
                .filter { (lastProviderRunAtEpoch($0) ?? -1) < since || kindIsBehind($0, snapshot: current).behind }
                .map { Self.kindLabels[$0] ?? $0 }
            let action = pending.isEmpty ? "skipped" : "requested"
            log(
                "event=complication_close_refresh caller=\(caller) open_request_epoch=\(Int(since))"
                    + " pending=\(pending.isEmpty ? "none" : pending.joined(separator: "+")) action=\(action)"
            )
            guard !pending.isEmpty else { return }
            forceReloadOnMain(scheduleRetry: false, caller: caller, reason: "close:\(pending.joined(separator: "+"))")
        }
    }

    /// Bobble settings changed: reload only the Bobble kind. Never gated; refreshes its remembered key.
    func reloadGlucoseBobbleKind(caller: String = "bobble_settings") {
        onMain { [self] in
            let key = contentKey(forKind: Self.glucoseBobbleComplicationKind, snapshot: gateSnapshotOnMain())
            inMemoryRequestedContentKeys[Self.glucoseBobbleComplicationKind] = key
            appGroupDefaults?.set(key, forKey: Self.lastRequestedContentKeyPrefix + Self.glucoseBobbleComplicationKind)
            log("event=complication_kind_reload kind=\(Self.glucoseBobbleComplicationKind) caller=\(caller)")
            if let kindReloadSink {
                kindReloadSink(Self.glucoseBobbleComplicationKind)
            } else {
                WidgetCenter.shared.reloadTimelines(ofKind: Self.glucoseBobbleComplicationKind)
            }
        }
    }

    // MARK: - TRIO-120 Provider-run telemetry (written by the complication extension)

    struct ProviderRunInfo: Equatable {
        /// Seconds since the previous provider run of this kind; -1 when there was none.
        let sincePrevRunSeconds: Int
        /// True when this run's reading is newer than the previous run's; false when either is unknown.
        let newerReading: Bool
        /// TRIO-126: seconds from the latest watch-app open to this run; set only on the first run of
        /// this kind after that open, nil on every later run.
        var openToRunSeconds: Int? = nil
    }

    @discardableResult
    func recordProviderRun(kind: String, readingEpoch: Int?, renderedContentKey: String? = nil, now: Date = Date()) -> ProviderRunInfo {
        guard let defaults = appGroupDefaults else { return ProviderRunInfo(sincePrevRunSeconds: -1, newerReading: false) }
        let atKey = Self.lastProviderRunAtKeyPrefix + kind
        let readingKey = Self.lastProviderRunReadingKeyPrefix + kind
        let prevAt = defaults.object(forKey: atKey) as? Double
        let prevReading = defaults.object(forKey: readingKey) as? Int
        let since = prevAt.map { max(0, Int(now.timeIntervalSince1970 - $0)) } ?? -1
        let newer: Bool = {
            guard let readingEpoch, let prevReading else { return false }
            return readingEpoch > prevReading
        }()
        defaults.set(now.timeIntervalSince1970, forKey: atKey)
        if let readingEpoch { defaults.set(readingEpoch, forKey: readingKey) } else { defaults.removeObject(forKey: readingKey) }
        defaults.set(newer, forKey: Self.lastProviderRunNewerKeyPrefix + kind)
        // TRIO-126: what this run rendered, for the open check. No key recorded means behind.
        if let renderedContentKey {
            defaults.set(renderedContentKey, forKey: Self.lastProviderRunContentKeyPrefix + kind)
        } else {
            defaults.removeObject(forKey: Self.lastProviderRunContentKeyPrefix + kind)
        }
        var openToRun: Int?
        if let openAt = defaults.object(forKey: Self.lastOpenAtKey) as? Double,
           now.timeIntervalSince1970 >= openAt,
           defaults.object(forKey: Self.openLatencyLoggedKeyPrefix + kind) as? Double != openAt
        {
            openToRun = Int(now.timeIntervalSince1970 - openAt)
            defaults.set(openAt, forKey: Self.openLatencyLoggedKeyPrefix + kind)
        }
        return ProviderRunInfo(sincePrevRunSeconds: since, newerReading: newer, openToRunSeconds: openToRun)
    }

    /// Per kind: seconds since its last provider run and whether that run carried a newer reading
    /// than the run before it. Appended to the reload request line.
    private func providerRunSummary(now: Date) -> String {
        let labels = [Self.complicationKind: "main", Self.glucoseBobbleComplicationKind: "bobble"]
        return Self.allComplicationKinds.map { kind in
            let label = labels[kind] ?? kind
            var since = -1
            var newer = false
            if let defaults = appGroupDefaults {
                if let at = defaults.object(forKey: Self.lastProviderRunAtKeyPrefix + kind) as? Double {
                    since = max(0, Int(now.timeIntervalSince1970 - at))
                }
                newer = defaults.bool(forKey: Self.lastProviderRunNewerKeyPrefix + kind)
            }
            return "\(label)_since_prev_run_s=\(since) \(label)_newer_reading=\(newer)"
        }.joined(separator: " ")
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

    private func coalescedReloadOnMain(
        minInterval: TimeInterval = 30,
        isRetry: Bool = false,
        scheduleRetry: Bool = true,
        scheduleTrailing: Bool = false,
        gateCaller: String? = nil
    ) {
        assert(Thread.isMainThread, "coalescedReloadOnMain must be called on main thread")
        let now = nowProvider()
        let elapsed = now.timeIntervalSince(lastReload)

        if elapsed < minInterval {
            reloadSuppressionCount += 1
            let elapsedStr = String(format: "%.3f", elapsed)
            let minStr = String(format: "%.3f", minInterval)
            log("⏳ Reload DEBOUNCED burst_window_id=\(burstWindowId) suppressed=\(reloadSuppressionCount) elapsed=\(elapsedStr)s min=\(minStr)s")
            if scheduleTrailing {
                scheduleTrailingReloadOnMain(minInterval: minInterval, remaining: minInterval - elapsed)
            }
            return
        }

        // TRIO-120: gated callers (save path, trailing reload) go ahead only when what a face shows
        // changed since the last request, or the last request is unserviced.
        if let gateCaller {
            guard evaluateReloadGateOnMain(caller: gateCaller).proceed else { return }
            currentRequestCaller = gateCaller
        } else {
            currentRequestCaller = isRetry ? "coalesced_retry" : "coalesced"
            currentRequestReason = "bypass"
        }

        cancelPendingRetryOnMain(reason: "superseded by new reload")
        Self.reloadGenerationToken = UUID().uuidString

        burstWindowId += 1
        reloadSuppressionCount = 0
        let elapsedStr = String(format: "%.3f", elapsed)
        log("🔄 Reload TRIGGERED burst_window_id=\(burstWindowId) suppressed=\(reloadSuppressionCount) elapsed=\(elapsedStr)s since last reload\(isRetry ? " (retry)" : "")")
        lastReload = now
        noteReloadFiredOnMain(by: "coalesced")
        performReload()

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
    func forceReload(scheduleRetry: Bool = true, caller: String = "force") {
        onMain { [self] in
            forceReloadOnMain(scheduleRetry: scheduleRetry, caller: caller)
        }
    }

    private func forceReloadOnMain(scheduleRetry: Bool = true, caller: String = "force", reason: String = "bypass") {
        assert(Thread.isMainThread, "forceReloadOnMain must be called on main thread")
        currentRequestCaller = caller
        currentRequestReason = reason
        cancelPendingRetryOnMain(reason: "superseded by force reload")
        Self.reloadGenerationToken = UUID().uuidString
        log("🔄 FORCE reload triggered (bypassing debounce)")
        lastReload = nowProvider()
        noteReloadFiredOnMain(by: "force")
        performReload()
        if scheduleRetry {
            scheduleRetryAfterReloadOnMain(minInterval: 30)
        }
    }

    private func performReload() {
        reloadRequestSequence += 1
        recordRequestedContentOnMain()
        if let reloadSink {
            reloadSink()
            return
        }
        reloadTimeline()
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
            log("event=complication_reload_requested reload_generation=\(reloadGeneration) reload_requested_at_epoch_seconds=\(record.requestedAtEpochSeconds) reload_id=\(record.id.uuidString) caller=\(currentRequestCaller) gate_reason=\(currentRequestReason) \(providerRunSummary(now: Date()))")

            if let lastTS = Self.lastValidTimestamp {
                let ageSec = max(0, Int(Date().timeIntervalSince(lastTS)))
                log("event=complication_reload_age age_seconds=\(ageSec) reading_date_epoch_seconds=\(Int(lastTS.timeIntervalSince1970)) reading_date=\(Self.iso8601Formatter.string(from: lastTS))")
            }
            // Names both kinds: the block below reloads the circular complication too (two calls on
            // watchOS 10+, reloadAllTimelines before). Same prefix as before, so existing queries on
            // "Calling WidgetCenter.reloadTimelines" still match.
            log("🔔 Calling WidgetCenter.reloadTimelines for kinds \(Self.complicationKind) and \(Self.glucoseBobbleComplicationKind) (reloadAllTimelines before watchOS 10)")

            let reloadBlock = {
                if #available(watchOS 10.0, *) {
                    WidgetCenter.shared.reloadTimelines(ofKind: Self.complicationKind)
                    WidgetCenter.shared.reloadTimelines(ofKind: Self.glucoseBobbleComplicationKind)
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
                self.performUnservicedCheckOnMain(generation: generation)
            }
            unservicedCheckWorkItem = work
            scheduleDelayedWork(Self.unservicedCheckDelay, work)
        }

        /// The body of the unserviced check. TRIO-120: serviced means every installed kind observed
        /// `generation`. Never gated. Refreshes the installed-kinds cache for the next evaluation.
        func performUnservicedCheckOnMain(generation: Int) {
            defer { refreshInstalledKinds() } // after evaluating, so a changed set re-checks exactly once
            evaluateUnservicedOnMain(generation: generation, trigger: nil)
        }

        /// Shared unserviced evaluation and re-request (15 min rate limit). `trigger` is logged when
        /// the check was not the timer (e.g. `installed_kinds_changed`).
        fileprivate func evaluateUnservicedOnMain(generation: Int, trigger: String?) {
            guard !isGenerationServiced(generation) else { return } // serviced — the common, silent case
            if trigger != nil, openRequestIsPending() { return }
            let observed = widgetObservedGeneration() ?? -1
            let triggerField = trigger.map { " trigger=\($0)" } ?? ""
            guard Date().timeIntervalSince(lastUnservicedRetryAt) >= Self.unservicedRetryMinInterval else {
                log("event=complication_reload_unserviced generation=\(generation) observed=\(observed) per_kind=\(perKindObservedSummary())\(triggerField) action=rate_limited")
                return
            }
            lastUnservicedRetryAt = Date()
            log("event=complication_reload_unserviced generation=\(generation) observed=\(observed) per_kind=\(perKindObservedSummary())\(triggerField) action=re_request")
            forceReloadOnMain(scheduleRetry: false, caller: "unserviced_re_request")
        }
    #endif

    #if !WIDGET_EXTENSION
    /// C-210-9 (scan #3): launch/resume reconciliation. The in-memory unserviced-reload timer
    /// (`scheduleUnservicedReloadCheck`) dies if the app is suspended before its grace period fires,
    /// so an unserviced reload could otherwise never recover. Both generations are persisted in the
    /// App Group, so compare them on launch/foreground and re-request once (rate-limited) when the
    /// widget never serviced the most recent reload. Watch-app only (never the widget process).
    func reconcileUnservicedReloadOnLaunch() {
        // TRIO-120: refresh the installed kinds (launch and foreground); this evaluation uses the
        // cache, and a changed set re-checks servicing when the refresh completes.
        defer { refreshInstalledKinds() }
        guard let defaults = appGroupDefaults else { return }
        let requested = defaults.integer(forKey: Self.reloadGenerationKey)
        guard requested > 0 else { return }
        let observed = widgetObservedGeneration() ?? -1
        guard !isGenerationServiced(requested) else { return } // serviced — the common case
        if openRequestIsPending() {
            log("event=complication_reload_unserviced_launch requested=\(requested) observed=\(observed) per_kind=\(perKindObservedSummary()) action=open_request_pending")
            return
        }
        guard Date().timeIntervalSince(lastUnservicedRetryAt) >= Self.unservicedRetryMinInterval else {
            log("event=complication_reload_unserviced_launch requested=\(requested) observed=\(observed) per_kind=\(perKindObservedSummary()) action=rate_limited")
            return
        }
        lastUnservicedRetryAt = Date()
        log("event=complication_reload_unserviced_launch requested=\(requested) observed=\(observed) per_kind=\(perKindObservedSummary()) action=re_request")
        forceReload(scheduleRetry: false, caller: "launch_reconcile")
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

    /// TRIO-118: records which saved reading a firing reload covers, and absorbs a pending trailing
    /// reload only if that reload already covers the newest stored reading. A reload that fired
    /// before the newest save (e.g. a force reload just before it) does not.
    private func noteReloadFiredOnMain(by source: String) {
        assert(Thread.isMainThread, "noteReloadFiredOnMain must be called on main thread")
        lastReloadCoveredReadingDate = newestSavedReadingDate
        guard trailingReloadID != nil,
              let newest = newestSavedReadingDate,
              let covered = lastReloadCoveredReadingDate,
              covered >= newest else { return }
        pendingTrailingWorkItem?.cancel()
        pendingTrailingWorkItem = nil
        trailingReloadID = nil
        log("⏱️ Trailing reload ABSORBED by=\(source)")
    }

    /// TRIO-118: a save's reload was suppressed by `minInterval`; schedule one trailing reload for when
    /// the interval expires. At most one is pending. Independent of the retry machinery.
    private func scheduleTrailingReloadOnMain(minInterval: TimeInterval, remaining: TimeInterval) {
        assert(Thread.isMainThread, "scheduleTrailingReloadOnMain must be called on main thread")
        guard trailingReloadID == nil else { return }

        let id = UUID()
        trailingReloadID = id
        let delay = max(0, remaining) + Self.trailingReloadMargin
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.trailingReloadID == id else { return }
            self.pendingTrailingWorkItem = nil
            self.trailingReloadID = nil
            self.log("⏱️ Trailing reload FIRED")
            self.coalescedReloadOnMain(minInterval: minInterval, scheduleRetry: false, scheduleTrailing: true, gateCaller: "trailing")
        }
        pendingTrailingWorkItem = workItem
        log("⏱️ Trailing reload SCHEDULED in=\(String(format: "%.1f", delay))s")
        scheduleDelayedWork(delay, workItem)
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
        dataAgeSeconds: Int,
        sincePrevRunSeconds: Int,
        newerReading: Bool,
        openToRunSeconds: Int? = nil
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
            + " kind=\(Self.complicationKind)"
            + " since_prev_run_s=\(sincePrevRunSeconds)"
            + " newer_reading=\(newerReading)"
            + (openToRunSeconds.map { " open_to_run_s=\($0)" } ?? "")
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

    // fork — distinct event names keep the corner complication's complication_get_timeline_called
    // metrics unaffected; -1 means unavailable for the ages and generation.
    func logGlucoseBobbleProviderCall(
        call: String,
        isPreview: Bool,
        hasSnapshot: Bool,
        dataAgeSeconds: Int,
        loopAgeSeconds: Int,
        observedReloadGeneration: Int,
        settingsSummary: String,
        runInfo: ProviderRunInfo? = nil
    ) {
        log(
            "event=glucose_bobble_complication_\(call)"
            + " kind=TrioGlucoseBobbleComplication"
            + " is_preview=\(isPreview)"
            + " has_snapshot=\(hasSnapshot)"
            + " data_age_seconds=\(dataAgeSeconds)"
            + " loop_age_seconds=\(loopAgeSeconds)"
            + " observed_reload_generation=\(observedReloadGeneration)"
            + (runInfo.map { " since_prev_run_s=\($0.sincePrevRunSeconds) newer_reading=\($0.newerReading)" + ($0.openToRunSeconds.map { " open_to_run_s=\($0)" } ?? "") } ?? "")
            + " \(settingsSummary)"
        )
    }
#endif

    private func log(_ message: String) {
        ComplicationLogBuffer.append(message)
        let forwarder = Self.logForwarderLock.withLock { $0.forwarder }
        forwarder?(message)
    }
}
