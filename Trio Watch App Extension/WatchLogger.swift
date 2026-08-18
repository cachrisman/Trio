import Foundation
import WatchKit
import WatchConnectivity

/// Shared startup transport gate for watch log delivery.
/// Synchronous access is required so foreground lifecycle code can arm or disarm
/// suppression before any follow-on log call has a chance to flush.
enum WatchStartupTransportGate {
    private static let lock = NSLock()
    private static var isSuppressed = true
    private static var activationSequence: Int?

    static func arm(activationSequence: Int?) {
        lock.lock()
        defer { lock.unlock() }
        isSuppressed = true
        self.activationSequence = activationSequence
    }

    @discardableResult
    static func disarm(activationSequence: Int? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let activationSequence,
           let currentActivationSequence = self.activationSequence,
           currentActivationSequence != activationSequence
        {
            return false
        }

        isSuppressed = false
        self.activationSequence = nil
        return true
    }

    static func snapshot() -> (isSuppressed: Bool, activationSequence: Int?) {
        lock.lock()
        defer { lock.unlock() }
        return (isSuppressed, activationSequence)
    }
}

// MARK: - WCSession send completion (single resume for reply vs error)

/// Ensures `CheckedContinuation.resume` runs at most once when either `replyHandler` or `errorHandler` fires.
private final class WCSessionReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func complete(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume()
    }
}

