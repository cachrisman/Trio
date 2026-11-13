import Foundation

// Sends the diagnostic subset of device-log entries straight to the cloud sink. It deliberately bypasses
// TrioLogger: LogExport already merges DeviceLogStore, so tee'ing through AppLogStore would duplicate lines.
final class CloudDeviceLogForwarder: @unchecked Sendable {
    static let shared = CloudDeviceLogForwarder()

    private let policy: DeviceLogForwardingPolicy
    private let sink: LogSink

    init(policy: DeviceLogForwardingPolicy = DeviceLogForwardingPolicy(), sink: LogSink = CloudLogSink.shared) {
        self.policy = policy
        self.sink = sink
    }

    /// Called synchronously from `DeviceLogStore.log`, so the timestamp is the event time.
    func forward(managerIdentifier: String, typeRawValue: String, message: String) {
        let timestamp = Date()
        guard let decision = policy.decide(
            managerIdentifier: managerIdentifier,
            typeRawValue: typeRawValue,
            message: message
        ) else { return }
        // Category can't be derived cheaply here (DeviceLogStore doesn't know the active managers), so the
        // manager identifier rides in the message.
        sink.accept(LogRecord(
            timestamp: timestamp,
            level: decision.isWarning ? .warning : .info,
            category: "Device",
            message: decision.text,
            file: #fileID,
            function: #function,
            line: #line,
            launchID: LaunchID.current
        ))
    }
}
