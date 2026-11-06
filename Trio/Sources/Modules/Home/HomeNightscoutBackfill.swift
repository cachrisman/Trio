import Foundation

/// Bounds the pre-loop Nightscout glucose fetch so force-loop is not held open indefinitely.
enum HomeNightscoutBackfill {
    enum Outcome: Equatable {
        case stored(Int)
        case empty
        case timedOut
        case failed
    }

    /// Gap used to cluster near-duplicate fetched readings; mirrors
    /// `GlucoseStorage.backfillGlucose`'s 3.5-minute window against stored readings.
    static let duplicateWindow: TimeInterval = 210

    /// Splits fetched readings into store call batches. Near-duplicate clusters are stored
    /// one reading per call so each accepted reading counts as existing for the next —
    /// matching `backfillGlucose`'s across-call semantics. Isolated readings (more than
    /// `duplicateWindow` from every other fetched reading) share one first batch.
    static func storeBatches(_ readings: [BloodGlucose]) -> [[BloodGlucose]] {
        let sorted = readings.sorted { $0.dateString < $1.dateString }
        guard !sorted.isEmpty else { return [] }

        var clusters: [[BloodGlucose]] = []
        var current: [BloodGlucose] = [sorted[0]]
        for reading in sorted.dropFirst() {
            if reading.dateString.timeIntervalSince(current[current.count - 1].dateString) <= duplicateWindow {
                current.append(reading)
            } else {
                clusters.append(current)
                current = [reading]
            }
        }
        clusters.append(current)

        var batches: [[BloodGlucose]] = []
        let singletons = clusters.compactMap { $0.count == 1 ? $0[0] : nil }
        if !singletons.isEmpty {
            batches.append(singletons)
        }
        for cluster in clusters where cluster.count > 1 {
            for reading in cluster {
                batches.append([reading])
            }
        }
        return batches
    }

    static func run(
        timeout: Duration,
        fetch: @escaping () async -> [BloodGlucose],
        store: @escaping ([BloodGlucose]) async throws -> Void
    ) async -> Outcome {
        await withCheckedContinuation { continuation in
            let gate = Gate()

            let fetchTask = Task {
                let fetched = await fetch()
                guard await gate.claimFetch() else { return }

                guard !fetched.isEmpty else {
                    continuation.resume(returning: .empty)
                    return
                }

                do {
                    for batch in storeBatches(fetched) {
                        try await store(batch)
                    }
                    continuation.resume(returning: .stored(fetched.count))
                } catch {
                    continuation.resume(returning: .failed)
                }
            }

            Task {
                try? await Task.sleep(for: timeout)
                // Only a timeout that wins cancels; once the fetch has won, its store must run to completion.
                if await gate.claimTimeout() {
                    fetchTask.cancel()
                    continuation.resume(returning: .timedOut)
                }
            }
        }
    }

    private actor Gate {
        private enum Phase { case open, fetchWon, closed }
        private var phase: Phase = .open

        func claimTimeout() -> Bool {
            guard phase == .open else { return false }
            phase = .closed
            return true
        }

        func claimFetch() -> Bool {
            guard phase == .open else { return false }
            phase = .fetchWon
            return true
        }
    }
}
