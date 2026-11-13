import Foundation

// Pure, Foundation-only decisions for forwarding device logs and determinations to the cloud.
// Kept free of LoopKit, CoreData and UIKit so it can be unit tested in isolation.

enum DeviceLogForwardingFilter {
    static let maxMessageLength = 1000
    static let latencyMarker = "connect latency"
    static let connectedMarker = "CONNECTED"

    /// `typeRawValue` is the LoopKit `DeviceLogEntryType.rawValue`.
    static func shouldForward(typeRawValue: String, message: String) -> Bool {
        if typeRawValue == "error" || typeRawValue == "connection" { return true }
        return message.contains(latencyMarker) || message.contains(connectedMarker)
    }

    static func isWarning(typeRawValue: String) -> Bool {
        typeRawValue == "error"
    }

    static func format(managerIdentifier: String, typeRawValue: String, message: String, reserving reserved: Int = 0) -> String {
        let text = "\(managerIdentifier) [\(typeRawValue)] \(message)"
        let limit = max(0, maxMessageLength - reserved)
        return text.count > limit ? String(text.prefix(limit)) : text
    }
}

/// Lock-protected; `DeviceLogStore.log` is called from arbitrary threads.
final class DeviceLogForwardingPolicy: @unchecked Sendable {
    struct Decision: Equatable {
        let isWarning: Bool
        let text: String
    }

    static let backfillMarker = "Backfill frame of unexpected length"
    static let backfillInterval: TimeInterval = 5 * 60

    private let clock: () -> Date
    private let lock = NSLock()
    private var lastBackfillForward: Date?
    private var suppressedBackfill = 0

    init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    func decide(managerIdentifier: String, typeRawValue: String, message: String) -> Decision? {
        guard DeviceLogForwardingFilter.shouldForward(typeRawValue: typeRawValue, message: message) else { return nil }
        var suffix = ""
        if message.contains(Self.backfillMarker) {
            let now = clock()
            lock.lock()
            if let last = lastBackfillForward, now >= last, now.timeIntervalSince(last) < Self.backfillInterval {
                suppressedBackfill += 1
                lock.unlock()
                return nil
            }
            if suppressedBackfill > 0 { suffix = " (+\(suppressedBackfill) suppressed)" }
            suppressedBackfill = 0
            lastBackfillForward = now
            lock.unlock()
        }
        let text = DeviceLogForwardingFilter.format(
            managerIdentifier: managerIdentifier,
            typeRawValue: typeRawValue,
            message: message,
            reserving: suffix.count
        ) + suffix
        return Decision(isWarning: DeviceLogForwardingFilter.isWarning(typeRawValue: typeRawValue), text: text)
    }
}

/// Remembers recently seen determinations; reports new ones and a later flip to enacted once.
struct DeterminationDedupe<ID: Hashable> {
    enum Outcome: Equatable {
        case new
        case enactedFlip
        case none
    }

    let capacity: Int
    private var seen: [ID: Bool] = [:]
    private var order: [ID] = []

    init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    var count: Int { seen.count }

    /// Old determinations arrive as updates (Nightscout upload flags, relaunch, history replay)
    /// and must not be re-logged, so only determinations this close to now are reported.
    static var recencyWindow: TimeInterval { 15 * 60 }

    mutating func observe(id: ID, enacted: Bool, date: Date?, now: Date = Date()) -> Outcome {
        let recent = date.map { abs(now.timeIntervalSince($0)) <= Self.recencyWindow } ?? false
        if let wasEnacted = seen[id] {
            guard enacted, !wasEnacted else { return .none }
            seen[id] = true
            return recent ? .enactedFlip : .none
        }
        guard recent else { return .none }
        seen[id] = enacted
        order.append(id)
        if order.count > capacity {
            seen.removeValue(forKey: order.removeFirst())
        }
        return .new
    }
}

enum CloudLogUploadFailureAction: Equatable {
    case rejectRows
    case retryLater
}

enum CloudLogUploadFailurePolicy {
    private static let retryLaterClientCodes: Set<Int> = [401, 403, 404, 408, 429]

