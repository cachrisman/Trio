import Darwin
import Foundation

// MARK: - Field resident memory telemetry (watch)

/// Rollout gate for resident memory samples. Policy: **04** / plan **02** (resident sample §).
enum WatchResidentTelemetryGate {
    /// Opt-in for **production App Store** builds when the receipt is not sandbox (see `hasSandboxAppStoreReceipt`).
    private static let userDefaultsKey = "com.trio.watch.residentTelemetryEnabled"

    /// `true` when `Bundle.main.appStoreReceiptURL` ends with **`sandboxReceipt`** — includes **TestFlight** and other sandbox-distributed builds. Production App Store builds use the **`receipt`** filename instead.
    private static var hasSandboxAppStoreReceipt: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    static var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        if hasSandboxAppStoreReceipt {
            return true
        }
        return UserDefaults.standard.bool(forKey: userDefaultsKey)
        #endif
    }
}

/// Reads **`TASK_VM_INFO.phys_footprint`** (bytes) → **MiB** only (design **04**).
enum WatchResidentMemory {
    static func physFootprintMebibytes() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / (1024.0 * 1024.0)
    }
}

// MARK: - Budget

/// Per-activation sample cap + **`hk_batch`** once per process (plan **02**).
struct WatchResidentTelemetryBudget {
    /// Matches the **six** activation-scoped checkpoint tokens; **`hk_batch`** with **`activationSequence == nil`** is process-scoped and does not use this counter.
    private static let maxSamplesPerActivation = 6

    private static let checkpointTokens: Set<String> = [
        "first_main_view",
        "deferred_watch_state_fired",
        "first_watch_state_apply",
        "hk_batch",
        "post_startup_flush",
        "chart_visible"
    ]

    private var budgetActivationSeq: Int?
    private var firedCheckpoints: Set<String> = []
    private var totalThisActivation: Int = 0
    private var hkBatchEmittedThisProcess = false

    mutating func resetForNewActivation(_ seq: Int) {
        budgetActivationSeq = seq
        firedCheckpoints.removeAll()
        totalThisActivation = 0
    }

    /// Returns `true` if this checkpoint should emit (caller logs after).
    /// **`hk_batch`** may use **`activationSequence == nil`** for the process-scoped first batch when no foreground activation sequence exists yet (omit `activation_seq` on the log line — design **04**).
    mutating func consumeIfAllowed(checkpoint: String, activationSequence: Int?) -> Bool {
        guard Self.checkpointTokens.contains(checkpoint) else { return false }

        if checkpoint == "hk_batch", hkBatchEmittedThisProcess {
            return false
        }

        if activationSequence == nil {
            guard checkpoint == "hk_batch" else { return false }
            hkBatchEmittedThisProcess = true
            return true
        }

        guard let seq = activationSequence else { return false }

        guard budgetActivationSeq == seq else { return false }
        guard totalThisActivation < Self.maxSamplesPerActivation else { return false }
        guard !firedCheckpoints.contains(checkpoint) else { return false }

        firedCheckpoints.insert(checkpoint)
        totalThisActivation += 1
        if checkpoint == "hk_batch" {
            hkBatchEmittedThisProcess = true
        }
        return true
    }

    /// Undo `consumeIfAllowed` when `task_info` fails after the budget slot was reserved.
    mutating func rollbackConsume(checkpoint: String, activationSequence: Int?) {
        if checkpoint == "hk_batch", activationSequence == nil {
            hkBatchEmittedThisProcess = false
            return
        }
        guard let seq = activationSequence, budgetActivationSeq == seq else { return }
        guard firedCheckpoints.remove(checkpoint) != nil else { return }
        totalThisActivation = max(0, totalThisActivation - 1)
        if checkpoint == "hk_batch" {
            hkBatchEmittedThisProcess = false
        }
    }
}

// MARK: - WatchState emission

extension WatchState {
    /// **Main thread only.** Structured **`event=watch_resident_sample`** line (plan **02**).
    func emitResidentMemorySample(checkpoint: String, activationSequence: Int?) {
        assert(Thread.isMainThread, "emitResidentMemorySample must run on main")
        guard WatchResidentTelemetryGate.isEnabled else { return }
        guard residentTelemetryBudget.consumeIfAllowed(checkpoint: checkpoint, activationSequence: activationSequence)
        else { return }
        guard let mib = WatchResidentMemory.physFootprintMebibytes() else {
            residentTelemetryBudget.rollbackConsume(checkpoint: checkpoint, activationSequence: activationSequence)
            return
        }

        let mibStr = String(format: "%.3f", mib)
        var line =
            "event=watch_resident_sample checkpoint=\(checkpoint) phys_footprint_mib=\(mibStr)"
        if let seq = activationSequence {
            line += " activation_seq=\(seq)"
        }

        Task {
            await WatchLogger.shared.log(line)
        }
    }
}
