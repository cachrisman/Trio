import Foundation
import WatchConnectivity

actor WatchLogger {
    static let shared = WatchLogger()

    private let build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    private var logs: [String] = []
    private let maxEntries = 500
    private let flushInterval: TimeInterval = 3 * 60
    private let flushSizeThreshold = 100
    private var lastFlush = Date()

    // Size caps
    private let logSizeCap = 16 * 1024 // 16 KB
    private let maxPerPayloadFiles = 10
    private let maxFileAge: TimeInterval = 48 * 60 * 60 // 48 hours

    private let session = WCSession.default
    private var timerTask: Task<Void, Never>?

    private let pendingPayloadsKey = "watchLoggerPendingPayloads"
    private let lastKnownBuildKey = "watchLogger.lastKnownBuild"
    private let lastInventoryKey = "WatchLogger.lastInventoryTimestamp"

    // E3: Inline metrics cache (10s TTL)
    private var cachedWatchLogFiles: Int = 0
    private var cachedDrainFiles: Int = 0
    private var cachedCountsTimestamp: Date = .distantPast

    private init() {
        Task {
            await startFlushTimer()
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
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

    // MARK: - Timer

    private func startFlushTimer() async {
        timerTask = Task {
            while true {
                try? await Task.sleep(nanoseconds: UInt64(flushInterval * 1_000_000_000))
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
        let entry = "[\(timestamp)] [b:\(build)] [\(shortFile):\(line)] \(function) → \(message)"

        logs.append(entry)
        if logs.count > maxEntries {
            logs.removeFirst(logs.count - maxEntries)
        }

        print(entry)

        await appendToDailyLog(entry)

        await flushIfNeeded(force: force)
    }

    /// Appends text to the daily local debug log (never sent to phone).
    func appendToDailyLog(_ text: String) async {
        let logDir = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("logs", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: logDir, withIntermediateDirectories: true
        )

        let dailyLogFile = logDir.appendingPathComponent("watch_log_daily.txt")
        let logEntry = text + "\n"

        if let data = logEntry.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: dailyLogFile) {
                _ = try? handle.seekToEnd()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: dailyLogFile)
            }
        }
    }

    // MARK: - Flush

    func flushIfNeeded(force: Bool = false) async {
        let now = Date()
        let shouldFlush = force
            || now.timeIntervalSince(lastFlush) >= flushInterval
            || logs.count >= flushSizeThreshold

        if shouldFlush {
            await flushToPhone()
        }
    }

    private func flushToPhone() async {
        guard !logs.isEmpty else { return }

        updateCachedCountsIfStale()
        await logFileInventory()

        var logsToSend = logs.joined(separator: "\n")

        // logSizeCap (16KB) limits in-memory flush payloads sent via WCSession.
        // Per-payload drain files can be up to 64KB (maxDrainFileSize).
        let originalUTF8Count = logsToSend.utf8.count
        let lineCount = logs.count

        if originalUTF8Count > logSizeCap {
            let marker = "⚠️ log_flush_truncated cap_bytes=\(logSizeCap) original_bytes=\(originalUTF8Count) lines_total=\(lineCount)"
            let markerBytes = marker.utf8.count + 1
            let contentCap = max(0, logSizeCap - markerBytes)

            let cappedData = logsToSend.data(using: .utf8)?.prefix(contentCap)
                ?? Data()
            let truncatedContent = String(data: cappedData, encoding: .utf8)
                ?? String(logsToSend.prefix(contentCap))

            logsToSend = marker + "\n" + truncatedContent
        }

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
        if let data = logsToSend.data(using: .utf8) {
            try? data.write(to: perPayloadFile)
        }

        logs.removeAll()
        lastFlush = Date()

        let envelope: [String: Any] = [
            "type": "watchLogs",
            "payloadId": payloadId,
            "data": logsToSend
        ]

        if session.isReachable && session.activationState == .activated {
            let filePath = perPayloadFile.path
            await storePendingPayload(
                payloadId: payloadId,
                type: "watchLogs",
                filePath: filePath
            )
            session.sendMessage(
                envelope,
                replyHandler: { reply in
                    Task {
                        if let ackType = reply["type"] as? String,
                           ackType == "ack",
                           let ackId = reply["payloadId"] as? String,
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
                    }
                },
                errorHandler: { error in
                    Task {
                        await WatchLogger.shared.log(
                            "⌚️ Failed to send logs: "
                                + error.localizedDescription
                        )
                    }
                }
            )
        } else {
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
            )
        }
    }

    // MARK: - Persisted log flush + retention

    func flushPersistedLogs() async {
        let lastKnownBuild = UserDefaults.standard.string(
            forKey: lastKnownBuildKey
        )
        if lastKnownBuild != build {
            UserDefaults.standard.set(build, forKey: lastKnownBuildKey)
            await log(
                "[UPGRADE] build changed"
                    + " from \(lastKnownBuild ?? "nil") to \(build)",
                force: true
            )
        }

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

        guard session.isReachable,
              session.activationState == .activated else { return }

        let pendingPayloads = await getPendingPayloads()
        let pendingIds = pendingPayloads.compactMap {
            $0["payloadId"] as? String
        }

        if !pendingIds.isEmpty {
            let queryEnvelope: [String: Any] = [
                "type": "queryAcks",
                "pendingIds": pendingIds
            ]
            session.sendMessage(
                queryEnvelope,
                replyHandler: { reply in
                    Task {
                        if let t = reply["type"] as? String,
                           t == "batchAck",
                           let ackIds = reply["ackIds"] as? [String] {
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
                            if !ackIds.isEmpty {
                                let result = errCount > 0 ? "err" : "ok"
                                await WatchLogger.shared.log(
                                    "⌚️ [CLEANUP] path=query_acks"
                                        + " artifact=watch_log"
                                        + " count=\(ackIds.count)"
                                        + " result=\(result)"
                                )
                            }
                            await WatchLogger.shared
                                .resendPendingPayloads()
                        }
                    }
                },
                errorHandler: { error in
                    Task {
                        await WatchLogger.shared.log(
                            "⌚️ Failed to query ACKs: "
                                + error.localizedDescription
                        )
                        await WatchLogger.shared.resendPendingPayloads()
                    }
                }
            )
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
        guard session.isReachable,
              session.activationState == .activated else { return }

        let pendingPayloads = await getPendingPayloads()

        for record in pendingPayloads {
            guard let payloadId = record["payloadId"] as? String,
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

            session.sendMessage(
                envelope,
                replyHandler: { reply in
                    Task {
                        if let ackType = reply["type"] as? String,
                           ackType == "ack",
                           let ackId = reply["payloadId"] as? String,
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
                    }
                },
                errorHandler: { error in
                    Task {
                        await WatchLogger.shared.log(
                            "⌚️ Failed to resend for \(payloadId): "
                                + error.localizedDescription
                        )
                    }
                }
            )
        }
    }

    // MARK: - Pending payload storage

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
                guard let pid = rec["payloadId"] as? String,
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

        let sampleIds = ids.prefix(3).joined(separator: "|")
        if watchLogOk + watchLogErr > 0 {
            let result = watchLogErr > 0 ? "err" : "ok"
            await log(
                "⌚️ [CLEANUP] path=confirm artifact=watch_log"
                    + " count=\(watchLogOk + watchLogErr)"
                    + " sample_ids=\(sampleIds)"
                    + " result=\(result)"
            )
        }
        if pendingRecordCount > 0 {
            await log(
                "⌚️ [CLEANUP] path=confirm"
                    + " artifact=pending_record"
                    + " count=\(pendingRecordCount) result=ok"
            )
        }
        if drainOk + drainErr > 0 {
            let result = drainErr > 0 ? "err" : "ok"
            await log(
                "⌚️ [CLEANUP] path=confirm artifact=drain"
                    + " count=\(drainOk + drainErr)"
                    + " result=\(result)"
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
        guard session.activationState == .activated else { return }

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
            session.sendMessage(
                envelope,
                replyHandler: { reply in
                    Task {
                        if let ackType = reply["type"] as? String,
                           ackType == "ack",
                           let ackId = reply["payloadId"] as? String,
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
                    }
                },
                errorHandler: { _ in
                    Task {
                        await WatchLogger.shared.storePendingPayload(
                            payloadId: payloadId,
                            type: "watchLogs",
                            filePath: filePath
                        )
                    }
                }
            )
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
        var msg = "⌚️ [CLEANUP] path=\(path) flow=\(flow)"
        msg += " artifact=\(artifact)"
        msg += " payloadId=\(payloadId)"
        msg += " outcome=\(res.outcome)"
        if let err = res.error {
            msg += " result=err error=\(err)"
        } else {
            msg += " result=ok"
        }
        await log(msg)
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
