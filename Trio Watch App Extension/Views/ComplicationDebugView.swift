import Combine
import SwiftUI
import WatchKit

struct ComplicationDebugView: View {
    private struct BleChecklistGate: Identifiable {
        let label: String
        let isSatisfied: Bool

        var id: String { label }
    }

    private enum BleChecklistStatus {
        case satisfied
        case blocker
        case pending
    }

    @State private var snapshot: TrioComplicationSnapshot?
    @State private var watchState = WatchState.shared
    @State private var showConfirmation = false
    @State private var confirmationMessage = ""
    @State private var refreshTrigger = UUID()
    @State private var autoRefreshTick = Date()

    @State private var watchLogCount: Int = 0
    @State private var watchLogBytes: UInt64 = 0
    @State private var drainCount: Int = 0
    @State private var drainBytes: UInt64 = 0
    @State private var pendingCount: Int = 0
    @State private var isLoadingLogFiles: Bool = false

    private let dataStore = TrioComplicationDataStore.shared
    private let autoRefreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var g7Manager: G7DirectBLEManager {
        watchState.g7DebugManager
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // SECTION 1: Data Store State
                sectionHeader("DATA STORE")
                dataStoreStateView

                Divider().padding(.vertical, 4)

                // SECTION 2: Direct BLE / G7 Observer
                sectionHeader("DIRECT BLE / G7 OBSERVER")
                directBleObserverView

                Divider().padding(.vertical, 4)

                // SECTION 3: Log Files
                sectionHeader("LOG FILES")
                logFilesView

                Divider().padding(.vertical, 4)

                // SECTION 4: Reload Status
                sectionHeader("RELOAD STATUS")
                reloadStatusView

                Divider().padding(.vertical, 4)

                // SECTION 5: Actions
                sectionHeader("ACTIONS")
                actionsView
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle("Debug")
        .onAppear {
            loadSnapshot()
            loadLogFileStats()
        }
        .onReceive(autoRefreshTimer) { date in
            autoRefreshTick = date
            loadSnapshot()
        }
        .overlay(confirmationOverlay)
        .id(refreshTrigger)
    }

    // MARK: - Data Store State Section

