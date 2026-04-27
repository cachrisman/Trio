import Foundation

@MainActor
extension WatchState {
    /// Apply a G7 eavesdrop EGV: update shared `TrioComplicationDataStore`, then `WatchState` for the main view.
    func applyG7DirectFromObserver(
        glucoseMgDl: Int,
        trend: String?,
        readingDate: Date,
        glucoseColorHex: String
    ) {
        let trendV = trend ?? ""
        var deltaV = delta ?? "--"
        if let prev = G7ComplicationDeltaState.previousGlucose, prev != glucoseMgDl {
            let d = glucoseMgDl - prev
            if d > 0 { deltaV = "+\(d)" } else if d < 0 { deltaV = "\(d)" } else { deltaV = "0" }
        }
        G7ComplicationDeltaState.previousGlucose = glucoseMgDl

        let snap = TrioComplicationSnapshot(
            glucose: String(glucoseMgDl),
            trend: trendV,
            delta: deltaV,
            readingDate: readingDate,
            date: Date(),
            glucoseColor: glucoseColorHex,
            dataSource: .g7DirectBLE
        )
        if !TrioComplicationDataStore.shared.wouldAcceptMainThreadSave(snap) {
            G7BLELog.log("event=g7_ble_snapshot_skipped reason=dedup_or_older reading_date=\(readingDate) glucose=\(glucoseMgDl)")
            return
        }
        TrioComplicationDataStore.shared.save(snap, minInterval: 5)
        currentGlucose = String(glucoseMgDl)
        self.trend = trendV
        delta = deltaV
        currentGlucoseColorString = glucoseColorHex
        if let a = Int(readingDate.timeIntervalSinceNow / -60.0) {
            lastLoopTime = "\(max(0, a)) min"
        }
        lastWatchStateUpdate = readingDate
        displayedComplicationDataSource = .g7DirectBLE
    }
}

@MainActor
enum G7ComplicationDeltaState {
    static var previousGlucose: Int?
}
