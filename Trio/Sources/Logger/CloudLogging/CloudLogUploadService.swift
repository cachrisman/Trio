import Foundation
import os
import UIKit

/// App lifecycle + periodic trigger wrapper that drains `CloudLogQueue` to the cloud provider.
///
/// - Manual trigger: `uploadNow()`
/// - Lifecycle triggers: foreground/background
/// - Periodic trigger: every 30 seconds while app is running
/// - Build change: one pass at start when `CFBundleVersion` differs from the last run
final class CloudLogUploadService {
    // Settings UI (first-choice config)
    static let userDefaultsEnabledKey = "cloudLogging.enabled"
    static let userDefaultsTokenKey = "cloudLogging.token"
    static let userDefaultsIngestionURLKey = "cloudLogging.ingestionUrl"

    // Legacy key (kept for backwards compatibility)
    static let legacyUserDefaultsTokenKey = "cloudLogging.betterStackSourceToken"

    private static let maxBatchesPerPass = 20
    private static let maxRequestsPerPass = 100
    private static let batchMaxBytes = 768_000
    private static let batchMaxRecords = 1000
    private static let maxRequestBytes = 1_000_000

    // Cloud logging must not use TrioLogger, otherwise upload failures would feed rows back into the queue.
    private static let osLog = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.nightscout.Trio",
        category: "CloudLogging"
    )

    private let provider: BetterStackLogtailProvider
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let tokenProvider: () -> String?
    private let ingestionURLProvider: () -> URL?
    private let passInFlight = OSAllocatedUnfairLock<Bool>(initialState: false)

    init() {
        tokenProvider = {
            let ud = UserDefaults.standard

            // If the user explicitly disabled cloud logging, do not fall back to file/env.
            if let enabled = ud.object(forKey: Self.userDefaultsEnabledKey) as? Bool, enabled == false {
                return nil
            }

            // Priority: Settings UI (UserDefaults) → app group settings/BetterStack.json → Info.plist → env.
            if let enabled = ud.object(forKey: Self.userDefaultsEnabledKey) as? Bool, enabled == true {
                if let t = ud.string(forKey: Self.userDefaultsTokenKey), !t.isEmpty { return t }
                if let t = ud.string(forKey: Self.legacyUserDefaultsTokenKey), !t.isEmpty { return t }
                // If enabled but no token set in UI, allow file-based config.
            } else {
                // No explicit enable flag; still allow legacy token key.
                if let t = ud.string(forKey: Self.legacyUserDefaultsTokenKey), !t.isEmpty { return t }
            }

            if let settings = BetterStackSettingsStore.load(),
               let t = settings.BetterStackSourceToken,
               !t.isEmpty
            {
                return t
            }

            if let t = Bundle.main.object(forInfoDictionaryKey: "BetterStackSourceToken") as? String, !t.isEmpty { return t }
            return ProcessInfo.processInfo.environment["BETTERSTACK_SOURCE_TOKEN"]
        }

        ingestionURLProvider = {
            let ud = UserDefaults.standard

            if let enabled = ud.object(forKey: Self.userDefaultsEnabledKey) as? Bool, enabled == false {
                return nil
            }

            if let enabled = ud.object(forKey: Self.userDefaultsEnabledKey) as? Bool, enabled == true {
                if let raw = ud.string(forKey: Self.userDefaultsIngestionURLKey), !raw.isEmpty {
                    return URL(string: raw)
                }
            }

            if let settings = BetterStackSettingsStore.load(),
               let raw = settings.BetterStackIngestionUrl,
               let url = URL(string: raw)
            {
                return url
            }
            return URL(string: "https://in.logs.betterstack.com/")
        }

        provider = BetterStackLogtailProvider(
            tokenProvider: tokenProvider,
            ingestionURLProvider: ingestionURLProvider
        )

        start()
    }

    deinit {
        stop()
    }

    func uploadNow() {
        guard isConfigured else { return }

        Task { [weak self] in
            await self?.runPass()
        }
    }

    private var isConfigured: Bool {
        guard let token = tokenProvider(), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return ingestionURLProvider() != nil
    }

    // MARK: - Upload pass

    private func runPass() async {
        guard isConfigured else { return }

        let acquired = passInFlight.withLock { running -> Bool in
            if running { return false }
            running = true
            return true
        }
        guard acquired else { return }
        defer { passInFlight.withLock { $0 = false } }

        // Persist pending in-memory rows first so this pass (notably the background one) sees them.
        await CloudLogSink.shared.flush()

        let common = CloudLogCommonAttributes.current
        let queue = CloudLogQueue.shared
        var requests = 0

        for _ in 0 ..< Self.maxBatchesPerPass {
            guard let batch = await queue.nextBatch(
                maxBytes: Self.batchMaxBytes,
                maxRecords: Self.batchMaxRecords
            ) else { return }

            // Only dropped-row reporting to send (skipped rows or counter): no items to bisect.
            if batch.items.isEmpty {
                guard requests < Self.maxRequestsPerPass else { return }
                requests += 1
                let event = CloudLogEvent.dropped(count: batch.droppedToReport, common: common)
                guard case .success = await provider.upload(events: [event]) else { return }
                await queue.commit(through: batch.end, droppedReported: batch.persistedDropped)
                continue
            }

            let itemEvents = batch.items.map { CloudLogEvent.make(from: $0.record, common: common) }
            var persistedPending = batch.persistedDropped
            var lo = 0
            var hi = batch.items.count

            while lo < batch.items.count {
                // Skipped rows count with the range that ends after them; persisted drops go with the first commit.
                func droppedCount(_ upper: Int) -> UInt64 {
                    persistedPending &+ UInt64(batch.itemSkips[lo ..< upper].reduce(0, +))
                }
                func events(upTo upper: Int) -> [CloudLogEvent] {
                    let dropped = droppedCount(upper)
                    let dropEvents = dropped > 0 ? [CloudLogEvent.dropped(count: dropped, common: common)] : []
                    return dropEvents + itemEvents[lo ..< upper]
                }

                // Halve the range until the encoded request fits (keep at least one item).
                while hi - lo > 1,
                      let size = provider.encodedSize(of: events(upTo: hi)),
                      size > Self.maxRequestBytes
                {
                    hi = lo + max(1, (hi - lo) / 2)
                }

                guard requests < Self.maxRequestsPerPass else { return }
                requests += 1

                switch await provider.upload(events: events(upTo: hi)) {
                case .success:
                    await queue.commit(through: batch.items[hi - 1].end, droppedReported: persistedPending)
                    persistedPending = 0
                    lo = hi
                    hi = batch.items.count
                case let .failure(error):
                    guard case let .unexpectedStatus(code, _) = error, code == 400 || code == 413 else { return }
                    if hi - lo > 1 {
                        // Bisect: retry the first half; the rest follows once it is committed.
                        hi = lo + (hi - lo) / 2
                        continue
                    }
                    // A permanently rejected single row must not wedge the queue.
                    Self.osLog.error("Cloud logging: dropping rejected row (status=\(code))")
                    let lostSkips = UInt64(batch.itemSkips[lo])
                    await queue.commit(through: batch.items[lo].end, droppedReported: 0)
                    queue.addDropped(1 &+ lostSkips)
                    lo += 1
                    hi = batch.items.count
                }
            }
        }
    }

    // MARK: - Scheduling

    private func start() {
        // Determination rows ride the same cloud pipeline; start their observer with the uploader.
        CloudDeterminationLogger.shared.start()
        let center = Foundation.NotificationCenter.default

        observers.append(
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.uploadNow()
            }
        )

        observers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.uploadInBackgroundTask()
            }
        )

        startTimer()

        // Detect build change and flush immediately so backlogged lines carry the old build
        let lastKnownBuildKey = "cloudLogUploadService.lastKnownBuild"
        let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let lastKnownBuild = UserDefaults.standard.string(forKey: lastKnownBuildKey)
        if lastKnownBuild != currentBuild {
            uploadNow()
            UserDefaults.standard.set(currentBuild, forKey: lastKnownBuildKey)
        }
    }

    private func uploadInBackgroundTask() {
        guard isConfigured else { return }

        let taskID = OSAllocatedUnfairLock<UIBackgroundTaskIdentifier>(initialState: .invalid)
        let endTask: @Sendable () -> Void = {
            let id = taskID.withLock { current -> UIBackgroundTaskIdentifier in
                defer { current = .invalid }
                return current
            }
            guard id != .invalid else { return }
            DispatchQueue.main.async {
                UIApplication.shared.endBackgroundTask(id)
            }
        }

        let id = UIApplication.shared.beginBackgroundTask(withName: "CloudLogUpload") {
            endTask()
        }
        taskID.withLock { $0 = id }

        Task { [weak self] in
            await self?.runPass()
            endTask()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.uploadNow()
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil

        let center = Foundation.NotificationCenter.default
        for o in observers {
            center.removeObserver(o)
        }
        observers.removeAll()
    }
}
