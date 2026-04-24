import CoreBluetooth
import Foundation

/// UUIDs, opcodes, and other constants for eavesdropping on the Dexcom G7's
/// BLE session via same-device CoreBluetooth sharing.
///
/// **On-wire authority:** values here mirror
/// `G7SensorKit/BluetoothServices.swift` and
/// `G7SensorKit/Messages/G7Opcode.swift`. They match DiaBLE's equivalents
/// (`DiaBLE/Dexcom.swift` / `DiaBLE/DexcomG7.swift`). Do not rename casually;
/// BetterStack filters reference the opcode hex values.
///
/// **Observer-only safety:** this file intentionally omits any J-PAKE /
/// app-key authentication opcodes. The watch observer must never own or
/// initiate G7 authentication. See
/// `docs/in-progress/watch-g7-direct-ble-observer/01-design.md` §3.
enum G7DirectBLEConstants {

    // MARK: - Service / characteristic UUIDs

    /// Advertisement-service short UUID (0xFEBC). Used as a scan filter and
    /// as one of the service lists passed to
    /// `retrieveConnectedPeripherals(withServices:)`.
    static let advertisementServiceUUID = CBUUID(string: "FEBC")

    /// Primary G7 CGM data service. Contains auth / control / backfill
    /// characteristics.
    static let cgmServiceUUID = CBUUID(string: "F8083532-849E-531C-C594-30F1F86A4EA5")

    /// Auxiliary service carrying J-PAKE characteristics. Observer does not
    /// subscribe here — discovered only so the skip can be logged.
    static let serviceBUUID = CBUUID(string: "F8084532-849E-531C-C594-30F1F86A4EA5")

    /// Read/notify — rarely used by the observer; kept for completeness.
    static let communicationCharacteristicUUID =
        CBUUID(string: "F8083533-849E-531C-C594-30F1F86A4EA5")

    /// Write/indicate — carries EGV / version / battery commands and
    /// responses. Observer writes `egvRequestOpcode` here.
    static let controlCharacteristicUUID =
        CBUUID(string: "F8083534-849E-531C-C594-30F1F86A4EA5")

    /// Write/indicate — carries auth challenge notifications.
    /// Observer subscribes but never writes.
    static let authenticationCharacteristicUUID =
        CBUUID(string: "F8083535-849E-531C-C594-30F1F86A4EA5")

    /// Read/write/notify — carries backfill packets after an EGV request.
    static let backfillCharacteristicUUID =
        CBUUID(string: "F8083536-849E-531C-C594-30F1F86A4EA5")

    /// J-PAKE characteristic on service B. Observer discovers only.
    static let jpakeCharacteristicUUID =
        CBUUID(string: "F8084533-849E-531C-C594-30F1F86A4EA5")

    // MARK: - Opcodes (G7Opcode equivalents)

    /// Incoming notification prefix on the authentication characteristic
    /// indicating an `AuthChallengeRxMessage`. See
    /// `G7SensorKit/Messages/AuthChallengeRxMessage.swift`.
    static let authChallengeRxOpcode: UInt8 = 0x05

    /// EGV request opcode: observer writes `[0x4e]` on the control
    /// characteristic and the sensor responds on control with an
    /// `0x4e`-prefixed 19-byte payload. See
    /// `G7SensorKit/Messages/G7GlucoseMessage.swift`.
    static let egvRequestOpcode: UInt8 = 0x4e

    /// Session-stop prefix (observed, never written).
    static let sessionStopOpcode: UInt8 = 0x28

    /// Extended version request/reply prefix (observed, not written by
    /// observer — no functional need).
    static let extendedVersionTxOpcode: UInt8 = 0x52
    static let extendedVersionRxOpcode: UInt8 = 0x53

    /// Backfill-finished marker on control (observed).
    static let backfillFinishedOpcode: UInt8 = 0x59

    // MARK: - Restoration / persistence keys

    /// `CBCentralManagerOptionRestoreIdentifierKey` value. Distinct from
    /// DiaBLE's and from any Trio iPhone-side central. Do not change.
    static let centralRestorationIdentifier = "trio.g7.observer.v1"

