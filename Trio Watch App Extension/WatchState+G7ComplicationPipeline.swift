import Foundation

@MainActor
extension WatchState {
    /// Approximate CGM time from the phone’s `"N min"` recency string (e.g. `lastLoopTime`).
    static func approximateDateFromRecencyString(_ s: String?) -> Date? {
        guard let s, s != "--" else { return nil }
        let parts = s.split(separator: " ")
        guard let n = Int(parts.first ?? "") else { return nil }
        return Date().addingTimeInterval(-TimeInterval(n * 60))
    }

    /// After phone watchState fields are set, try to update the shared complication store (winner policy) and
    /// record which path would own the *display* when that snapshot wins.
    func applyPhonePathToComplicationPipeline() {
        let rDate: Date
        if let t = lastWatchStateUpdate {
            rDate = Date(timeIntervalSince1970: t)
        } else if let approx = Self.approximateDateFromRecencyString(lastLoopTime) {
            rDate = approx
        } else {
            rDate = Date()
        }
        let snap = TrioComplicationSnapshot(
            glucoseDisplay: currentGlucose,
            trendArrow: trend,
            readingDate: rDate,
            ingestDate: Date(),
            dataSource: .watchConnectivityPhone
        )
        let won = TrioComplicationDataStore.shared.save(
            snapshot: snap,
            triggerReload: true,
            minInterval: 5
        )
        if won {
            displayedComplicationDataSource = .watchConnectivityPhone
        }
    }

    func applyG7DirectSnapshot(
        _ snap: TrioComplicationSnapshot,
        colorHex: String
    ) {
        let won = TrioComplicationDataStore.shared.save(
            snapshot: snap,
            triggerReload: true,
            minInterval: 5
        )
        guard won else { return }
        currentGlucose = snap.glucoseDisplay
        if let t = snap.trendArrow { trend = t }
        currentGlucoseColorString = colorHex
        if let a = Int(snap.readingDate.timeIntervalSinceNow / -60.0) {
            lastLoopTime = "\(max(0, a)) min"
        }
        if let g = Int(snap.glucoseDisplay) {
            let _ = g
            recomputeLocalDeltaIfPossible(newValue: g)
        }
        displayedComplicationDataSource = .g7DirectBLE
    }

    private func recomputeLocalDeltaIfPossible(newValue: Int) {
        guard let prev = G7ComplicationDeltaState.previousGlucose,
              newValue != prev
        else {
            G7ComplicationDeltaState.previousGlucose = newValue
            G7ComplicationDeltaState.previousAt = Date()
            return
        }
        let d = newValue - prev
        if d > 0 {
            delta = "+\(d)"
        } else if d < 0 {
            delta = "\(d)"
        } else {
            delta = "0"
        }
        G7ComplicationDeltaState.previousGlucose = newValue
        G7ComplicationDeltaState.previousAt = Date()
    }
}

// MARK: - Local delta (watch-side) for G7 direct path

@MainActor
enum G7ComplicationDeltaState {
    static var previousGlucose: Int?
    static var previousAt: Date?
}