actor WatchLogger {
    static let shared = WatchLogger()

    private let build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    private var logs: [String] = []
    private let maxEntries = 500
    private let flushInterval: TimeInterval = 3 * 60
    private let flushSizeThreshold = 100
    private var lastFlush = Date()

    // Size caps
    private let logSizeCap = 64 * 1024 // 64 KB
    private let maxPerPayloadFiles = 10
    private let maxFileAge: TimeInterval = 48 * 60 * 60 // 48 hours

    /// Hard ceiling for `watch_log_daily.txt`. Past this, `appendToDailyLog` rewrites the file
    /// keeping only the newest `dailyLogTruncateKeepBytes`. Bounded so the rewrite read stays
    /// well under the watchOS per-process memory limit that previously triggered Jetsam when
    /// `WatchErrorReporter.readRecentLogs` slurped an unbounded daily log via `Data(contentsOf:)`.
    private let dailyLogSizeCap: UInt64 = 2 * 1024 * 1024 // 2 MB
    private let dailyLogTruncateKeepBytes: UInt64 = 1 * 1024 * 1024 // 1 MB

    private let session = WCSession.default
    private var timerTask: Task<Void, Never>?

    private let pendingPayloadsKey = "watchLoggerPendingPayloads"
    private let lastKnownBuildKey = "watchLogger.lastKnownBuild"
    private let lastInventoryKey = "WatchLogger.lastInventoryTimestamp"

    // E3: Inline metrics cache (10s TTL)
    private var cachedWatchLogFiles: Int = 0
    private var cachedDrainFiles: Int = 0
    private var cachedCountsTimestamp: Date = .distantPast

    // C-209-2: daily-log lines buffer in-actor and write as one batch per drain — the per-line
    // open/seek/write/close (plus createDirectory) was the #2 measured battery driver. Local
    // debug file only; worst case on a hard kill is losing up to `dailyLogBufferMaxLines` buffered
    // lines of watch_log_daily.txt (writes now confirm before clearing + retry on failure).
    private var dailyLogBuffer: [String] = []
    private let dailyLogBatchSize = 40

    /// Loss accounting. The ring (`WatchTelemetryRing`) counts its own evictions; WatchLogger
    /// previously counted nothing, so on-device drops (a swallowed daily-log write, a `logs`
    /// drop-oldest) were silent. Window counters reset on each `log_pipeline_summary`; totals
    /// are cumulative for the process. Surfaced on the summary line so a lost batch leaves a trace.
    private var logsDropped = 0
    private var logsDroppedTotal = 0
    private var dailyWriteFailures = 0
    private var dailyWriteFailuresTotal = 0
    private var dailyLogDropped = 0
    private var dailyLogDroppedTotal = 0
    /// Bound on the daily-log retry buffer so repeated write failures can't grow it unboundedly.
    private let dailyLogBufferMaxLines = 2000
    /// Buffer size after the last daily-log drain attempt — throttles size-triggered retries to once
    /// per fresh batch (not on every log()) while a failed batch is still buffered.
    private var lastDailyDrainCount = 0
    /// Cause of the most recent daily-log write failure (sanitized, truncated); surfaced on the summary.
    private var lastDailyWriteError: String?

    // C-209-3: routine pipeline narration (ack cleanups, queued-bg notices, confirm batches)
    // is counted here and emitted as ONE `log_pipeline_summary` line per flush. These sites
    // were ~70% of all watch log volume on build 208 (logCleanup alone: 12.2k lines/40h).
    // Error paths still emit full diagnostic lines.
    private var pipelineQueuedBackground = 0
    private var pipelineCleanupOk = 0
    private var pipelineConfirmFiles = 0

    // C-209-4: WC log shipping slows to 10 min while backgrounded — the 3-min cadence is a
    // radio/battery tax with no reader benefit when the app is off-screen. Set from the
    // TrioWatchApp scene-phase hook.
    private var isBackgrounded = false
    private let backgroundFlushInterval: TimeInterval = 10 * 60
    private var currentFlushInterval: TimeInterval {
        isBackgrounded ? backgroundFlushInterval : flushInterval
    }

    // C-209-3: process-local inventory guard — the persisted 24h gate demonstrably fails
    // across watch process churn (1.5k [INVENTORY] lines in 40h on build 208).
    private var didLogInventoryThisProcess = false

    /// Wall-clock cap for how long **this actor** waits on `sendMessage`’s reply/error callbacks.
    /// This does **not** cancel in-flight `WCSession` delivery; a late `replyHandler` may still run.
    /// Keep conservative on watchOS: long waits serialize the actor behind other lifecycle/flush work.
    /// Raise only if telemetry shows healthy ACKs routinely exceed this under real devices.
    private static let wcSessionSendTimeoutNs: UInt64 = 5 * 1_000_000_000

    private init() {
        Task {
            await startFlushTimer()
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // C-208-8 (6.5): pin locale + calendar — an unpinned DateFormatter follows the device's
        // settings, so a watch on the Buddhist/Japanese calendar would stamp shifted years into
        // every log line, silently breaking time correlation in BetterStack.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    // MARK: - File-removal helpers

    struct RemoveResult {
        let outcome: String // "deleted" | "missing" | "error"
        let error: String? // nil → result=ok
        var succeeded: Bool { error == nil }
    }

    static func removeFileTracked(at url: URL) -> RemoveResult {
        do {
            try FileManager.default.removeItem(at: url)
            return RemoveResult(outcome: "deleted", error: nil)
        } catch {
            let nsErr = error as NSError
            if nsErr.domain == NSCocoaErrorDomain && nsErr.code == 4 {
                return RemoveResult(outcome: "missing", error: nil)
            }
            return RemoveResult(
                outcome: "error",
                error: sanitizeError(error)
            )
        }
    }

    static func removeFileTracked(atPath path: String) -> RemoveResult {
        do {
            try FileManager.default.removeItem(atPath: path)
            return RemoveResult(outcome: "deleted", error: nil)
        } catch {
            let nsErr = error as NSError
            if nsErr.domain == NSCocoaErrorDomain && nsErr.code == 4 {
                return RemoveResult(outcome: "missing", error: nil)
            }
            return RemoveResult(
                outcome: "error",
                error: sanitizeError(error)
            )
        }
    }

    /// Best-effort removal: true = gone (deleted or already absent),
    /// false = unexpected error.
    static func removeFileQuietly(at url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            let nsErr = error as NSError
            return nsErr.domain == NSCocoaErrorDomain && nsErr.code == 4
        }
    }

    static func sanitizeError(_ error: Error) -> String {
        let nsErr = error as NSError
        let raw = "\(nsErr.domain)_\(nsErr.code)"
        let sanitized = raw
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
        return String(sanitized.prefix(50))
    }

    /// Non-blocking: nudges `activate()` and reports whether the session is already `.activated`
    /// for an immediate `sendMessage`. Avoids multi-second polling on hot paths.
    private func prepareSessionForImmediateSend() -> Bool {
        if session.activationState == .activated { return true }
        session.activate()
        return session.activationState == .activated
    }

    /// Awaits `sendMessage` until reply, error, or **actor-side** timeout.
    ///
    /// **Semantics:** The timeout only bounds how long `WatchLogger` suspends; it does not cancel the
    /// underlying session send. If the phone ACKs later, `replyHandler` may still run; `WCSessionReplyGate`
    /// ensures the continuation resumes at most once, while `onReply` cleanup stays idempotent
    /// (`removeFileTracked` / `removePendingPayload` tolerate missing files).
    ///
    /// **Pending:** Call sites that need recovery must `storePendingPayload` *before* awaiting here.
    /// On timeout we **do not** enqueue `transferUserInfo` automatically (avoids duplicate delivery);
    /// the payload row + on-disk file remain for `resendPendingPayloads` / a later ACK.
    private func sendMessageAwaitingReply(
        _ envelope: [String: Any],
        context: String,
        onReply: @escaping ([String: Any]) async -> Void,
        onError: @escaping (Error) async -> Void
    ) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let gate = WCSessionReplyGate()
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: Self.wcSessionSendTimeoutNs)
                // C-208-5 (1.6): `try?` swallows CancellationError, so without this guard the
                // reply/error handlers' `timeoutTask.cancel()` *woke* this task, which then
                // logged a phantom "timed out" line on every ACKed send — corrupting the
                // WC-delivery telemetry used to debug actual delivery problems.
                guard !Task.isCancelled else { return }
                await WatchLogger.shared.log(
                    "⌚️ WCSession sendMessage timed out context=\(context)"
                        + " note=payload_still_pending no_auto_transferUserInfo"
                )
                gate.complete(cont)
            }
            session.sendMessage(
                envelope,
                replyHandler: { reply in
                    Task {
                        timeoutTask.cancel()
                        defer { gate.complete(cont) }
                        await onReply(reply)
                    }
                },
                errorHandler: { error in
                    Task {
                        timeoutTask.cancel()
                        defer { gate.complete(cont) }
                        await onError(error)
                    }
                }
            )
        }
    }

    // Battery context: enable monitoring once per process; all reads on MainActor.
    private static var hasEnabledBatteryMonitoring = false

    @MainActor
    private static func batteryContextOnMain() -> String {
        let device = WKInterfaceDevice.current()
        if !hasEnabledBatteryMonitoring {
            hasEnabledBatteryMonitoring = true
            device.isBatteryMonitoringEnabled = true
        }
        let levelText: String
        if device.batteryLevel >= 0 {
            levelText = String(Int((device.batteryLevel * 100).rounded()))
        } else {
            levelText = "unknown"
        }
        let stateText: String
        switch device.batteryState {
        case .unknown:
            stateText = "unknown"
        case .unplugged:
            stateText = "unplugged"
        case .charging:
            stateText = "charging"
        case .full:
            stateText = "full"
        @unknown default:
            stateText = "unknown_default"
        }
        return "battery_level_percent=\(levelText) battery_state=\(stateText)"
    }

    private var lastBatteryContext = "battery_level_percent=unknown battery_state=unknown"
    private var lastBatteryRefreshEpoch: TimeInterval = 0
    private var batteryRefreshTask: Task<String, Never>?

    /// C-209-5 (B6): TTL 60s → 15s. The 60s cache smeared `battery_state` for up to a minute
    /// around plug/unplug transitions; a state-only fresh read would cost the same MainActor
    /// hop as refreshing both fields, so the whole context refreshes at 15s (≤4 hops/min).
    private func batteryContextCached(now: TimeInterval = Date().timeIntervalSince1970) async -> String {
        if now - lastBatteryRefreshEpoch < 15 {
            return lastBatteryContext
        }
        if let existing = batteryRefreshTask {
            let result = await existing.value
            let currentNow = Date().timeIntervalSince1970
            if currentNow - lastBatteryRefreshEpoch >= 15 {
                lastBatteryContext = result
                lastBatteryRefreshEpoch = currentNow
            }
            return result
        }
        let task = Task { await MainActor.run { Self.batteryContextOnMain() } }
        batteryRefreshTask = task
        defer { batteryRefreshTask = nil }

        let result = await task.value
        lastBatteryContext = result
        lastBatteryRefreshEpoch = Date().timeIntervalSince1970
        return result
    }

    // MARK: - Timer

    private func startFlushTimer() async {
        timerTask = Task {
            while true {
                // C-209-4: re-read each cycle so background entry/exit changes the cadence.
                try? await Task.sleep(nanoseconds: UInt64(currentFlushInterval * 1_000_000_000))
                await flushIfNeeded(force: false)
            }
        }
    }

    // MARK: - Logging

    func log(
        _ message: String,
        force: Bool = false,
        function: String = #function,
        file: String = #fileID,
        line: Int = #line
    ) async {
        let shortFile = (file as NSString).lastPathComponent
        let timestamp = Self.dateFormatter.string(from: Date())
        let batteryContext = await batteryContextCached()
        let entry = "[\(timestamp)] [b:\(build)] [\(shortFile):\(line)] \(function) → \(message) \(batteryContext)"

        logs.append(entry)
        if logs.count > maxEntries {
            let over = logs.count - maxEntries
            logs.removeFirst(over)
            logsDropped += over          // surfaced on the next log_pipeline_summary (mirrors ring_dropped)
            logsDroppedTotal += over
        }

        #if DEBUG
            print(entry)
        #endif

        bufferDailyLogLine(entry)

        await flushIfNeeded(force: force)
    }

    /// C-209-2: directory resolution + creation hoisted to once-per-process — it previously ran
    /// on every single log line.
    private static let dailyLogFileURL: URL = {
        let logDir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logDir, withIntermediateDirectories: true
        )
        return logDir.appendingPathComponent("watch_log_daily.txt")
    }()

    /// C-209-2: buffer a line; one batched disk write per `dailyLogBatchSize` lines or per
    /// flush-cadence drain (see `flushIfNeeded`).
    private func bufferDailyLogLine(_ text: String) {
        dailyLogBuffer.append(text)
        // Drain once per fresh batch since the last attempt — not on every line while a failed batch
        // is still buffered (that previously turned every log() into a disk-write retry). The flush
        // cadence retries the stuck batch separately.
        if dailyLogBuffer.count - lastDailyDrainCount >= dailyLogBatchSize {
            drainDailyLogBuffer()
        }
    }

    /// C-209-2: single open/seek/write/close for the whole buffered batch. Confirm the write before
    /// clearing the buffer (previously it cleared first and swallowed write errors → silent batch loss).
    private func drainDailyLogBuffer() {
        guard !dailyLogBuffer.isEmpty else { lastDailyDrainCount = 0; return }
        let batch = dailyLogBuffer.joined(separator: "\n")
        if appendToDailyLog(batch) {
            dailyLogBuffer.removeAll(keepingCapacity: true)
            lastDailyWriteError = nil // recovered — don't let a stale cause ride the next summary
        } else {
            // Write failed — keep the batch for the next drain instead of silently dropping it.
            dailyWriteFailures += 1
            dailyWriteFailuresTotal += 1
            if dailyLogBuffer.count > dailyLogBufferMaxLines {
                let over = dailyLogBuffer.count - dailyLogBufferMaxLines
                dailyLogBuffer.removeFirst(over)
                dailyLogDropped += over
                dailyLogDroppedTotal += over
            }
        }
        lastDailyDrainCount = dailyLogBuffer.count // 0 after success; retained count throttles retries
    }

    /// Appends text to the daily local debug log (never sent to phone).
    /// Returns whether the append succeeded (no throw — not fsync-verified); the caller keeps the
    /// buffer on `false` so a swallowed write failure can no longer silently lose the batch.
    @discardableResult
    private func appendToDailyLog(_ text: String) -> Bool {
        let dailyLogFile = Self.dailyLogFileURL
        let logEntry = text + "\n"

        guard let data = logEntry.data(using: .utf8) else { return false }

        var postWriteSize: UInt64?
        do {
            if FileManager.default.fileExists(atPath: dailyLogFile.path) {
                // File exists → append. If it can't be opened for writing, FAIL — never overwrite the
                // log with just this batch (the old `data.write(to:)` fallback silently truncated it).
                let handle = try FileHandle(forWritingTo: dailyLogFile)
                defer { try? handle.close() }
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: data)
                postWriteSize = try? handle.offset()
            } else {
                try data.write(to: dailyLogFile) // first write — create the file
                postWriteSize = UInt64(data.count)
            }
        } catch {
            // Domain+code only — never the path/filename, which could ride the summary line to BetterStack.
            let nsErr = error as NSError
            lastDailyWriteError = "\(nsErr.domain)#\(nsErr.code)".replacingOccurrences(of: " ", with: "_").prefix(40).description
            return false // batch is retried (not dropped); cause surfaced on the summary line
        }

        if let size = postWriteSize, size > dailyLogSizeCap {
            truncateDailyLogKeepingNewest(at: dailyLogFile)
        }
        return true
    }

    /// Rewrites `watch_log_daily.txt` keeping only the newest `dailyLogTruncateKeepBytes`,
    /// aligned to a newline boundary so the head of the file stays line-clean.
    ///
    /// Streaming tail read via `FileHandle` so peak allocation is bounded by
    /// `dailyLogTruncateKeepBytes` (~1 MB) regardless of how large the on-disk file is —
    /// `Data(contentsOf:)` would re-introduce the Jetsam risk this fix exists to prevent.
    private func truncateDailyLogKeepingNewest(at url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return }
        let keepBytes = min(fileSize, dailyLogTruncateKeepBytes)
        let startOffset = fileSize - keepBytes
        try? handle.seek(toOffset: startOffset)

        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

        // If we tailed from mid-file, drop any bytes before the first newline so we don't
        // leave a partial line at the head of the rewritten file.
        let aligned: Data = {
            guard startOffset > 0, let nlIndex = data.firstIndex(of: UInt8(ascii: "\n")) else {
                return data
            }
            let after = data.index(after: nlIndex)
            return after < data.endIndex ? data.subdata(in: after ..< data.endIndex) : Data()
        }()

        guard !aligned.isEmpty else { return }

        let marker = "[truncated daily log: kept newest \(aligned.count) bytes]\n"
        var output = Data(marker.utf8)
        output.append(aligned)

        try? output.write(to: url, options: .atomic)
    }

    // MARK: - Flush

    func flushIfNeeded(force: Bool = false) async {
        let now = Date()
        let shouldFlush = force
            || now.timeIntervalSince(lastFlush) >= currentFlushInterval // C-209-4
            || logs.count >= flushSizeThreshold

        if shouldFlush {
            drainDailyLogBuffer() // C-209-2: the local file rides the same cadence
            guard !WatchStartupTransportGate.snapshot().isSuppressed else { return }
            await flushToPhone()
        }
    }

    /// C-209-4: scene-phase hook (TrioWatchApp). Entering background gets one last forced flush
    /// from the existing scene-transition log call; after that, shipping runs at
    /// `backgroundFlushInterval` until the app is active again.
    func setBackgrounded(_ backgrounded: Bool) {
        isBackgrounded = backgrounded
    }

    private func flushToPhone() async {
        guard !logs.isEmpty else { return }
        guard !WatchStartupTransportGate.snapshot().isSuppressed else { return }

        updateCachedCountsIfStale()
        await logFileInventory()

        let allContent = logs.joined(separator: "\n")
        let originalUTF8Count = allContent.utf8.count
        let totalLineCount = logs.count
        let originalLines = logs

        logs.removeAll()
        lastFlush = Date()

        // C-209-3: one summary line per flush replaces the demoted per-event pipeline
        // narration, and carries the live E3 counts that per-flush [INVENTORY] used to spam.
        // log() here is safe: lastFlush was just reset, so the nested flushIfNeeded no-ops.
        let summary = "event=log_pipeline_summary"
            + " lines_flushed=\(totalLineCount)"
            + " queued_bg=\(pipelineQueuedBackground)"
            + " cleanup_ok=\(pipelineCleanupOk)"
            + " confirm_files=\(pipelineConfirmFiles)"
            + " watch_log_files=\(cachedWatchLogFiles)"
            + " drain_files=\(cachedDrainFiles)"
            + " logs_dropped=\(logsDropped) logs_dropped_total=\(logsDroppedTotal)"
            + " daily_write_failures=\(dailyWriteFailures) daily_write_failures_total=\(dailyWriteFailuresTotal)"
            + " daily_lines_dropped=\(dailyLogDropped) daily_lines_dropped_total=\(dailyLogDroppedTotal)"
            + (lastDailyWriteError.map { " daily_write_err=\($0)" } ?? "")
        pipelineQueuedBackground = 0
        pipelineCleanupOk = 0
        pipelineConfirmFiles = 0
        logsDropped = 0
        dailyWriteFailures = 0
        dailyLogDropped = 0
        lastDailyWriteError = nil
        await log(summary)

        // Single payload fits within cap — send directly
        if originalUTF8Count <= logSizeCap {
            await sendLogPayload(allContent)
            return
        }

        // 4E: Split oversized payloads into sequential chunks (max 4 × logSizeCap)
        let maxChunks = 4
        let groupId = UUID().uuidString

        // Content budget per chunk: logSizeCap minus worst-case chunk marker overhead.
        // Marker byte cost is subtracted so the total chunk payload stays within logSizeCap.
        let worstCaseMarker = "📦 log_flush_chunk chunk=\(maxChunks)/\(maxChunks) payload_id=\(groupId) lines_in_chunk=\(totalLineCount)"
        let markerOverhead = worstCaseMarker.utf8.count + 1
        let contentBudget = max(1, logSizeCap - markerOverhead)

        // Pack lines greedily into chunks (line-boundary-aware)
        var chunks: [(content: String, lineCount: Int)] = []
        var currentLines: [String] = []
        var currentBytes = 0
        var lineIndex = 0

        while lineIndex < originalLines.count {
            let line = originalLines[lineIndex]
            let addedBytes = (currentLines.isEmpty ? 0 : 1) + line.utf8.count

            if currentBytes + addedBytes > contentBudget && !currentLines.isEmpty {
                chunks.append((
                    content: currentLines.joined(separator: "\n"),
                    lineCount: currentLines.count
                ))
                currentLines = []
                currentBytes = 0

                if chunks.count >= maxChunks - 1 {
                    // Last allowed chunk — pack all remaining lines
                    let remaining = Array(originalLines[lineIndex...])
                    let remainingContent = remaining.joined(separator: "\n")

                    if remainingContent.utf8.count <= contentBudget {
                        chunks.append((content: remainingContent, lineCount: remaining.count))
                    } else {
                        // 4A truncation on the last chunk — pack what fits, then COUNT + surface the rest.
                        // Reserve marker width (incl. a worst-case lines_dropped field) so the real count
                        // can be filled in after packing without busting the byte budget.
                        let markerTemplate = "⚠️ log_flush_truncated cap_bytes=\(logSizeCap) original_bytes=\(originalUTF8Count) lines_total=\(totalLineCount) lines_dropped=\(totalLineCount)"
                        let truncMarkerBytes = markerTemplate.utf8.count + 1
                        let truncBudget = max(0, contentBudget - truncMarkerBytes)

                        var truncLines: [String] = []
                        var truncBytes = 0
                        for rl in remaining {
                            let added = (truncLines.isEmpty ? 0 : 1) + rl.utf8.count
                            if truncBytes + added > truncBudget { break }
                            truncLines.append(rl)
                            truncBytes += added
                        }

                        // Overflow beyond 4x cap is dropped from the BetterStack ship path ONLY; the lines
                        // remain in the on-device daily log. Count them (cumulative logs_dropped_total, like
                        // the ring's evictions) and stamp the per-flush count on the truncation marker.
                        let droppedInTrunc = remaining.count - truncLines.count
                        if droppedInTrunc > 0 {
                            logsDropped += droppedInTrunc
                            logsDroppedTotal += droppedInTrunc
                        }
                        let truncMarker = "⚠️ log_flush_truncated cap_bytes=\(logSizeCap) original_bytes=\(originalUTF8Count) lines_total=\(totalLineCount) lines_dropped=\(droppedInTrunc)"
                        let truncContent = truncMarker + "\n" + truncLines.joined(separator: "\n")
                        chunks.append((content: truncContent, lineCount: truncLines.count))
                    }
                    lineIndex = originalLines.count
                    break
                }
                continue
            }

            currentLines.append(line)
            currentBytes += addedBytes
            lineIndex += 1
        }

        if !currentLines.isEmpty {
            chunks.append((
                content: currentLines.joined(separator: "\n"),
                lineCount: currentLines.count
            ))
        }

        let totalChunks = chunks.count

        for (index, chunk) in chunks.enumerated() {
            let chunkNumber = index + 1
            let chunkMarker = "📦 log_flush_chunk chunk=\(chunkNumber)/\(totalChunks) payload_id=\(groupId) lines_in_chunk=\(chunk.lineCount)"
            let finalContent = chunkMarker + "\n" + chunk.content
            await sendLogPayload(finalContent)
        }
    }

    /// Sends a single log payload (or chunk) to the phone via WCSession.
    private func sendLogPayload(_ content: String) async {
        let payloadId = UUID().uuidString

        let logDir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logDir, withIntermediateDirectories: true
        )

        let perPayloadFile = logDir.appendingPathComponent(
            "watch_log_\(payloadId).txt"
        )
        if let data = content.data(using: .utf8) {
            try? data.write(to: perPayloadFile)
        }

        let envelope: [String: Any] = [
            "type": "watchLogs",
            "payloadId": payloadId,
            "data": content
        ]

        if session.isReachable {
            guard prepareSessionForImmediateSend() else {
                await storePendingPayload(
                    payloadId: payloadId,
                    type: "watchLogs",
                    filePath: perPayloadFile.path
                )
                _ = session.transferUserInfo(envelope)
                await log(
                    "⌚️ Logs queued for background delivery"
                        + " (payloadId: \(payloadId))"
                        + " watch_log_files=\(cachedWatchLogFiles)"
                        + " drain_files=\(cachedDrainFiles)"
                        + " note=activation_timeout"
                )
                return
            }

            let filePath = perPayloadFile.path
            await storePendingPayload(
                payloadId: payloadId,
                type: "watchLogs",
                filePath: filePath
            )
            await sendMessageAwaitingReply(
                envelope,
                context: "flush payloadId=\(payloadId)"
            ) { reply in
                if let ackType = reply["type"] as? String,
                   ackType == "ack",
                   let ackId = WatchConnectivityPayloadIds.payloadIdString(
                       reply["payloadId"]
                   ),
                   ackId == payloadId {
                    let res = WatchLogger.removeFileTracked(
                        at: perPayloadFile
                    )
                    if res.succeeded {
                        await WatchLogger.shared
                            .removePendingPayload(payloadId)
                    }
                    await WatchLogger.shared
                        .logCleanup(
                            path: "ack_reply", flow: "flush",
                            artifact: "watch_log",
                            payloadId: payloadId,
                            result: res
                        )
                }
            } onError: { error in
                await WatchLogger.shared.log(
                    "⌚️ Failed to send logs: "
                        + error.localizedDescription
                )
            }
        } else {
            await storePendingPayload(
                payloadId: payloadId,
                type: "watchLogs",
                filePath: perPayloadFile.path
            )
            _ = session.transferUserInfo(envelope)
            // C-209-3: was a full line per payload (3.3k lines/40h); counted into the summary.
            pipelineQueuedBackground += 1
        }
    }

    // MARK: - Persisted log flush + retention

    func flushPersistedLogs(startupTransportSuppressedOverride: Bool? = nil) async {
        let startupTransportSuppressed = startupTransportSuppressedOverride
            ?? WatchStartupTransportGate.snapshot().isSuppressed
        let lastKnownBuild = UserDefaults.standard.string(
            forKey: lastKnownBuildKey
        )
        if lastKnownBuild != build {
            await log(
                "[UPGRADE] build changed"
                    + " from \(lastKnownBuild ?? "nil") to \(build)",
                force: !startupTransportSuppressed
            )
            UserDefaults.standard.set(build, forKey: lastKnownBuildKey)
        }

        guard !startupTransportSuppressed else { return }

        updateCachedCountsIfStale()
        await logFileInventory()

        await drainComplicationLogs()

        let logDir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("logs", isDirectory: true)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logDir,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]
        ) else { return }

        let perPayloadFiles = files.filter { file in
            file.lastPathComponent.hasPrefix("watch_log_")
                && file.lastPathComponent.hasSuffix(".txt")
                && file.lastPathComponent != "watch_log_daily.txt"
        }

        let validFiles = await applyWatchLogRetention(
            perPayloadFiles: perPayloadFiles
        )

        guard session.isReachable else { return }

        if !prepareSessionForImmediateSend() {
            await log(
                "⌚️ flush_persisted_logs skipping_query_acks"
                    + " note=session_not_activated"
            )
            return
        }

        let pendingPayloads = await getPendingPayloads()
        let pendingIds = pendingPayloads.compactMap {
            WatchConnectivityPayloadIds.payloadIdString($0["payloadId"])
        }

        if !pendingIds.isEmpty {
            let queryEnvelope: [String: Any] = [
                "type": "queryAcks",
                "pendingIds": pendingIds
            ]
            await sendMessageAwaitingReply(
                queryEnvelope,
                context: "query_acks"
            ) { reply in
                guard let ackType = reply["type"] as? String,
                      ackType == "batchAck"
                else {
                    await WatchLogger.shared.resendPendingPayloads()
                    return
                }

                let ackIds = WatchConnectivityPayloadIds.payloadIdStrings(
                    from: reply["ackIds"]
                )

                if ackIds.isEmpty {
                    await WatchLogger.shared.resendPendingPayloads()
                    return
                }

                var errCount = 0
                for ackId in ackIds {
                    let path = logDir.appendingPathComponent(
                        "watch_log_\(ackId).txt"
                    )
                    if WatchLogger.removeFileQuietly(at: path) {
                        await WatchLogger.shared
                            .removePendingPayload(ackId)
                    } else {
                        errCount += 1
                    }
                }
                let result = errCount > 0 ? "err" : "ok"
                await WatchLogger.shared.log(
                    "⌚️ [CLEANUP] path=query_acks"
                        + " artifact=watch_log"
                        + " count=\(ackIds.count)"
                        + " result=\(result)"
                )
                await WatchLogger.shared
                    .resendPendingPayloads()
            } onError: { error in
                await WatchLogger.shared.log(
                    "⌚️ Failed to query ACKs: "
                        + error.localizedDescription
                )
                await WatchLogger.shared.resendPendingPayloads()
            }
        } else {
            await resendPendingPayloads()
        }
    }

    /// Deletes age-expired and excess watch_log files, emits a
    /// [CLEANUP] retention summary when any files are removed.
    /// Returns the surviving file list.
    private func applyWatchLogRetention(
        perPayloadFiles: [URL]
    ) async -> [URL] {
        let now = Date()
        var validFiles: [URL] = []
        var expiredFiles: [URL] = []
        var oldestDeletedAge: TimeInterval = 0

        for file in perPayloadFiles {
            if let attrs = try? FileManager.default.attributesOfItem(
                atPath: file.path
            ),
                let created = attrs[.creationDate] as? Date {
                let age = now.timeIntervalSince(created)
                if age > maxFileAge {
                    expiredFiles.append(file)
                    oldestDeletedAge = max(oldestDeletedAge, age)
                    continue
                }
            }
            validFiles.append(file)
        }

        var deletedCount = 0
        var errCount = 0

        for file in expiredFiles {
            if Self.removeFileQuietly(at: file) {
                deletedCount += 1
            } else {
                errCount += 1
            }
        }

        if validFiles.count > maxPerPayloadFiles {
            let sorted = validFiles.sorted { f1, f2 in
                let d1 = ((try? FileManager.default.attributesOfItem(
                    atPath: f1.path
                ))?[.creationDate] as? Date) ?? .distantPast
                let d2 = ((try? FileManager.default.attributesOfItem(
                    atPath: f2.path
                ))?[.creationDate] as? Date) ?? .distantPast
                return d1 > d2
            }
            let excess = sorted.suffix(
                validFiles.count - maxPerPayloadFiles
            )
            for file in excess {
                if let attrs = try? FileManager.default.attributesOfItem(
                    atPath: file.path
                ),
                    let created = attrs[.creationDate] as? Date {
                    oldestDeletedAge = max(
                        oldestDeletedAge, now.timeIntervalSince(created)
                    )
                }
                if Self.removeFileQuietly(at: file) {
                    deletedCount += 1
                } else {
                    errCount += 1
                }
            }
            validFiles = Array(sorted.prefix(maxPerPayloadFiles))
        }

        if deletedCount > 0 || errCount > 0 {
            let hours = Int(oldestDeletedAge / 3600)
            let result = errCount > 0 ? "err" : "ok"
            await log(
                "⌚️ [CLEANUP] path=retention artifact=watch_log"
                    + " deleted=\(deletedCount)"
                    + " remaining=\(validFiles.count)"
                    + " oldest_age_hours=\(hours)"
                    + " result=\(result)"
            )
        }

        return validFiles
    }

    // MARK: - Resend pending payloads

    func resendPendingPayloads() async {
        guard !WatchStartupTransportGate.snapshot().isSuppressed else { return }
        guard session.isReachable else { return }
        guard prepareSessionForImmediateSend() else {
            await log(
                "⌚️ resend_pending_payloads skipped"
                    + " note=session_not_activated"
            )
            return
        }

        let pendingPayloads = await getPendingPayloads()

        for record in pendingPayloads {
            guard let payloadId = WatchConnectivityPayloadIds.payloadIdString(
                      record["payloadId"]
                  ),
                  let type = record["type"] as? String,
                  type == "watchLogs",
                  let filePath = record["filePath"] as? String
            else { continue }

            let fileURL = URL(fileURLWithPath: filePath)

            guard let data = try? Data(contentsOf: fileURL),
                  let logString = String(data: data, encoding: .utf8),
                  !logString.isEmpty
            else {
                await removePendingPayload(payloadId)
                continue
            }

            let envelope: [String: Any] = [
                "type": "watchLogs",
                "payloadId": payloadId,
                "data": logString
            ]

            await sendMessageAwaitingReply(
                envelope,
                context: "resend payloadId=\(payloadId)"
            ) { reply in
                if let ackType = reply["type"] as? String,
                   ackType == "ack",
                   let ackId = WatchConnectivityPayloadIds.payloadIdString(
                       reply["payloadId"]
                   ),
                   ackId == payloadId {
                    let res = WatchLogger.removeFileTracked(
                        at: fileURL
                    )
                    if res.succeeded {
                        await WatchLogger.shared
                            .removePendingPayload(payloadId)
                    }
                    await WatchLogger.shared
                        .logCleanup(
                            path: "ack_reply", flow: "resend",
                            artifact: "watch_log",
                            payloadId: payloadId,
                            result: res
                        )
                }
            } onError: { error in
                await WatchLogger.shared.log(
                    "⌚️ Failed to resend for \(payloadId): "
                        + error.localizedDescription
                )
            }
        }
    }

    // MARK: - Pending payload storage

    /// Replaces any existing pending row with the same `payloadId` before append, so repeated
    /// failures for one payload cannot multiply list entries (only `createdAtEpoch` refreshes).
    func storePendingPayload(
        payloadId: String, type: String, filePath: String
    ) async {
        var pending = UserDefaults.standard.array(
            forKey: pendingPayloadsKey
        ) as? [[String: Any]] ?? []

        pending.removeAll { $0["payloadId"] as? String == payloadId }

        let record: [String: Any] = [
            "payloadId": payloadId,
            "type": type,
            "filePath": filePath,
            "createdAtEpoch": Date().timeIntervalSince1970
        ]
        pending.append(record)

        let now = Date().timeIntervalSince1970
        pending = pending.filter { rec in
            if let t = rec["createdAtEpoch"] as? TimeInterval {
                return (now - t) < maxFileAge
            }
            return true
        }

        UserDefaults.standard.set(pending, forKey: pendingPayloadsKey)
    }

    func removePendingPayload(_ payloadId: String) async {
        var pending = UserDefaults.standard.array(
            forKey: pendingPayloadsKey
        ) as? [[String: Any]] ?? []
        pending.removeAll { $0["payloadId"] as? String == payloadId }
        UserDefaults.standard.set(pending, forKey: pendingPayloadsKey)
    }

    func getPendingPayloads() async -> [[String: Any]] {
        UserDefaults.standard.array(
            forKey: pendingPayloadsKey
        ) as? [[String: Any]] ?? []
    }

    // MARK: - Drain File Cleanup

    /// Deletes drain files and pending payload records for the given
    /// payloadIds. Idempotent: tolerates missing files, duplicate calls,
    /// and overlap between batchAck and watchLogConfirm.
    /// Emits per-artifact-type [CLEANUP] events.
    func deleteFilesForPayloadIds(_ ids: [String]) async {
        let pendingPayloads = await getPendingPayloads()
        let pendingByPayloadId = Dictionary(
            pendingPayloads.compactMap { rec -> (String, String)? in
                guard let pid = WatchConnectivityPayloadIds.payloadIdString(
                          rec["payloadId"]
                      ),
                      let path = rec["filePath"] as? String
                else { return nil }
                return (pid, path)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let logsDir = ComplicationLogBuffer.sharedContainerURL()?
            .appendingPathComponent("logs", isDirectory: true)

        var watchLogOk = 0, watchLogErr = 0
        var pendingRecordCount = 0
        var drainOk = 0, drainErr = 0

        for id in ids {
            var watchLogFailed = false
            if let filePath = pendingByPayloadId[id] {
                let res = Self.removeFileTracked(atPath: filePath)
                if res.succeeded {
                    watchLogOk += 1
                } else {
                    watchLogErr += 1
                    watchLogFailed = true
                }
            }

            if !watchLogFailed {
                await removePendingPayload(id)
                pendingRecordCount += 1
            }

            if let logsDir {
                let drainFile = logsDir.appendingPathComponent(
                    "complication_log.drain.\(id).txt"
                )
                let res = Self.removeFileTracked(at: drainFile)
                if res.succeeded { drainOk += 1 }
                else { drainErr += 1 }
            }
        }

        // C-209-3: routine confirm cleanups (≈2.9k lines/40h across three sites) fold into the
        // flush summary; only failures emit lines.
        pipelineConfirmFiles += watchLogOk + pendingRecordCount + drainOk
        if watchLogErr > 0 {
            let sampleIds = ids.prefix(3).joined(separator: "|")
            await log(
                "⌚️ [CLEANUP] path=confirm artifact=watch_log"
                    + " count=\(watchLogOk + watchLogErr)"
                    + " sample_ids=\(sampleIds)"
                    + " result=err"
            )
        }
        if drainErr > 0 {
            await log(
                "⌚️ [CLEANUP] path=confirm artifact=drain"
                    + " count=\(drainOk + drainErr)"
                    + " result=err"
            )
        }
    }

    // MARK: - Complication Log Drain

    private func drainComplicationLogs() async {
        guard let containerURL = ComplicationLogBuffer
            .sharedContainerURL() else { return }

        let logsDir = containerURL.appendingPathComponent(
            "logs", isDirectory: true
        )
        let fileManager = FileManager.default

        guard let allFiles = try? fileManager.contentsOfDirectory(
            at: logsDir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        var drainFiles = allFiles
            .filter {
                $0.lastPathComponent.hasPrefix("complication_log.drain.")
                    && $0.lastPathComponent.hasSuffix(".txt")
            }
            .sorted { url1, url2 in
                let d1 = (try? url1.resourceValues(
                    forKeys: [.creationDateKey]
                ).creationDate) ?? .distantPast
                let d2 = (try? url2.resourceValues(
                    forKeys: [.creationDateKey]
                ).creationDate) ?? .distantPast
                return d1 < d2
            }

        drainFiles = await applyDrainRetention(
            drainFiles: drainFiles
        )

        for drainFile in drainFiles {
            await sendLogContentFromFile(fileURL: drainFile)
        }

        let logFile = logsDir.appendingPathComponent("complication_log.txt")
        guard fileManager.fileExists(atPath: logFile.path) else { return }

        let drainURL = logsDir.appendingPathComponent(
            "complication_log.drain.\(UUID().uuidString).txt"
        )
        do {
            try fileManager.moveItem(at: logFile, to: drainURL)
        } catch {
            return
        }

        await sendLogContentFromFile(fileURL: drainURL)
    }

    /// Deletes drain files exceeding maxFileAge or maxPerPayloadFiles,
    /// emits [CLEANUP] retention summary. Returns surviving files.
    private func applyDrainRetention(
        drainFiles: [URL]
    ) async -> [URL] {
        let now = Date()
        var deletedCount = 0
        var errCount = 0
        var oldestDeletedAge: TimeInterval = 0

        var remaining = drainFiles.filter { file in
            guard let created = (try? file.resourceValues(
                forKeys: [.creationDateKey]
            ).creationDate),
                now.timeIntervalSince(created) > maxFileAge
            else { return true }

            let age = now.timeIntervalSince(created)
            oldestDeletedAge = max(oldestDeletedAge, age)
            if Self.removeFileQuietly(at: file) {
                deletedCount += 1
            } else {
                errCount += 1
            }
            return false
        }

        if remaining.count > maxPerPayloadFiles {
            let excess = remaining.prefix(
                remaining.count - maxPerPayloadFiles
            )
            for file in excess {
                if let created = (try? file.resourceValues(
                    forKeys: [.creationDateKey]
                ).creationDate) {
                    oldestDeletedAge = max(
                        oldestDeletedAge, now.timeIntervalSince(created)
                    )
                }
                if Self.removeFileQuietly(at: file) {
                    deletedCount += 1
                } else {
                    errCount += 1
                }
            }
            remaining = Array(remaining.suffix(maxPerPayloadFiles))
        }

        if deletedCount > 0 || errCount > 0 {
            let hours = Int(oldestDeletedAge / 3600)
            let result = errCount > 0 ? "err" : "ok"
            await log(
                "⌚️ [CLEANUP] path=retention artifact=drain"
                    + " deleted=\(deletedCount)"
                    + " remaining=\(remaining.count)"
                    + " oldest_age_hours=\(hours)"
                    + " result=\(result)"
            )
        }

        return remaining
    }

    private static func payloadIdFromDrainFile(_ fileURL: URL) -> String {
        let name = fileURL.deletingPathExtension().lastPathComponent
        let prefix = "complication_log.drain."
        if let range = name.range(of: prefix) {
            let candidate = String(name[range.upperBound...])
            if !candidate.isEmpty { return candidate }
        }
        return UUID().uuidString
    }

    private static let drainSizeCap = 64 * 1024

    private func sendLogContentFromFile(fileURL: URL) async {
        guard let data = try? Data(contentsOf: fileURL),
              var content = String(data: data, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines)
                  .isEmpty
        else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        if content.utf8.count > Self.drainSizeCap {
            let rawData = Data(content.utf8)
            let truncData = rawData.prefix(Self.drainSizeCap)
            if let nl = truncData.lastIndex(of: UInt8(ascii: "\n")) {
                content = String(
                    decoding: truncData[...nl], as: UTF8.self
                ) + "[truncated]\n"
            } else {
                content = String(
                    decoding: truncData, as: UTF8.self
                ) + "\n[truncated]\n"
            }
        }

        let payloadId = Self.payloadIdFromDrainFile(fileURL)
        let envelope: [String: Any] = [
            "type": "watchLogs",
            "payloadId": payloadId,
            "data": content
        ]

        let filePath = fileURL.path

        if session.isReachable {
            guard prepareSessionForImmediateSend() else {
                await storePendingPayload(
                    payloadId: payloadId,
                    type: "watchLogs",
                    filePath: filePath
                )
                _ = session.transferUserInfo(envelope)
                await log(
                    "⌚️ Drain logs queued for background delivery"
                        + " (payloadId: \(payloadId))"
                        + " watch_log_files=\(cachedWatchLogFiles)"
                        + " drain_files=\(cachedDrainFiles)"
                        + " note=activation_timeout"
                )
                return
            }

            await storePendingPayload(
                payloadId: payloadId,
                type: "watchLogs",
                filePath: filePath
            )

            await sendMessageAwaitingReply(
                envelope,
                context: "drain payloadId=\(payloadId)"
            ) { reply in
                if let ackType = reply["type"] as? String,
                   ackType == "ack",
                   let ackId = WatchConnectivityPayloadIds.payloadIdString(
                       reply["payloadId"]
                   ),
                   ackId == payloadId {
                    let res = WatchLogger.removeFileTracked(
                        at: fileURL
                    )
                    if res.succeeded {
                        await WatchLogger.shared
                            .removePendingPayload(payloadId)
                    }
                    await WatchLogger.shared
                        .logCleanup(
                            path: "ack_reply", flow: "drain",
                            artifact: "drain",
                            payloadId: payloadId,
                            result: res
                        )
                }
            } onError: { error in
                await WatchLogger.shared.log(
                    "⌚️ Failed to send drain logs"
                        + " (payloadId: \(payloadId)): "
                        + error.localizedDescription
                )
                await WatchLogger.shared.storePendingPayload(
                    payloadId: payloadId,
                    type: "watchLogs",
                    filePath: filePath
                )
            }
        } else {
            _ = session.transferUserInfo(envelope)
            await storePendingPayload(
                payloadId: payloadId,
                type: "watchLogs",
                filePath: filePath
            )
        }
    }

    // MARK: - Cleanup log helper

    /// Formats and emits a [CLEANUP] line for ack_reply paths.
    private func logCleanup(
        path: String, flow: String, artifact: String,
        payloadId: String, result res: RemoveResult
    ) async {
        // C-209-3: successful cleanups are counted into the flush summary — this single site
        // emitted 12.2k lines in 40h (61% of all watch log volume). Failures keep the full line.
        if let err = res.error {
            var msg = "⌚️ [CLEANUP] path=\(path) flow=\(flow)"
            msg += " artifact=\(artifact)"
            msg += " payloadId=\(payloadId)"
            msg += " outcome=\(res.outcome)"
            msg += " result=err error=\(err)"
            await log(msg)
        } else {
            pipelineCleanupOk += 1
        }
    }

    // MARK: - Observability (E2, E3)

    /// E3: Recompute cached file counts if stale (10s TTL).
    private func updateCachedCountsIfStale() {
        let now = Date()
        guard now.timeIntervalSince(cachedCountsTimestamp) >= 10
        else { return }

        let fileManager = FileManager.default
        let logDir = fileManager.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first?.appendingPathComponent("logs", isDirectory: true)

        if let logDir, let files = try? fileManager.contentsOfDirectory(
            at: logDir, includingPropertiesForKeys: nil
        ) {
            cachedWatchLogFiles = files.filter {
                $0.lastPathComponent.hasPrefix("watch_log_")
                    && $0.lastPathComponent.hasSuffix(".txt")
                    && $0.lastPathComponent != "watch_log_daily.txt"
            }.count
        }

        if let containerURL = ComplicationLogBuffer
            .sharedContainerURL() {
            let drainsDir = containerURL.appendingPathComponent(
                "logs", isDirectory: true
            )
            if let files = try? fileManager.contentsOfDirectory(
                at: drainsDir, includingPropertiesForKeys: nil
            ) {
                cachedDrainFiles = files.filter {
                    $0.lastPathComponent
                        .hasPrefix("complication_log.drain.")
                        && $0.lastPathComponent.hasSuffix(".txt")
                }.count
            }
        }

        cachedCountsTimestamp = now
    }

    /// E2: Best-effort daily inventory of log files and pending payloads.
    private func logFileInventory() async {
        // C-209-3: process-local guard added — the persisted 24h gate demonstrably failed
        // across watch process churn (1.5k [INVENTORY] lines in 40h on build 208). Worst case
        // is now one line per process launch; live counts ride `log_pipeline_summary`.
        guard !didLogInventoryThisProcess else { return }
        didLogInventoryThisProcess = true
        let lastInventory = UserDefaults.standard.double(
            forKey: lastInventoryKey
        )
        let now = Date().timeIntervalSince1970
        guard (now - lastInventory) >= 24 * 60 * 60 else { return }

        let fileManager = FileManager.default
        var watchLogsCount = 0
        var watchLogsBytes: UInt64 = 0
        var drainsCount = 0
        var drainsBytes: UInt64 = 0

        let logDir = fileManager.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first?.appendingPathComponent("logs", isDirectory: true)

        if let logDir, let files = try? fileManager.contentsOfDirectory(
            at: logDir, includingPropertiesForKeys: [.fileSizeKey]
        ) {
            for file in files
                where file.lastPathComponent.hasPrefix("watch_log_")
                && file.lastPathComponent.hasSuffix(".txt")
                && file.lastPathComponent != "watch_log_daily.txt" {
                watchLogsCount += 1
                if let attrs = try? fileManager.attributesOfItem(
                    atPath: file.path
                ),
                    let size = attrs[.size] as? UInt64 {
                    watchLogsBytes += size
                }
            }
        }

        if let containerURL = ComplicationLogBuffer
            .sharedContainerURL() {
            let drainsDir = containerURL.appendingPathComponent(
                "logs", isDirectory: true
            )
            if let files = try? fileManager.contentsOfDirectory(
                at: drainsDir, includingPropertiesForKeys: [.fileSizeKey]
            ) {
                for file in files
                    where file.lastPathComponent
                    .hasPrefix("complication_log.drain.")
                    && file.lastPathComponent.hasSuffix(".txt") {
                    drainsCount += 1
                    if let attrs = try? fileManager.attributesOfItem(
                        atPath: file.path
                    ),
                        let size = attrs[.size] as? UInt64 {
                        drainsBytes += size
                    }
                }
            }
        }

        let pendingCount = (UserDefaults.standard.array(
            forKey: pendingPayloadsKey
        ) as? [[String: Any]])?.count ?? 0

        await log(
            "⌚️ [INVENTORY]"
                + " watch_logs_count=\(watchLogsCount)"
                + " watch_logs_bytes=\(watchLogsBytes)"
                + " drains_count=\(drainsCount)"
                + " drains_bytes=\(drainsBytes)"
                + " pending_count=\(pendingCount)"
        )

        UserDefaults.standard.set(now, forKey: lastInventoryKey)
    }
}
