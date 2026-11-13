import Foundation
import G7SensorKit

/// C-208-9: producer-side telemetry ring.
///
/// BLE-path emitters (`G7Telemetry.emit` from the fork's queues, the adapter's `log()` on
/// MainActor) enqueue formatted lines **synchronously** — no per-event `Task` spawn, no
/// MainActor hop, no actor suspension on the timing-sensitive paths. A single long-lived
/// drainer feeds the upstream `WatchLogger` ring under category `g7`, which keeps all of its
/// buffering / shipping / persistence semantics unchanged.
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
    // C-212-4 pt2 (BUG-F): scene/ext context for fork (`module=g7_core`) lines, which can't know the
    // watch app's scene phase. Synced by the adapter at BLE-lifecycle points (where fork events cluster).
    private var contextScenePhase = "unknown"
    private var contextExtSessionActive = false

    private let linkTimeline = G7LinkTimeline()

    private init() {}

    /// TRIO-107: acquisition arm (`upstream` / `stock`), set once by the adapter at init.
    func setLinkArm(_ arm: String) {
        linkTimeline.setArm(arm)
    }

    /// Adapter-driven context sync (sensor name + adapter session id + scene/ext for fork lines).
    func setContext(sensorName: String, g7Session: String, scenePhase: String, extSessionActive: Bool) {
        lock.lock()
        contextSensorName = sensorName
        contextSession = g7Session
        contextScenePhase = scenePhase
        contextExtSessionActive = extSessionActive
        lock.unlock()
        linkTimeline.noteContext(scenePhase: scenePhase, g7Session: g7Session)
    }

    /// Fork telemetry -> formatted `module=g7_core` line using emit-time context.
    func enqueueCoreTelemetry(payload: G7TelemetryPayload) {
        lock.lock()
        let name = contextSensorName
        let sid = contextSession
        let scene = contextScenePhase
        let extActive = contextExtSessionActive
        lock.unlock()
        enqueue(G7StructuredTelemetryLogLine.formatCoreTelemetry(
            sensorName: name,
            payload: payload,
            g7Session: sid
        ) + " scene_phase=\(scene) ext_session_active=\(extActive)")
        // C-217-D5: UI-207-3's deferred "Was restored" row — display wiring only. Observe-only
        // hook for the fork's `will_restore_state` event: placed AFTER the enqueue and OUTSIDE
        // the ring's lock, so the telemetry hot path (lock -> append -> yield) is untouched. The
        // string compare allocates nothing on the non-matching (overwhelmingly common) path; the
        // main-queue hop happens only on the rare restore event.
        if payload.event == "will_restore_state" {
            DispatchQueue.main.async {
                WatchState.shared.bleWasRestored = true
                WatchState.shared.bleLastRestoreAt = Date()
            }
        }
        // TRIO-107: per-link summary. Same placement rules as above (after the enqueue, outside
        // the ring's lock); the timeline has its own lock and non-matching events return at once.
        for summary in linkTimeline.handle(event: payload.event, fields: payload.fields, ctxSession: sid) {
            enqueue(G7StructuredTelemetryLogLine.formatBleModule(
                sensorName: name,
                event: "link_summary",
                fields: summary.fields + " scene_phase=\(scene) ext_session_active=\(extActive) connect_seen=\(summary.connectSeen)",
                g7Session: summary.session
            ))
        }
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
            WatchLogger.shared.info(.g7, line)
        }
    }
}

/// TRIO-107: one `link_summary` per G7 link. Fed from `WatchTelemetryRing.enqueueCoreTelemetry`,
/// which relies on the library emitting its events in order on one serial queue, so every earlier
/// event of a link is recorded before that link's `disconnect` arrives.
final class G7LinkTimeline: @unchecked Sendable {
    struct Summary {
        let fields: String
        let session: String
        let connectSeen: Bool
    }

    private struct Link {
        let t0: Date
        let restored: Bool
        var session: String?
        var ready: Date?
        var sub: Date?
        var auth03: Date?
        var auth05: Date?
        var egv: Date?
        var rssiAt: Date?
        var rssiValue: String?
        var gattFail: String?
    }

    private let lock = NSLock()
    private var links: [String: Link] = [:]
    private var lastOpenKey: String?
    private var pendingRestored: Set<String> = []
    private var arm = "unknown"
    private var scenePhaseActive = false
    private var lastLeftActive: Date?
    private let createdAt = Date()
    private let processStart: Date

    init() {
        processStart = Self.readProcessStart() ?? createdAt
    }

    private static func readProcessStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    func setArm(_ value: String) {
        lock.lock()
        arm = value
        lock.unlock()
    }

    func noteContext(scenePhase: String, g7Session: String) {
        lock.lock()
        let isActive = scenePhase == "active"
        if scenePhaseActive, !isActive { lastLeftActive = Date() }
        scenePhaseActive = isActive
        if g7Session != "nil" {
            for key in links.keys { links[key]?.session = g7Session }
        }
        lock.unlock()
    }

    private static let staleAfter: TimeInterval = 600

