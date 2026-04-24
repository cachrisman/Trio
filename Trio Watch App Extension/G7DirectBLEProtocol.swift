import CoreBluetooth
import Foundation

enum G7BLEServiceUUID {
    static let advertisement = CBUUID(string: "FEBC")
    static let cgmService = CBUUID(string: "F8083532-849E-531C-C594-30F1F86A4EA5")
}

enum G7BLECharacteristicUUID {
    static let control = CBUUID(string: "F8083534-849E-531C-C594-30F1F86A4EA5")
    static let authentication = CBUUID(string: "F8083535-849E-531C-C594-30F1F86A4EA5")
    static let backfill = CBUUID(string: "F8083536-849E-531C-C594-30F1F86A4EA5")
    static let jpake = CBUUID(string: "F8084533-849E-531C-C594-30F1F86A4EA5")
}

enum G7BLEOpcode {
    static let authChallengeRx: UInt8 = 0x05
    static let glucoseTx: UInt8 = 0x4e
}

struct G7AuthState {
    let isAuthenticated: Bool
    let isBonded: Bool

    init?(data: Data) {
        guard data.count >= 3, data[0] == G7BLEOpcode.authChallengeRx else { return nil }
        isAuthenticated = data[1] == 0x01
        isBonded = data[2] == 0x01
    }
}

struct G7GlucoseReading {
    let glucose: Int
    let trendString: String
    let readingDate: Date
}

enum G7GlucoseParser {
    static func parse(_ data: Data) -> G7GlucoseReading? {
        guard data.count >= 19, data[0] == G7BLEOpcode.glucoseTx, data[1] == 0x00 else { return nil }

        let messageTimestamp = littleEndianUInt32(data[2..<6])
        let age = littleEndianUInt16(data[10..<12])
        let glucoseRaw = littleEndianUInt16(data[12..<14])
        guard glucoseRaw != 0xffff else { return nil }
        let glucose = Int(glucoseRaw & 0x0fff)

        let trendByte = data[15]
        let trendRate: Double? = trendByte == 0x7f ? nil : Double(Int8(bitPattern: trendByte)) / 10.0
        guard messageTimestamp >= UInt32(age) else { return nil }
        let readingDate = Date(timeIntervalSince1970: TimeInterval(messageTimestamp - UInt32(age)))

        return G7GlucoseReading(
            glucose: glucose,
            trendString: trendName(from: trendRate),
            readingDate: readingDate
        )
    }

    private static func littleEndianUInt16(_ slice: Data.SubSequence) -> UInt16 {
        var value: UInt16 = 0
        for (index, byte) in slice.enumerated() {
            value |= UInt16(byte) << (8 * index)
        }
        return value
    }

    private static func littleEndianUInt32(_ slice: Data.SubSequence) -> UInt32 {
        var value: UInt32 = 0
        for (index, byte) in slice.enumerated() {
            value |= UInt32(byte) << (8 * index)
        }
        return value
    }

    private static func trendName(from rate: Double?) -> String {
        guard let rate else { return "Flat" }
        switch rate {
        case let x where x <= -3.0: return "DoubleDown"
        case let x where x <= -2.0: return "SingleDown"
        case let x where x <= -1.0: return "FortyFiveDown"
        case let x where x < 1.0: return "Flat"
        case let x where x < 2.0: return "FortyFiveUp"
        case let x where x < 3.0: return "SingleUp"
        default: return "DoubleUp"
        }
    }
}

extension Data {
    var hexPreview: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
