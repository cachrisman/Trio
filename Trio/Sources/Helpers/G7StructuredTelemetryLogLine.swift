import Foundation
import G7SensorKit

/// Canonical key order for G7 cloud logs: `module` → `sensor_name` → `event` → optional fields → `g7_session`.
/// Pipeline code may append further keys (e.g. battery) after this string.
enum G7StructuredTelemetryLogLine {
    /// G7SensorKit telemetry (`module=g7_core`).
    static func formatCoreTelemetry(sensorName: String, payload: G7TelemetryPayload, g7Session: String) -> String {
        let core: String
        if payload.fields.isEmpty {
            core = "module=g7_core sensor_name=\(sensorName) event=\(payload.event)"
        } else {
            core = "module=g7_core sensor_name=\(sensorName) event=\(payload.event) \(payload.fields)"
        }
        return "\(core) g7_session=\(g7Session)"
    }

    /// Watch direct BLE observer (`module=g7_ble`).
    static func formatBleModule(sensorName: String, event: String, fields: String, g7Session: String) -> String {
        let core: String
        if fields.isEmpty {
            core = "module=g7_ble sensor_name=\(sensorName) event=\(event)"
        } else {
            core = "module=g7_ble sensor_name=\(sensorName) event=\(event) \(fields)"
        }
        return "\(core) g7_session=\(g7Session)"
    }
}
