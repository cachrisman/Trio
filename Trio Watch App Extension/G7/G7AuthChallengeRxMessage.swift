import Foundation

// G7SensorKit `AuthChallengeRxMessage.swift` (G7SensorKit/Messages/AuthChallengeRxMessage.swift).

struct G7AuthChallengeRxMessage: Equatable {
    let isAuthenticated: Bool
    let isBonded: Bool

    init?(data: Data) {
        guard data.count >= 3 else { return nil }
        guard data[0] == G7Opcode.authChallengeRx.rawValue else { return nil }
        isAuthenticated = data[1] == 0x01
        isBonded = data[2] == 0x01
    }
}
