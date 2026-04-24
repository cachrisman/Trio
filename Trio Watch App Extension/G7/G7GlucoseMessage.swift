import Foundation

// Layout from G7SensorKit `G7GlucoseMessage.swift` (G7SensorKit/Messages/G7GlucoseMessage.swift).

struct G7GlucoseMessage: Equatable {
    let glucose: UInt16?
    let predicted: UInt16?
    let glucoseIsDisplayOnly: Bool
    let messageTimestamp: UInt32
    let algorithmState: G7AlgorithmState
    let sequence: UInt16
    let trend: Double?
    let data: Data
    let age: UInt16

    var hasReliableGlucose: Bool { algorithmState.hasReliableGlucose }

    var glucoseTimestamp: UInt32 { messageTimestamp - UInt32(age) }

    /// Nightscout / Trio watch trend string (same naming as `WatchState.trend` from the phone).
    var trendString: String? {
        guard let t = trend else { return nil }
        switch t {
        case let x where x <= -3.0: "DoubleDown"
        case let x where x <= -2.0: "SingleDown"
        case let x where x <= -1.0: "FortyFiveDown"
        case let x where x < 1.0: "Flat"
        case let x where x < 2.0: "FortyFiveUp"
        case let x where x < 3.0: "SingleUp"
        default: "DoubleUp"
        }
    }

    init?(data: Data) {
        guard data.count >= 19 else { return nil }
        guard data[1] == 0 else { return nil }

        messageTimestamp = data.subdata(in: 2 ..< 6).g7ToUInt32()
        sequence = data.subdata(in: 6 ..< 8).g7ToUInt16()
        age = data.subdata(in: 10 ..< 12).g7ToUInt16()
        let glucoseData = data.subdata(in: 12 ..< 14).g7ToUInt16()
        if glucoseData != 0xFFFF {
            glucose = glucoseData & 0x0FFF
            glucoseIsDisplayOnly = (data[18] & 0x10) > 0
        } else {
            glucose = nil
            glucoseIsDisplayOnly = false
        }
        let predictionData = data.subdata(in: 16 ..< 18).g7ToUInt16()
        if predictionData != 0xFFFF {
            predicted = predictionData & 0x0FFF
        } else {
            predicted = nil
        }
        algorithmState = G7AlgorithmState(rawValue: data[14])
        if data[15] == 0x7F {
            trend = nil
        } else {
            trend = Double(Int8(bitPattern: data[15])) / 10
        }
        self.data = data
    }
}
