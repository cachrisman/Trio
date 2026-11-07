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
