#if os(iOS)
import Foundation
import Swinject
import UIKit

private enum CloudLogPlatform: String {
    case ios
    case watchos
}

private struct CloudLogFileDescriptor {
    let path: String
    let platform: CloudLogPlatform
}

private struct ParsedLogLine {
    let message: String
    let timestamp: String?
    let level: String?
    let category: String?
    let platform: CloudLogPlatform
}

private struct CloudLogPayload: Encodable {
    let dt: String?
    let level: String?
    let message: String
    let platform: String
    let category: String?
    let env: String?
    let appVersion: String?
    let build: String?
    let correlationId: String?
}

private struct CloudLoggingConfiguration {
    let isEnabled: Bool
    let endpoint: URL
    let token: String
    let environment: String

    static func load() -> CloudLoggingConfiguration? {
        guard let info = Bundle.main.infoDictionary else { return nil }

        let enabledString = info["CloudLoggingEnabled"] as? String ?? "NO"
        let isEnabled = enabledString.uppercased() == "YES"

        guard isEnabled,
              let endpointString = info["CloudLoggingEndpoint"] as? String,
              let endpoint = URL(string: endpointString),
              let token = info["CloudLoggingToken"] as? String,
              !token.isEmpty
        else {
            return nil
        }

        let environmentString = info["CloudLoggingEnv"] as? String
        let environment = (environmentString?.isEmpty == false) ? (environmentString ?? "dev") : "dev"

        return CloudLoggingConfiguration(
            isEnabled: isEnabled,
            endpoint: endpoint,
            token: token,
            environment: environment
        )
    }
}

private final class CloudLogProvider {
    private let configuration: CloudLoggingConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder

    init(configuration: CloudLoggingConfiguration) {
        self.configuration = configuration
        session = URLSession(configuration: .ephemeral)
        encoder = JSONEncoder()
    }

    func upload(events: [ParsedLogLine], appVersion: String?, build: String?) async throws {
        guard !events.isEmpty else { return }

        var batches: [[ParsedLogLine]] = []
        let chunkSize = 50
        var index = 0
        while index < events.count {
            let end = min(events.count, index + chunkSize)
            batches.append(Array(events[index ..< end]))
            index = end
        }

        for batch in batches {
            let payload = batch.map { line in
                CloudLogPayload(
                    dt: line.timestamp,
                    level: line.level,
                    message: line.message,
                    platform: line.platform.rawValue,
                    category: line.category,
                    env: configuration.environment,
                    appVersion: appVersion,
                    build: build,
                    correlationId: nil
                )
            }

            var request = URLRequest(url: configuration.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try encoder.encode(payload)

            _ = try await session.data(for: request)
        }
    }
}

final class CloudLogUploader: Injectable {
    @Injected var watchManager: WatchManager!

    private let configuration: CloudLoggingConfiguration?
    private let provider: CloudLogProvider?
    private let queue = DispatchQueue(label: "CloudLogUploader.queue")
    private var timer: DispatchSourceTimer?
    private let offsetsKey = "CloudLogUploader.offsets.v1"
    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private let isoFormatter: ISO8601DateFormatter

    private var retryDelay: TimeInterval = 5
    private var nextAllowedUpload: Date = .distantPast

    init(resolver: Resolver) {
        configuration = CloudLoggingConfiguration.load()
        provider = configuration.map { CloudLogProvider(configuration: $0) }
        isoFormatter = ISO8601DateFormatter()
        injectServices(resolver)
    }

    func start() {
        guard configuration?.isEnabled == true else { return }

        registerNotifications()
        scheduleTimer()
        uploadNow()
    }

    func uploadNow() {
        guard configuration?.isEnabled == true else { return }
        queue.async { [weak self] in
            guard let self else { return }
            Task { await self.processUpload(reason: "manual") }
        }
    }