    static func action(for error: CloudLogUploadError) -> CloudLogUploadFailureAction {
        switch error {
        case .encoding:
            return .rejectRows
        case let .unexpectedStatus(code, _):
            guard (400 ..< 500).contains(code), !retryLaterClientCodes.contains(code) else { return .retryLater }
            return .rejectRows
        case .notConfigured, .invalidURL, .transport, .invalidResponse:
            return .retryLater
        }
    }
}

// MARK: - Cloud log batch upload drain (testable; mirrors `CloudLogUploadService.runPass` per-batch loop)

enum CloudLogBatchUploadDrain {
    enum Outcome: Equatable {
        case batchComplete
        case stopPass
    }

    struct Handlers: Sendable {
        let encodedSize: @Sendable ([CloudLogEvent]) -> Int?
        let upload: @Sendable ([CloudLogEvent]) async -> Result<Void, CloudLogUploadError>
        let commit: @Sendable (CloudLogQueue.Cursor, UInt64) async -> Void
        let addDropped: @Sendable (UInt64) -> Void
        let logRejectedRow: @Sendable (String) -> Void
        let uploadDropVisibility: @Sendable (CloudLogEvent) async -> Void
    }

    struct Context: Sendable {
        let itemEvents: [CloudLogEvent]
        let itemEnds: [CloudLogQueue.Cursor]
        let itemSkips: [Int]
        var persistedDropped: UInt64
        let rangeStart: CloudLogQueue.Cursor
        let common: CloudLogCommonAttributes
        let maxRequestBytes: Int
        let maxRequestsPerPass: Int
    }

    static func rejectionStatusLabel(for error: CloudLogUploadError) -> String {
        switch error {
        case .encoding:
            return "encoding"
        case let .unexpectedStatus(code, _):
            return String(code)
        case .notConfigured, .invalidURL, .transport, .invalidResponse:
            return "retry"
        }
    }

    static func drain(
        handlers: Handlers,
        context: Context,
        requests: inout Int
    ) async -> Outcome {
        let count = context.itemEvents.count
        guard count > 0 else { return .batchComplete }

        let ctx = context
        var persistedPending = ctx.persistedDropped
        var lo = 0
        var hi = count

        while lo < count {
            func droppedCount(_ upper: Int) -> UInt64 {
                persistedPending &+ UInt64(ctx.itemSkips[lo ..< upper].reduce(0, +))
            }
            func events(upTo upper: Int) -> [CloudLogEvent] {
                let dropped = droppedCount(upper)
                let dropEvents = dropped > 0 ? [CloudLogEvent.dropped(count: dropped, common: ctx.common)] : []
                return dropEvents + ctx.itemEvents[lo ..< upper]
            }

            while hi - lo > 1,
                  let size = handlers.encodedSize(events(upTo: hi)),
                  size > ctx.maxRequestBytes
            {
                hi = lo + max(1, (hi - lo) / 2)
            }

            guard requests < ctx.maxRequestsPerPass else { return .stopPass }
            requests += 1

            switch await handlers.upload(events(upTo: hi)) {
            case .success:
                await handlers.commit(ctx.itemEnds[hi - 1], persistedPending)
                persistedPending = 0
                lo = hi
                hi = count
            case let .failure(error):
                switch CloudLogUploadFailurePolicy.action(for: error) {
                case .retryLater:
                    return .stopPass
                case .rejectRows:
                    if hi - lo > 1 {
                        hi = lo + (hi - lo) / 2
                        continue
                    }
                    let status = rejectionStatusLabel(for: error)
                    handlers.logRejectedRow(status)
                    let lostSkips = UInt64(ctx.itemSkips[lo])
                    let rowEnd = ctx.itemEnds[lo]
                    let rowStart = lo == 0 ? ctx.rangeStart : ctx.itemEnds[lo - 1]
                    await handlers.commit(rowEnd, 0)
                    let droppedRows = 1 &+ lostSkips
                    handlers.addDropped(droppedRows)

                    if requests < ctx.maxRequestsPerPass {
                        requests += 1
                        let visibility = CloudLogEvent.rowDropped(
                            status: status,
                            rows: droppedRows,
                            rangeStart: rowStart,
                            rangeEnd: rowEnd,
                            common: ctx.common
                        )
                        await handlers.uploadDropVisibility(visibility)
                    }

                    lo += 1
                    hi = count
                }
            }
        }

        return .batchComplete
    }
}
