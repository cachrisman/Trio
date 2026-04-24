import Foundation

extension WatchState {
    enum G7BLEStatus: String {
        case off
        case searching
        case connecting
        case active
        case stalled
        case unavailable

        var display: String {
            switch self {
            case .off: "off"
            case .searching: "search"
            case .connecting: "conn"
            case .active: "active"
            case .stalled: "stall"
            case .unavailable: "na"
            }
        }
    }

    var g7BLEStatus: G7BLEStatus {
        get { _g7BLEStatus }
        set { _g7BLEStatus = newValue }
    }

    var g7LastDirectEventAt: Date? {
        get { _g7LastDirectEventAt }
        set { _g7LastDirectEventAt = newValue }
    }

    var g7DisplayedSource: TrioComplicationDataSource {
        get { _g7DisplayedSource }
        set { _g7DisplayedSource = newValue }
    }

    func startG7ObserverForActiveScene() {
        G7DirectBLEObserver.shared.delegate = self
        G7DirectBLEObserver.shared.start(sceneActive: true)
    }

    func updateG7ObserverForScene(active: Bool) {
        G7DirectBLEObserver.shared.updateScene(active: active)
    }

    func stopG7Observer() {
        G7DirectBLEObserver.shared.stop()
    }
}

extension WatchState: G7DirectBLEObserverDelegate {
    func g7ObserverDidUpdateStatus(_ status: G7BLEStatus) {
        g7BLEStatus = status
    }

    func g7ObserverDidRecordDirectEvent(at date: Date) {
        g7LastDirectEventAt = date
    }

    func g7ObserverDidReceiveEGV(glucose: String, trend: String, delta: String, readingDate: Date) {
        currentGlucose = glucose
        self.trend = trend
        self.delta = delta
        lastWatchStateUpdate = readingDate
        g7DisplayedSource = .directBLE
        g7LastDirectEventAt = Date()

        let snapshot = TrioComplicationSnapshot(
            glucose: glucose,
            trend: trend,
            delta: delta,
            readingDate: readingDate,
            date: Date(),
            glucoseColor: currentGlucoseColorString,
            source: .directBLE
        )
        TrioComplicationDataStore.shared.save(snapshot, minInterval: 5)

        Task {
            await WatchLogger.shared.log(
                "event=g7_ble_snapshot_saved glucose=\(glucose) trend=\(trend) reading_epoch=\(Int(readingDate.timeIntervalSince1970))"
            )
        }
    }
}