    func requestWatchLogSnapshot() {
        watchManager.requestWatchLogSnapshot()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        timer?.cancel()
    }
}

private extension CloudLogUploader {
    func registerNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    func scheduleTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 300, repeating: 300)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.processUpload(reason: "timer") }
        }
        timer.resume()
        self.timer = timer
    }

    @objc func handleForeground() {
        queue.async { [weak self] in
            guard let self else { return }
            Task { await self.processUpload(reason: "foreground") }
        }
    }

    @objc func handleBackground() {
        queue.async { [weak self] in
            guard let self else { return }
            Task { await self.processUpload(reason: "background") }
        }
    }

    func processUpload(reason _: String) async {
        guard Date() >= nextAllowedUpload else { return }
        guard let provider else { return }

        var offsets = loadOffsets()
        var newOffsets = offsets
        var events: [ParsedLogLine] = []

        for descriptor in logFiles where fileManager.fileExists(atPath: descriptor.path) {
            let offset = offsets[descriptor.path] ?? 0
            let readResult = readLines(from: descriptor.path, startingAt: offset)
            guard let result = readResult, !result.lines.isEmpty else {
                continue
            }

            let parsed = result.lines.compactMap { parse(line: $0, platform: descriptor.platform) }
            events.append(contentsOf: parsed)
            newOffsets[descriptor.path] = result.nextOffset
        }

        guard !events.isEmpty else { return }

        do {
            try await provider.upload(
                events: events,
                appVersion: Bundle.main.appDevVersion,
                build: Bundle.main.buildVersionNumber
            )
            saveOffsets(newOffsets)
            resetBackoff()
        } catch {
            debug(.storage, "❌ Cloud log upload failed: \(error)")
            applyBackoff()
        }
    }

    var logFiles: [CloudLogFileDescriptor] {
        [
            CloudLogFileDescriptor(path: SimpleLogReporter.logFile, platform: .ios),
            CloudLogFileDescriptor(path: SimpleLogReporter.logFilePrev, platform: .ios),
            CloudLogFileDescriptor(path: SimpleLogReporter.watchLogFile, platform: .watchos),
            CloudLogFileDescriptor(path: SimpleLogReporter.watchLogFilePrev, platform: .watchos)
        ]
    }

    func loadOffsets() -> [String: Int] {
        defaults.dictionary(forKey: offsetsKey) as? [String: Int] ?? [:]
    }

    func saveOffsets(_ offsets: [String: Int]) {
        defaults.setValue(offsets, forKey: offsetsKey)
    }

    func readLines(from path: String, startingAt offset: Int) -> (lines: [String], nextOffset: Int)? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let fileSize = attributes[.size] as? NSNumber
        else { return nil }

        let currentSize = fileSize.intValue
        var startOffset = offset
        if currentSize < offset {
            startOffset = 0
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        do {
            if #available(iOS 13.0, *) {
                try handle.seek(toOffset: UInt64(startOffset))
                let data = try handle.readToEnd() ?? Data()
                let content = String(data: data, encoding: .utf8) ?? ""
                let lines = content.split(whereSeparator: \.isNewline).map { String($0) }
                return (lines, currentSize)
            } else {
                handle.seek(toFileOffset: UInt64(startOffset))
                let data = handle.readDataToEndOfFile()
                let content = String(data: data, encoding: .utf8) ?? ""
                let lines = content.split(whereSeparator: \.isNewline).map { String($0) }
                return (lines, currentSize)
            }
        } catch {
            debug(.storage, "❌ Failed reading log file at offset: \(error)")
            return nil
        }
    }

    func parse(line: String, platform: CloudLogPlatform) -> ParsedLogLine? {
        var remaining = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if remaining.isEmpty { return nil }

        var timestampString: String?
        var category: String?

        if platform == .ios {
            if let firstSpace = remaining.firstIndex(of: " ") {
                let tsCandidate = String(remaining[..<firstSpace])
                timestampString = tsCandidate
                remaining = String(remaining[remaining.index(after: firstSpace)...]).trimmingCharacters(in: .whitespaces)
            }

            if remaining.hasPrefix("["), let end = remaining.firstIndex(of: "]") {
                let categoryRange = remaining.index(after: remaining.startIndex)..<end
                category = String(remaining[categoryRange])
                remaining = String(remaining[remaining.index(after: end)...]).trimmingCharacters(in: .whitespaces)
            }
        } else {
            if remaining.hasPrefix("["), let end = remaining.firstIndex(of: "]") {
                let tsRange = remaining.index(after: remaining.startIndex)..<end
                timestampString = String(remaining[tsRange])
                remaining = String(remaining[remaining.index(after: end)...]).trimmingCharacters(in: .whitespaces)
            }
        }

        var level: String?
        if remaining.hasPrefix("DEV:") {
            level = "debug"
        } else if remaining.hasPrefix("INFO:") {
            level = "info"
        } else if remaining.hasPrefix("WARN:") {
            level = "warning"
        } else if remaining.hasPrefix("ERR:") {
            level = "error"
        }

        if timestampString == nil {
            timestampString = isoFormatter.string(from: Date())
        }

        return ParsedLogLine(
            message: remaining,
            timestamp: timestampString,
            level: level,
            category: category,
            platform: platform
        )
    }

    func applyBackoff() {
        nextAllowedUpload = Date().addingTimeInterval(retryDelay)
        retryDelay = min(retryDelay * 2, 300)
    }

    func resetBackoff() {
        retryDelay = 5
        nextAllowedUpload = .distantPast
    }
}

#endif