    /// Watch-local `UserDefaults` key storing the most recently successful
    /// peripheral identifier (`UUID.uuidString`). App-group not required —
    /// the observer only exists on the watch.
    static let preferredPeripheralIdentifierKey = "trio.g7.observer.preferredPeripheralUUID"

    /// After this many consecutive connect failures for the persisted
    /// identifier, clear it and fall back to service retrieval / scan.
    static let preferredPeripheralClearAfterConsecutiveFailures = 5

    // MARK: - Name matching

    /// G7 peripheral name prefix.
    static let g7NamePrefix = "DXCM"

    /// Dexcom ONE+ peripheral name prefix (same protocol family; accepted
    /// because both references accept it).
    static let dexcomOnePlusNamePrefix = "DX02"

    /// Returns true if `name` matches the accepted G7-family prefix list.
    static func nameMatchesG7(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return name.hasPrefix(g7NamePrefix) || name.hasPrefix(dexcomOnePlusNamePrefix)
    }

    // MARK: - Timing

    /// Fallback timer for the auth advance condition (design §8). If Trio
    /// hasn't observed an authenticated+bonded auth challenge within this
    /// window after auth-notify enable, advance anyway.
    static let authAdvanceFallbackSeconds: TimeInterval = 6

    /// EGV-request fallback cadence (design §9). If no EGV has arrived in
    /// this window while connected and control-ready, write the request
    /// again.
    static let egvFallbackTimerSeconds: TimeInterval = 330  // 5m30s

    /// "Stalled" threshold for the UI status (design §14). Observer state
    /// reports `.stalled` if connected + ready but no EGV in this window.
    static let uiStalledThresholdSeconds: TimeInterval = 360  // 6 min

    /// Reconnect backoff schedule in seconds. Index saturates at the end.
    static let reconnectBackoffSeconds: [TimeInterval] = [2, 5, 10, 20, 30]

    /// Cap on control-write retries per connect cycle (design §10).
    static let maxControlWriteRetriesPerCycle = 3

    /// Delay before retrying a failed control write (design §10).
    static let controlWriteRetryDelaySeconds: TimeInterval = 10

    // MARK: - Logging event families

    enum Event {
        static let lifecycle = "g7_ble_lifecycle"
        static let centralState = "g7_ble_central_state"
        static let scanStart = "g7_ble_scan_start"
        static let scanStopped = "g7_ble_scan_stopped"
        static let peripheralDiscovered = "g7_ble_peripheral_discovered"
        static let peripheralSkipped = "g7_ble_peripheral_skipped"
        static let connectAttempt = "g7_ble_connect_attempt"
        static let didConnect = "g7_ble_did_connect"
        static let connectFailed = "g7_ble_connect_failed"
        static let didDisconnect = "g7_ble_did_disconnect"
        static let willRestoreState = "g7_ble_will_restore_state"
        static let servicesDiscovered = "g7_ble_services_discovered"
        static let characteristicsDiscovered = "g7_ble_characteristics_discovered"
        static let authNotifyEnabled = "g7_ble_auth_notify_enabled"
        static let controlNotifyEnabled = "g7_ble_control_notify_enabled"
        static let backfillNotifyEnabled = "g7_ble_backfill_notify_enabled"
        static let jpakeSkipped = "g7_ble_jpake_skipped"
        static let authPayloadReceived = "g7_ble_auth_payload_received"
        static let advanceReady = "g7_ble_advance_ready"
        static let egvRequestSent = "g7_ble_egv_request_sent"
        static let egvRequestWriteFailed = "g7_ble_egv_request_write_failed"
        static let egvReceived = "g7_ble_egv_received"
        static let backfillPacket = "g7_ble_backfill_packet_received"
        static let snapshotSaved = "g7_ble_snapshot_saved"
        static let blockedNoPeripheral = "g7_ble_blocked_no_peripheral"
        static let blockedAuthIncomplete = "g7_ble_blocked_auth_incomplete"
        static let blockedControlNotReady = "g7_ble_blocked_control_not_ready"
        static let sessionOutcome = "g7_ble_session_outcome"
    }

    /// Attribution tags for `connect_attempt` / `did_connect` (design §5).
    enum ConnectSource: String {
        case retrievedIdentifier = "retrieved_identifier"
        case retrievedDataService = "retrieved_data_service"
        case retrievedFebc = "retrieved_febc"
        case scan
        case restored
    }
}