    private var dataStoreStateView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let s = snapshot {
                HStack {
                    Text("Glucose:")
                    Spacer()
                    Text(s.glucose)
                        .foregroundColor(glucoseColor(for: s.glucose))
                        .fontWeight(.bold)
                }

                HStack {
                    Text("Trend:")
                    Spacer()
                    Text(s.trend.isEmpty ? "--" : s.trend)
                }

                HStack {
                    Text("Delta:")
                    Spacer()
                    Text(s.delta)
                }

                HStack {
                    Text("Reading:")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formatTime(s.readingDate))
                        Text("(\(formatAge(s.readingDate)))")
                            .font(.caption2)
                            .foregroundColor(ageColor(s.readingDate))
                    }
                }

                HStack {
                    Text("Saved:")
                    Spacer()
                    Text(formatTime(s.date))
                }

                if let state = s.state, !state.isEmpty {
                    HStack {
                        Text("State:")
                        Spacer()
                        Text(state)
                            .foregroundColor(.orange)
                    }
                }
            } else {
                Text("No snapshot available")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            HStack {
                Text("Path:")
                Spacer()
                Text(truncatePath(dataStore.appGroupContainerPath))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Divider().padding(.vertical, 2)

            // App Group ID Debug Section
            sectionHeader("APP GROUP")

            HStack {
                Text("AppGroupID:")
                Spacer()
                if let appGroupID = dataStore.appGroupID {
                    Text(appGroupID)
                        .font(.system(size: 9))
                        .foregroundColor(.green)
                        .lineLimit(1)
                } else {
                    Text("Not Found")
                        .font(.system(size: 9))
                        .foregroundColor(.red)
                }
            }

            HStack {
                Text("Container:")
                Spacer()
                if dataStore.appGroupContainerURL != nil {
                    Text(dataStore.appGroupContainerAccessible ? "✓ Accessible" : "✗ Not Accessible")
                        .font(.system(size: 9))
                        .foregroundColor(dataStore.appGroupContainerAccessible ? .green : .red)
                } else {
                    Text("✗ No URL")
                        .font(.system(size: 9))
                        .foregroundColor(.red)
                }
            }

            if let containerURL = dataStore.appGroupContainerURL {
                HStack {
                    Text("Container Path:")
                    Spacer()
                    Text(truncatePath(containerURL.path))
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                HStack {
                    Text("Snapshot File:")
                    Spacer()
                    if dataStore.snapshotFileExists {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("✓ Exists")
                                .font(.system(size: 9))
                                .foregroundColor(.green)
                            if let size = dataStore.snapshotFileSize {
                                Text("\(size) bytes")
                                    .font(.system(size: 7))
                                    .foregroundColor(.secondary)
                            }
                            if let age = dataStore.snapshotFileAge {
                                Text("\(Int(age))s old")
                                    .font(.system(size: 7))
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        Text("✗ Missing")
                            .font(.system(size: 9))
                            .foregroundColor(.red)
                    }
                }

                if let files = try? FileManager.default.contentsOfDirectory(atPath: containerURL.path), !files.isEmpty {
                    HStack {
                        Text("Container Files:")
                        Spacer()
                        Text("\(files.count)")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .font(.caption)
    }

    // MARK: - Reload Status Section

    private var reloadStatusView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last reload:")
                Spacer()
                Text(formatTime(dataStore.lastReloadTimestamp))
            }

            HStack {
                Text("Elapsed:")
                Spacer()
                Text("\(Int(dataStore.secondsSinceLastReload))s ago")
            }

            HStack {
                Text("Debounce:")
                Spacer()
                if dataStore.isDebounceActive {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                        Text("\(Int(dataStore.secondsUntilNextReloadAllowed))s")
                    }
                    .foregroundColor(.red)
                } else {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Ready")
                    }
                    .foregroundColor(.green)
                }
            }
        }
        .font(.caption)
    }

    // MARK: - Direct BLE Observer Section

    private var directBleObserverView: some View {
        VStack(alignment: .leading, spacing: 4) {
            debugRow("Mode:", value: "Direct BLE Observer")
            debugRow("Session owner:", value: "Dexcom G7 app")
            debugRow("Using phone relay:", value: yesNo(watchState.isUsingPhoneRelayForCurrentWatchData))

            Divider().padding(.vertical, 2)

            sectionHeader("LATEST SESSION FUNNEL")
            Text("First yellow row = first unsatisfied gate")
                .font(.system(size: 9))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(bleChecklistGates.enumerated()), id: \.element.id) { index, gate in
                    bleChecklistRow(label: gate.label, status: bleChecklistStatus(for: gate, index: index))
                }
            }
            .padding(.top, 2)

            Divider().padding(.vertical, 2)

            sectionHeader("CURRENT BLOCKER")
            debugRow(
                "Current stage:",
                value: g7Manager.debugCurrentProtocolStageLabel,
                valueColor: stageColor(g7Manager.debugCurrentProtocolStageLabel)
            )
            debugMultilineRow(
                "Last blocked reason:",
                value: humanizeDebugValue(g7Manager.lastBlockedReason),
                valueColor: blockerColor(g7Manager.lastBlockedReason)
            )
            debugRow(
                "Last timeout stage:",
                value: humanizeDebugValue(g7Manager.debugTimeoutStage)
            )
            debugMultilineRow(
                "Last disconnect reason:",
                value: humanizeDebugValue(g7Manager.lastDisconnectReason)
            )
            debugMultilineRow(
                "Current session id:",
                value: g7Manager.currentG7SessionId ?? "--",
                monospaced: true
            )
        }
        .font(.caption)
    }

    // MARK: - Log Files Section

    private var logFilesView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Watch Logs:")
                Spacer()
                Text("\(watchLogCount) files, \(formatBytes(watchLogBytes))")
                    .foregroundColor(.secondary)
            }
            HStack {
                Text("Drain Files:")
                Spacer()
                Text("\(drainCount) files, \(formatBytes(drainBytes))")
                    .foregroundColor(.secondary)
            }
            HStack {
                Text("Pending:")
                Spacer()
                Text("\(pendingCount)")
                    .foregroundColor(pendingCount > 0 ? .yellow : .secondary)
            }
        }
        .font(.caption)
    }

    private func loadLogFileStats() {
        guard !isLoadingLogFiles else { return }
        isLoadingLogFiles = true
        Task {
            let fileManager = FileManager.default
            var wlCount = 0
            var wlBytes: UInt64 = 0
            var dcCount = 0
            var dcBytes: UInt64 = 0

            let logDir = fileManager.urls(
                for: .documentDirectory, in: .userDomainMask
            ).first?.appendingPathComponent("logs", isDirectory: true)

            if let logDir, let files = try? fileManager.contentsOfDirectory(
                at: logDir, includingPropertiesForKeys: [.fileSizeKey]
            ) {
                for file in files
                    where file.lastPathComponent.hasPrefix("watch_log_")
                    && file.lastPathComponent.hasSuffix(".txt")
                    && file.lastPathComponent != "watch_log_daily.txt" {
                    wlCount += 1
                    if let attrs = try? fileManager.attributesOfItem(
                        atPath: file.path
                    ), let size = attrs[.size] as? UInt64 {
                        wlBytes += size
                    }
                }
            }

            if let containerURL = ComplicationLogBuffer
                .sharedContainerURL() {
                let drainsDir = containerURL.appendingPathComponent(
                    "logs", isDirectory: true
                )
                if let files = try? fileManager.contentsOfDirectory(
                    at: drainsDir, includingPropertiesForKeys: [.fileSizeKey]
                ) {
                    for file in files
                        where file.lastPathComponent
                        .hasPrefix("complication_log.drain.")
                        && file.lastPathComponent.hasSuffix(".txt") {
                        dcCount += 1
                        if let attrs = try? fileManager.attributesOfItem(
                            atPath: file.path
                        ), let size = attrs[.size] as? UInt64 {
                            dcBytes += size
                        }
                    }
                }
            }

            let pCount = await WatchLogger.shared
                .getPendingPayloads().count

            await MainActor.run {
                watchLogCount = wlCount
                watchLogBytes = wlBytes
                drainCount = dcCount
                drainBytes = dcBytes
                pendingCount = pCount
                isLoadingLogFiles = false
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        return "\(bytes / 1024) KB"
    }

    // MARK: - Actions Section

    private var actionsView: some View {
        VStack(spacing: 8) {
            Button {
                Task {
                    await WatchLogger.shared.log("🔧 Debug: Force Reload tapped")
                }
                // scheduleRetry: false — debug view one-shot; no retry needed (Phase 1.3).
                dataStore.forceReload(scheduleRetry: false)
                showConfirmation(message: "✅ Reload triggered!")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    loadSnapshot()
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Force Reload")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.blue)

            Button {
                Task {
                    await WatchLogger.shared.log("🔧 Debug: Request Fresh Data tapped")
                }
                WatchState.shared.requestWatchStateUpdate()
                showConfirmation(message: "📡 Requesting...")
            } label: {
                HStack {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                    Text("Request Data")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)

            Button {
                loadSnapshot()
                loadLogFileStats()
                refreshTrigger = UUID()
                showConfirmation(message: "🔄 Refreshed")
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Refresh View")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.gray)
            .disabled(isLoadingLogFiles)

            Button {
                flushWatchLogs()
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Flush Logs")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.purple)
        }
    }

    private func flushWatchLogs() {
        Task {
            await WatchLogger.shared.log("⌚️ DEBUG manual flush requested", force: true)
            await WatchLogger.shared.flushIfNeeded(force: true)
            await WatchLogger.shared.flushPersistedLogs()
            await MainActor.run {
                showConfirmation(message: "📤 Logs flushed")
            }
        }
    }

    // MARK: - Confirmation Overlay

    private var confirmationOverlay: some View {
        Group {
            if showConfirmation {
                VStack {
                    Spacer()
                    Text(confirmationMessage)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .padding(.bottom, 20)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showConfirmation)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    private func debugRow(_ title: String, value: String, valueColor: Color = .primary) -> some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .foregroundColor(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private func debugMultilineRow(
        _ title: String,
        value: String,
        valueColor: Color = .primary,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? .system(size: 9, design: .monospaced) : .caption)
                .foregroundColor(valueColor)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadSnapshot() {
        snapshot = dataStore.latestSnapshot()
    }

    private func showConfirmation(message: String) {
        confirmationMessage = message
        showConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showConfirmation = false
        }
    }

    private func formatTime(_ date: Date) -> String {
        _ = autoRefreshTick
        if date == .distantPast { return "--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatAge(_ date: Date) -> String {
        if date == .distantPast { return "--" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    private func ageColor(_ date: Date) -> Color {
        if date == .distantPast { return .secondary }
        let age = Date().timeIntervalSince(date)
        if age < 300 { return .green }
        if age < 900 { return .yellow }
        return .red
    }

    private func glucoseColor(for value: String) -> Color {
        guard let glucose = Double(value) else { return .secondary }
        if glucose < 70 { return .red }
        if glucose > 180 { return .orange }
        return .green
    }

    private func truncatePath(_ path: String?) -> String {
        guard let path = path else { return "Unknown" }
        let components = path.components(separatedBy: "/")
        if components.count > 3 {
            return ".../" + components.suffix(2).joined(separator: "/")
        }
        return path
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private func stageColor(_ stage: String) -> Color {
        switch normalizedStageKey(stage) {
        case "connected":
            return .green
        case "error":
            return .red
        case "authenticating",
            "awaiting_auth",
            "awaiting_connect",
            "awaiting_control",
            "awaiting_egv",
            "awaiting_first_egv",
            "awaiting_gatt_setup",
            "connecting",
            "discovering_characteristics",
            "discovering_services",
            "scanning":
            return .yellow
        default:
            return .secondary
        }
    }

    private var bleChecklistGates: [BleChecklistGate] {
        [
            BleChecklistGate(label: "Filter armed", isSatisfied: g7Manager.latestSessionFilterArmed),
            BleChecklistGate(label: "Target matched", isSatisfied: g7Manager.latestSessionTargetMatched),
            BleChecklistGate(label: "Pre-connect sane", isSatisfied: g7Manager.latestSessionPreConnectSane),
            BleChecklistGate(label: "Connect attempt", isSatisfied: g7Manager.latestSessionConnectAttempted),
            BleChecklistGate(label: "Did connect", isSatisfied: g7Manager.latestSessionDidConnect),
            BleChecklistGate(label: "Services discovered", isSatisfied: g7Manager.latestSessionServicesDiscovered),
            BleChecklistGate(label: "Characteristics callback returned", isSatisfied: g7Manager.latestSessionCharacteristicsCallbackReturned),
            BleChecklistGate(label: "Required characteristics present", isSatisfied: g7Manager.latestSessionRequiredCharacteristicsPresent),
            BleChecklistGate(label: "Auth notify enabled", isSatisfied: g7Manager.latestSessionAuthNotifyEnabled),
            BleChecklistGate(label: "J-PAKE skipped", isSatisfied: g7Manager.latestSessionJpakeSkipped),
            BleChecklistGate(label: "0x03 seen", isSatisfied: g7Manager.latestSessionSawAuthChallenge03),
            BleChecklistGate(label: "0x05 authenticated", isSatisfied: g7Manager.latestSessionAuthenticated),
            BleChecklistGate(label: "0x05 bonded", isSatisfied: g7Manager.latestSessionBonded),
            BleChecklistGate(label: "Control notify enabled", isSatisfied: g7Manager.latestSessionControlNotifyEnabled),
            BleChecklistGate(label: "0x4E sent", isSatisfied: g7Manager.latestSessionEgvRequestSent),
            BleChecklistGate(label: "0x4E received", isSatisfied: g7Manager.latestSessionEgvResponseReceived),
            BleChecklistGate(label: "Snapshot saved", isSatisfied: g7Manager.latestSessionSnapshotSaved)
        ]
    }

    private var firstUnsatisfiedChecklistIndex: Int? {
        bleChecklistGates.firstIndex(where: { !$0.isSatisfied })
    }

    private func bleChecklistStatus(for gate: BleChecklistGate, index: Int) -> BleChecklistStatus {
        if gate.isSatisfied {
            return .satisfied
        }
        if firstUnsatisfiedChecklistIndex == index {
            return .blocker
        }
        return .pending
    }

    private func bleChecklistRow(label: String, status: BleChecklistStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: checklistSymbol(for: status))
                .foregroundColor(checklistColor(for: status))
                .frame(width: 12)
            Text(label)
                .foregroundColor(checklistColor(for: status))
                .fontWeight(status == .blocker ? .semibold : .regular)
            Spacer()
        }
    }

    private func checklistSymbol(for status: BleChecklistStatus) -> String {
        switch status {
        case .satisfied:
            return "checkmark.circle.fill"
        case .blocker:
            return "exclamationmark.circle.fill"
        case .pending:
            return "circle"
        }
    }

    private func checklistColor(for status: BleChecklistStatus) -> Color {
        switch status {
        case .satisfied:
            return .green
        case .blocker:
            return .yellow
        case .pending:
            return .secondary
        }
    }

    private func blockerColor(_ rawValue: String?) -> Color {
        guard let rawValue, !rawValue.isEmpty else { return .secondary }
        return .yellow
    }

    private func normalizedStageKey(_ stage: String) -> String {
        stage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }

    private func humanizeDebugValue(_ rawValue: String?) -> String {
        guard let rawValue, !rawValue.isEmpty else { return "--" }
        switch rawValue {
        case "service_discovery_failed":
            return "Service discovery failed"
        case "no_data_service":
            return "No data service"
        case "characteristic_discovery_failed":
            return "Characteristic discovery failed"
        case let value where value.hasPrefix("no_required_characteristic"):
            return value
                .replacingOccurrences(of: "no_required_characteristic", with: "No required characteristic")
        case let value where value.hasPrefix("notify_failed"):
            return value
                .replacingOccurrences(of: "notify_failed", with: "Notify failed")
                .replacingOccurrences(of: "_", with: " ")
        default:
            break
        }
        let humanized = rawValue.replacingOccurrences(of: "_", with: " ")
        guard let first = humanized.first else { return "--" }
        return first.uppercased() + humanized.dropFirst()
    }
}

#Preview {
    NavigationStack {
        ComplicationDebugView()
    }
}
