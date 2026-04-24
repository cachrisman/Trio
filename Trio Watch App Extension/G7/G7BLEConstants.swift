import CoreBluetooth
import Foundation

// UUIDs match G7SensorKit `BluetoothServices.swift` (G7SensorKit/BluetoothServices.swift).

enum G7BLEAdvertisement {
    static let febc = CBUUID(string: "FEBC")
}

enum G7BLEService {
    static let cgm = CBUUID(string: "F8083532-849E-531C-C594-30F1F86A4EA5")
    static let serviceB = CBUUID(string: "F8084532-849E-531C-C594-30F1F86A4EA5")
}

enum G7BLECharacteristic {
    static let communication = CBUUID(string: "F8083533-849E-531C-C594-30F1F86A4EA5")
    static let control = CBUUID(string: "F8083534-849E-531C-C594-30F1F86A4EA5")
    static let authentication = CBUUID(string: "F8083535-849E-531C-C594-30F1F86A4EA5")
    static let backfill = CBUUID(string: "F8083536-849E-531C-C594-30F1F86A4EA5")
    // Service B (J-PAKE path) — G7SensorKit `ServiceBCharacteristicUUID`
    static let serviceB_E = CBUUID(string: "F8084533-849E-531C-C594-30F1F86A4EA5")
    static let serviceB_F = CBUUID(string: "F8084534-849E-531C-C594-30F1F86A4EA5")
}

enum G7Opcode: UInt8 {
    case authChallengeRx = 0x05
    case glucoseTx = 0x4E
    case backfillFinished = 0x59
}

/// Restoration identifier for same-device eavesdrop session (DiaBLE-style eager CBCentral; G7SensorKit also uses a stable ID).
let kG7DirectBLERestoreIdentifier = "com.trio.watchapp.g7directble.observer"
