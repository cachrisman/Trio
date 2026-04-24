import Foundation

// Mirrors G7SensorKit `AlgorithmState.swift` (G7SensorKit/AlgorithmState.swift) for parsing only.

enum G7AlgorithmState: RawRepresentable, Equatable {
    typealias RawValue = UInt8

    enum State: UInt8 {
        case stopped = 1
        case warmup = 2
        case excessNoise = 3
        case firstOfTwoBGsNeeded = 4
        case secondOfTwoBGsNeeded = 5
        case ok = 6
        case needsCalibration = 7
        case calibrationError1 = 8
        case calibrationError2 = 9
        case calibrationLinearityFitFailure = 10
        case sensorFailedDuetoCountsAberration = 11
        case sensorFailedDuetoResidualAberration = 12
        case outOfCalibrationDueToOutlier = 13
        case outlierCalibrationRequest = 14
        case sessionExpired = 15
        case sessionFailedDueToUnrecoverableError = 16
        case sessionFailedDueToTransmitterError = 17
        case temporarySensorIssue = 18
        case sensorFailedDueToProgressiveSensorDecline = 19
        case sensorFailedDuetoHighCountsAberration = 20
        case sensorFailedDuetoLowCountsAberration = 21
        case sensorFailedDuetoRestart = 22
        case expired = 24
        case sensorFailed = 25
        case sessionEnded = 26
    }

    case known(State)
    case unknown(RawValue)

    init(rawValue: RawValue) {
        if let s = State(rawValue: rawValue) {
            self = .known(s)
        } else {
            self = .unknown(rawValue)
        }
    }

    var rawValue: RawValue {
        switch self {
        case .known(let s):
            s.rawValue
        case .unknown(let v):
            v
        }
    }

    var hasReliableGlucose: Bool {
        guard case .known(.ok) = self else { return false }
        return true
    }
}

enum G7GlucoseLimits {
    static let minimum: UInt16 = 40
    static let maximum: UInt16 = 400
}
