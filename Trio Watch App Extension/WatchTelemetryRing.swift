import Foundation
import G7SensorKit

/// C-208-9: producer-side telemetry ring.
///
/// BLE-path emitters (`G7Telemetry.emit` from the fork's queues, the adapter's `log()` on
/// MainActor) enqueue formatted lines **synchronously** — no per-event `Task` spawn, no
/// MainActor hop, no actor suspension on the timing-sensitive paths. A single long-lived
/// drainer feeds the existing `WatchLogger` transport, which keeps all of its
/// buffering / flush / persistence / BetterStack semantics unchanged.
///
/// Semantics:
/// - **Bounded (512), drop-oldest:** the enqueue path can never block or grow unboundedly.
///   Drops are counted and surfaced **at drain time** (`ring_dropped=` window count +
///   `ring_dropped_total=` cumulative) on a line that is being handed directly to WatchLogger —
///   so an annotated line can never itself be evicted. Residual: drops occurring after the
///   final drain of a process die with the process (cumulative counter restarts at relaunch).
/// - **`seq=` ordering:** a monotonic per-process sequence stamped at enqueue restores true
///   emission order in BetterStack regardless of downstream interleaving (review 5.6).
/// - **Lock-guarded (`NSLock`):** event rates are tens/sec worst case; the critical section is
///   an array append/remove. Deliberately not "lock-free" — simpler is safer here.
/// - **Suspension:** lines not yet drained die with the process. Acceptable: the ring carries
///   diagnostics; the capture-critical EGV path persists its own state independently
///   (C-208-10's secure-write).
final class WatchTelemetryRing: @unchecked Sendable {
    static let shared = WatchTelemetryRing()

    private let lock = NSLock()
    private var buffer: [String] = []
    private var seq: UInt64 = 0
    private var dropped: UInt64 = 0
    private var totalDropped: UInt64 = 0
    private let capacity = 512
    private var signal: AsyncStream<Void>.Continuation?

    /// Session context captured at emit time for fork (`module=g7_core`) lines. Updated by the
    /// adapter (MainActor) on connect / disconnect / identity changes; read under the lock from
    /// any queue. Attribution note: fork events emitted between a physical connect and the
    /// adapter's MainActor connect bookkeeping (e.g. `gatt_ready`, early `auth_*`) carry the
    /// PRIOR session id by design — emit-time context is the honest semantics; log readers
    /// should expect the session boundary on the adapter's `did_connect` line.
    private var contextSensorName = "nil"
    private var contextSession = "nil"

    private init() {}

    /// Adapter-driven context sync (sensor name + adapter session id).
    func setContext(sensorName: String, g7Session: String) {
        lock.lock()
        contextSensorName = sensorName
        contextSession = g7Session
        lock.unlock()
    }

    /// Fork telemetry -> formatted `module=g7_core` line using emit-time context.
    func enqueueCoreTelemetry(payload: G7TelemetryPayload) {
        lock.lock()
        let name = contextSensorName
        let sid = contextSession
        lock.unlock()
        enqueue(G7StructuredTelemetryLogLine.formatCoreTelemetry(
            sensorName: name,
            payload: payload,
            g7Session: sid
        ))
    }

    /// Pre-formatted line (the adapter formats its own `module=g7_ble` lines on MainActor where
    /// its state is directly readable).
    func enqueue(_ line: String) {
        lock.lock()
        seq += 1
        if buffer.count >= capacity {
            buffer.removeFirst()
            dropped += 1
            totalDropped += 1
        }
        buffer.append("\(line) seq=\(seq)")
        let continuation = signal
        lock.unlock()
        continuation?.yield()
    }

    /// Started once from `ExtensionDelegate.applicationDidFinishLaunching`.
    func startDrainer() {
        let stream = AsyncStream<Void> { continuation in
            lock.lock()
            signal = continuation
            lock.unlock()
            continuation.yield() // drain anything enqueued before the drainer existed
        }
        Task.detached(priority: .utility) { [weak self] in
            for await _ in stream {
                await self?.drainOnce()
            }
        }
    }

    /// Synchronous locked dequeue (NSLock is unavailable from async contexts in the Swift 6
    /// language mode — keep all locking in sync helpers). Drop counts are surfaced here, on a
    /// line that is being handed straight to WatchLogger, so the annotation can never be evicted.
    private func dequeueLine() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard buffer.isEmpty == false else { return nil }
        var line = buffer.removeFirst()
        if dropped > 0 {
            line += " ring_dropped=\(dropped) ring_dropped_total=\(totalDropped)"
            dropped = 0
        }
        return line
    }

    private func drainOnce() async {
        while let line = dequeueLine() {
            await WatchLogger.shared.log(line)
        }
    }
}
