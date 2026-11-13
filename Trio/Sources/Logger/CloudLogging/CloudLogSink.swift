import Foundation
import os
import UIKit

// Feeds every log record (phone and watch) into the durable CloudLogQueue. accept() only touches an
// in-memory buffer under a lock; the hand-off to disk happens on a private queue, coalesced.
final class CloudLogSink: LogSink, @unchecked Sendable {
    static let shared = CloudLogSink()

    static let pendingLimit = 5000
    static let batchSize = 200
    static let flushDelay: TimeInterval = 1

    private static let enabledKey = "cloudLogging.enabled"
    private static let osLogger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.nightscout.Trio",
        category: "CloudLogging"
    )

    private struct Pending: Sendable {
        var records: [LogRecord] = []
        var droppedCount: UInt64 = 0
        var enabled: Bool
        var flushScheduled = false
        var batchFlushScheduled = false
    }

    private let cloudQueue: CloudLogQueue
    private let defaults: UserDefaults
    private let notificationCenter: Foundation.NotificationCenter
    private let pending: OSAllocatedUnfairLock<Pending>
    private let queue = DispatchQueue(label: "CloudLogSink.queue", qos: .utility)
    private var observers: [NSObjectProtocol] = []

    init(
        queue cloudQueue: CloudLogQueue = .shared,
        defaults: UserDefaults = .standard,
        notificationCenter: Foundation.NotificationCenter = .default
    ) {
        self.cloudQueue = cloudQueue
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        pending = OSAllocatedUnfairLock(initialState: Pending(enabled: Self.readEnabled(defaults)))

        observers = [
            notificationCenter.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: defaults,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.refreshEnabled() }
            },
            notificationCenter.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.drain(synchronously: false) }
            },
            notificationCenter.addObserver(
                forName: UIApplication.willTerminateNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.queue.sync { self.drain(synchronously: true) }
            }
        ]
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }

    func accept(_ record: LogRecord) {
        let (scheduleDelayed, flushNow) = pending.withLock { state -> (Bool, Bool) in
            guard state.enabled else { return (false, false) }
            state.records.append(record)
            if state.records.count > Self.pendingLimit {
                // Drop a chunk so a full buffer doesn't shift on every record
                let excess = state.records.count - Self.pendingLimit
                let dropCount = max(excess, Self.pendingLimit / 10)
                state.records.removeFirst(dropCount)
                state.droppedCount += UInt64(dropCount)
            }
            let scheduleDelayed = !state.flushScheduled
            state.flushScheduled = true
            let flushNow = state.records.count >= Self.batchSize && !state.batchFlushScheduled
            if flushNow { state.batchFlushScheduled = true }
            return (scheduleDelayed, flushNow)
        }
        if flushNow {
            queue.async { self.drain(synchronously: false) }
        }
        if scheduleDelayed {
            queue.asyncAfter(deadline: .now() + Self.flushDelay) {
                self.drain(synchronously: false)
            }
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.drain(synchronously: true)
                continuation.resume()
            }
        }
    }

    func records(in _: DateInterval, minimumLevel _: LogLevel) async -> [LogRecord] {
        []
    }

    private static func readEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool != false
    }

    private func refreshEnabled() {
        let enabled = Self.readEnabled(defaults)
        pending.withLock { $0.enabled = enabled }
    }

    private func drain(synchronously: Bool) {
        let (records, dropped) = pending.withLock { state -> ([LogRecord], UInt64) in
            defer {
                state.records = []
                state.droppedCount = 0
                state.flushScheduled = false
                state.batchFlushScheduled = false
            }
            return (state.records, state.droppedCount)
        }
        if dropped > 0 {
            cloudQueue.addDropped(dropped)
            Self.osLogger.warning("Pending buffer overflowed; dropped \(dropped, privacy: .public) rows")
        }
        guard !records.isEmpty else { return }
        if synchronously {
            cloudQueue.appendSync(records)
        } else {
            cloudQueue.append(records)
        }
    }
}
