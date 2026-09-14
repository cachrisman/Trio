import Foundation
import WatchConnectivity

actor WatchLogger {
    static let shared = WatchLogger()

    private var logs: [String] = []
    private let maxEntries = 500
    private let flushInterval: TimeInterval = 3 * 60
    private let flushSizeThreshold = 100
    private var lastFlush = Date()

    // Size caps
    private let logSizeCap = 16 * 1024 // 16 KB
    private let maxPerPayloadFiles = 20
    private let maxFileAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days

    private let session = WCSession.default
    private var timerTask: Task<Void, Never>?

    private let pendingPayloadsKey = "watchLoggerPendingPayloads"

    private init() {
        Task {
            await startFlushTimer()
        }
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }

    private func startFlushTimer() async {
        timerTask = Task {
            while true {
                try? await Task.sleep(nanoseconds: UInt64(flushInterval * 1_000_000_000))
                await flushIfNeeded(force: false)
            }
        }
    }

    func log(
        _ message: String,
        force: Bool = false,
        function: String = #function,
        file: String = #fileID,
        line: Int = #line
    ) async {
        let shortFile = (file as NSString).lastPathComponent
        let timestamp = dateFormatter.string(from: Date())
        let entry = "[\(timestamp)] [\(shortFile):\(line)] \(function) → \(message)"

        logs.append(entry)
        if logs.count > maxEntries {
            logs.removeFirst(logs.count - maxEntries)
        }

        print(entry)

        // Also append to daily log for local debugging
        await appendToDailyLog(entry)

        await flushIfNeeded(force: force)
    }

    /// Appends text to the daily local debug log (never sent to phone).
    func appendToDailyLog(_ text: String) async {
        let logDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("logs", isDirectory: true)

        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

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

    func flushIfNeeded(force: Bool = false) async {
        let now = Date()
        let shouldFlush = force || now.timeIntervalSince(lastFlush) >= flushInterval || logs.count >= flushSizeThreshold

        if shouldFlush {
            await flushToPhone()
        }
    }

    private func flushToPhone() async {
        guard !logs.isEmpty else {
            return
        }

        // Capture logsToSend BEFORE sending
        var logsToSend = logs.joined(separator: "\n")

        // Truncate to size cap
        if logsToSend.utf8.count > logSizeCap {
            let cappedData = logsToSend.data(using: .utf8)?.prefix(logSizeCap) ?? Data()
            logsToSend = String(data: cappedData, encoding: .utf8) ?? String(logsToSend.prefix(logSizeCap))
        }

        // Generate payloadId
        let payloadId = UUID().uuidString

        // Write to per-payload file BEFORE sending
        let logDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let perPayloadFile = logDir.appendingPathComponent("watch_log_\(payloadId).txt")
        if let data = logsToSend.data(using: .utf8) {
            try? data.write(to: perPayloadFile)
        }

        // Clear in-memory logs ONLY after file write
        logs.removeAll()
        lastFlush = Date()

        // Create envelope
        let envelope: [String: Any] = [
            "type": "watchLogs",
            "payloadId": payloadId,
            "data": logsToSend
        ]

        // Do NOT activate session - WatchState owns activation
        if session.isReachable && session.activationState == .activated {
            // Use sendMessage with replyHandler for immediate ACK
            let filePath = perPayloadFile.path
            session.sendMessage(
                envelope,
                replyHandler: { reply in
                    Task {
                        // Check if ACK received
                        if let ackType = reply["type"] as? String,
                           ackType == "ack",
                           let ackPayloadId = reply["payloadId"] as? String,
                           ackPayloadId == payloadId {
                            // ACK received - delete file
                            try? FileManager.default.removeItem(at: perPayloadFile)
                            await WatchLogger.shared.removePendingPayload(payloadId)
                            await WatchLogger.shared.log("⌚️ Logs ACK received from phone for payloadId: \(payloadId)")
                        }
                    }
                },
                errorHandler: { error in
                    Task {
                        await WatchLogger.shared.log("⌚️ Failed to send logs to phone: \(error.localizedDescription)")
                        // Keep file, mark as pending for retry
                        await WatchLogger.shared.storePendingPayload(payloadId: payloadId, type: "watchLogs", filePath: filePath)
                    }
                }
            )
        } else {
            // Not reachable - persist locally and mark as pending
            await storePendingPayload(payloadId: payloadId, type: "watchLogs", filePath: perPayloadFile.path)
            // Optionally use transferUserInfo for background delivery
            _ = session.transferUserInfo(envelope)
            await log("⌚️ Logs queued for background delivery to phone (payloadId: \(payloadId))")
        }
    }

    func flushPersistedLogs() async {
        let logDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("logs", isDirectory: true)

        // Scan for per-payload log files
        guard let files = try? FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]) else {
            return
        }

        let perPayloadFiles = files.filter { file in
            file.lastPathComponent.hasPrefix("watch_log_") &&
            file.lastPathComponent.hasSuffix(".txt") &&
            file.lastPathComponent != "watch_log_daily.txt"
        }

        // Apply retention caps
        let now = Date()
        var validFiles: [URL] = []
        var filesToDelete: [URL] = []

        for file in perPayloadFiles {
            // Check age
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
               let creationDate = attributes[.creationDate] as? Date {
                let age = now.timeIntervalSince(creationDate)
                if age > maxFileAge {
                    filesToDelete.append(file)
                    continue
                }
            }
            validFiles.append(file)
        }

        // Delete old files
        for file in filesToDelete {
            try? FileManager.default.removeItem(at: file)
        }

        // Enforce max files (keep most recent)
        if validFiles.count > maxPerPayloadFiles {
            // Sort by creation date, keep most recent
            let sortedFiles = validFiles.sorted { file1, file2 in
                let date1 = ((try? FileManager.default.attributesOfItem(atPath: file1.path))?[.creationDate] as? Date) ?? Date.distantPast
                let date2 = ((try? FileManager.default.attributesOfItem(atPath: file2.path))?[.creationDate] as? Date) ?? Date.distantPast
                return date1 > date2
            }
            let filesToRemove = sortedFiles.suffix(validFiles.count - maxPerPayloadFiles)
            for file in filesToRemove {
                try? FileManager.default.removeItem(at: file)
            }
            validFiles = Array(sortedFiles.prefix(maxPerPayloadFiles))
        }

        // If reachable, query ACKs first, then resend remaining files
        if session.isReachable && session.activationState == .activated {
            // 1. Query ACKs for pending payloads
            let pendingPayloads = await getPendingPayloads()
            let pendingIds = pendingPayloads.compactMap { $0["payloadId"] as? String }

            if !pendingIds.isEmpty {
                let queryEnvelope: [String: Any] = [
                    "type": "queryAcks",
                    "pendingIds": pendingIds
                ]

                session.sendMessage(
                    queryEnvelope,
                    replyHandler: { reply in
                        Task {
                            // Handle batchAck response
                            if let batchAckType = reply["type"] as? String,
                               batchAckType == "batchAck",
                               let ackIds = reply["ackIds"] as? [String] {
                                // Delete acknowledged files
                                for ackId in ackIds {
                                    let filePath = logDir.appendingPathComponent("watch_log_\(ackId).txt")
                                    try? FileManager.default.removeItem(at: filePath)
                                    await WatchLogger.shared.removePendingPayload(ackId)
                                }
                                // Resend remaining files
                                await WatchLogger.shared.resendPendingPayloads()
                            }
                        }
                    },
                    errorHandler: { error in
                        Task {
                            await WatchLogger.shared.log("⌚️ Failed to query ACKs: \(error.localizedDescription)")
                            // Still try to resend
                            await WatchLogger.shared.resendPendingPayloads()
                        }
                    }
                )
            } else {
                // No pending payloads, just resend any remaining files
                await resendPendingPayloads()
            }
        } else {
            // Not reachable - do NOT delete files, optionally use transferUserInfo
            // Files will be resent when reachable
        }
    }

    /// Resends pending payload files using sendMessage (not transferUserInfo) when reachable.
    func resendPendingPayloads() async {
        guard session.isReachable && session.activationState == .activated else {
            return
        }

        // Get pending payloads
        let pendingPayloads = await getPendingPayloads()

        for pendingRecord in pendingPayloads {
            guard let payloadId = pendingRecord["payloadId"] as? String,
                  let type = pendingRecord["type"] as? String,
                  type == "watchLogs",
                  let filePath = pendingRecord["filePath"] as? String else {
                continue
            }

            let fileURL = URL(fileURLWithPath: filePath)

            // Read file
            guard let data = try? Data(contentsOf: fileURL),
                  let logString = String(data: data, encoding: .utf8),
                  !logString.isEmpty else {
                // File doesn't exist or is empty - remove from pending
                await removePendingPayload(payloadId)
                continue
            }

            // Create envelope
            let envelope: [String: Any] = [
                "type": "watchLogs",
                "payloadId": payloadId,
                "data": logString
            ]

            // Resend using sendMessage (not transferUserInfo) to get immediate ACK
            session.sendMessage(
                envelope,
                replyHandler: { reply in
                    Task {
                        // Check if ACK received
                        if let ackType = reply["type"] as? String,
                           ackType == "ack",
                           let ackPayloadId = reply["payloadId"] as? String,
                           ackPayloadId == payloadId {
                            // ACK received - delete file
                            try? FileManager.default.removeItem(at: fileURL)
                            await WatchLogger.shared.removePendingPayload(payloadId)
                            await WatchLogger.shared.log("⌚️ Resent logs ACK received for payloadId: \(payloadId)")
                        }
                    }
                },
                errorHandler: { error in
                    Task {
                        await WatchLogger.shared.log("⌚️ Failed to resend logs for payloadId \(payloadId): \(error.localizedDescription)")
                        // Keep file for next retry
                    }
                }
            )
        }
    }

    /// Stores a pending payload record for later ACK matching.
    func storePendingPayload(payloadId: String, type: String, filePath: String) async {
        var pendingPayloads = UserDefaults.standard.array(forKey: pendingPayloadsKey) as? [[String: Any]] ?? []

        let record: [String: Any] = [
            "payloadId": payloadId,
            "type": type,
            "filePath": filePath,
            "createdAtEpoch": Date().timeIntervalSince1970
        ]

        pendingPayloads.append(record)

        // Clean up old records (older than 7 days)
        let now = Date().timeIntervalSince1970
        pendingPayloads = pendingPayloads.filter { record in
            if let createdAt = record["createdAtEpoch"] as? TimeInterval {
                return (now - createdAt) < (7 * 24 * 60 * 60)
            }
            return true
        }

        UserDefaults.standard.set(pendingPayloads, forKey: pendingPayloadsKey)
    }

    /// Removes a pending payload record after ACK.
    func removePendingPayload(_ payloadId: String) async {
        var pendingPayloads = UserDefaults.standard.array(forKey: pendingPayloadsKey) as? [[String: Any]] ?? []
        pendingPayloads.removeAll { record in
            record["payloadId"] as? String == payloadId
        }
        UserDefaults.standard.set(pendingPayloads, forKey: pendingPayloadsKey)
    }

    /// Gets all pending payload records.
    func getPendingPayloads() async -> [[String: Any]] {
        return UserDefaults.standard.array(forKey: pendingPayloadsKey) as? [[String: Any]] ?? []
    }
}