    /// Returns the summaries to emit for the links this event closes (usually none).
    func handle(event: String, fields: String, ctxSession: String) -> [Summary] {
        switch event {
        case "did_connect", "restored_didconnect_synthesized", "gatt_ready", "auth_notify_subscribed",
             "auth_value_received", "egv_received", "rssi_read", "command_timeout",
             "configure_block_skipped", "configure_retry_exhausted", "disconnect":
            break
        default:
            return []
        }
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case "restored_didconnect_synthesized":
            if let id = Self.value("peripheral", in: fields) { pendingRestored.insert(id) }
            return []
        case "did_connect":
            guard let id = Self.value("peripheral", in: fields) else { return [] }
            var result: [Summary] = []
            if let old = links[id] {
                result.append(summarize(old, key: id, end: "superseded", endAt: now, wasRemote: "nil"))
            }
            // A link whose `disconnect` never arrives (e.g. a stray peripheral dropped by the manager
            // first) is closed as `end=stale` once it is older than any real link, so `links` stays bounded.
            for (key, link) in links where now.timeIntervalSince(link.t0) > Self.staleAfter {
                result.append(summarize(link, key: key, end: "stale", endAt: now, wasRemote: "nil"))
            }
            let restored = pendingRestored.remove(id) != nil
            links[id] = Link(t0: now, restored: restored, session: ctxSession == "nil" ? nil : ctxSession)
            lastOpenKey = id
            return result
        case "disconnect":
            let wasRemote = Self.value("was_remote", in: fields) ?? "nil"
            if let id = Self.value("peripheral", in: fields), let link = links[id] {
                return [summarize(link, key: id, end: "disconnect", endAt: now, wasRemote: wasRemote)]
            }
            let id = Self.value("peripheral", in: fields) ?? "unknown"
            return [unknownSummary(key: id, wasRemote: wasRemote, session: ctxSession)]
        default:
            break
        }
        let key = Self.value("peripheral", in: fields) ?? lastOpenKey
        guard let key, var link = links[key] else { return [] }
        switch event {
        case "gatt_ready":
            if link.ready == nil { link.ready = now }
        case "auth_notify_subscribed":
            if link.sub == nil { link.sub = now }
        case "auth_value_received":
            let opcode = Self.value("opcode", in: fields)
            if opcode == "0x03", link.auth03 == nil { link.auth03 = now }
            if opcode == "0x05", link.auth05 == nil { link.auth05 = now }
        case "egv_received":
            if link.egv == nil { link.egv = now }
        case "rssi_read":
            if link.rssiAt == nil {
                link.rssiAt = now
                link.rssiValue = Self.value("value", in: fields) ?? "nil"
            }
        case "command_timeout":
            if link.gattFail == nil {
                link.gattFail = "command_timeout:" + (Self.value("op", in: fields) ?? "nil")
            }
        default: // configure_block_skipped, configure_retry_exhausted
            if link.gattFail == nil { link.gattFail = event }
        }
        links[key] = link
        return []
    }

    // Caller holds `lock`.
    private func summarize(_ link: Link, key: String, end: String, endAt: Date, wasRemote: String) -> Summary {
        links[key] = nil
        if lastOpenKey == key { lastOpenKey = links.max { $0.value.t0 < $1.value.t0 }?.key }
        func ms(_ d: Date?) -> Int {
            guard let d else { return -1 }
            return Int(d.timeIntervalSince(link.t0) * 1000)
        }
        let egv = ms(link.egv)
        let outcome: String
        if egv >= 0 {
            outcome = "egv"
        } else if link.auth03 != nil || link.auth05 != nil {
            outcome = "auth_no_egv"
        } else if link.sub != nil {
            outcome = "no_auth"
        } else {
            outcome = "no_gatt"
        }
        let body = "outcome=\(outcome) end=\(end) peripheral=\(key.prefix(8)) restored=\(link.restored) "
            + "ready_ms=\(ms(link.ready)) sub_ms=\(ms(link.sub)) auth03_ms=\(ms(link.auth03)) "
            + "auth05_ms=\(ms(link.auth05)) egv_ms=\(egv) rssi_ms=\(ms(link.rssiAt)) "
            + "rssi=\(link.rssiValue ?? "nil") gatt_fail=\(link.gattFail ?? "none") "
            + "dur_ms=\(ms(endAt)) was_remote=\(wasRemote) "
        return Summary(fields: body + tail(), session: link.session ?? "nil", connectSeen: true)
    }

    // Caller holds `lock`.
    private func unknownSummary(key: String, wasRemote: String, session: String) -> Summary {
        let body = "outcome=unknown end=disconnect peripheral=\(key.prefix(8)) restored=false "
            + "ready_ms=-1 sub_ms=-1 auth03_ms=-1 auth05_ms=-1 egv_ms=-1 rssi_ms=-1 rssi=nil "
            + "gatt_fail=none dur_ms=-1 was_remote=\(wasRemote) "
        return Summary(fields: body + tail(), session: session, connectSeen: false)
    }

    // Caller holds `lock`. Trailing arm / process_age_s / since_fg_s fields.
    private func tail() -> String {
        let now = Date()
        let sinceFg: Int
        if scenePhaseActive {
            sinceFg = 0
        } else if let left = lastLeftActive {
            sinceFg = Int(now.timeIntervalSince(left))
        } else {
            sinceFg = -1
        }
        return "arm=\(arm) process_age_s=\(Int(now.timeIntervalSince(processStart))) since_fg_s=\(sinceFg)"
    }

    private static func value(_ key: String, in fields: String) -> String? {
        guard let r = fields.range(of: key + "=") else { return nil }
        if r.lowerBound != fields.startIndex, fields[fields.index(before: r.lowerBound)] != " " { return nil }
        let rest = fields[r.upperBound...]
        return String(rest.prefix { $0 != " " })
    }
}
