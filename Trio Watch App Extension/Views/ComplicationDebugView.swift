import Combine
import SwiftUI

struct ComplicationDebugView: View {
    private struct BleChecklistGate: Identifiable {
        let label: String
        let isSatisfied: Bool

        var id: String { label }
    }

    private struct VisibleBleChecklistGate: Identifiable {
        let gate: BleChecklistGate
        let status: BleChecklistStatus

        var id: String { gate.id }
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
    @State private var confirmationToken = UUID()
    @State private var autoRefreshTick = Date()
    @State private var isBleChecklistExpanded = false

    @State private var watchLogCount = 0
    @State private var watchLogBytes: UInt64 = 0
    @State private var drainCount = 0
    @State private var drainBytes: UInt64 = 0
    @State private var pendingCount = 0
    @State private var isLoadingLogFiles = false
    @State private var pendingLogStatsReload = false

    private let dataStore = TrioComplicationDataStore.shared
    private let snapshotRefreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    private let logStatsRefreshTimer = Timer.publish(every: 10.0, on: .main, in: .common).autoconnect()

    private var g7Manager: G7DirectBLEManager {
        watchState.g7DebugManager
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("DATA STORE")
                dataStoreStateView

                Divider().padding(.vertical, 4)

                sectionHeader("DIRECT G7 BLE")
                directBleObserverView

                Divider().padding(.vertical, 4)

                sectionHeader("LOG FILES")
                logFilesView

                Divider().padding(.vertical, 4)

                sectionHeader("RELOAD STATUS")
                reloadStatusView

                Divider().padding(.vertical, 4)

                sectionHeader("ACTIONS")
                actionsView
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle("Debug")
        .onAppear {
            loadSnapshot()
            loadLogFileStats(force: true)
        }
        .onReceive(snapshotRefreshTimer) { date in
            autoRefreshTick = date
            loadSnapshot()
        }
        .onReceive(logStatsRefreshTimer) { _ in
            loadLogFileStats()
        }
        .overlay(confirmationOverlay)
    }

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
        }
        .font(.caption)
    }

    private var directBleObserverView: some View {
        VStack(alignment: .leading, spacing: 6) {
            debugRow(
                "Current UI source:",
                value: watchState.isUsingPhoneRelayForCurrentWatchData ? "Phone relay" : "Direct BLE"
            )

            let nextUpdateSeconds: Int
            if let readingDate = snapshot?.readingDate {
                let targetDate = readingDate.addingTimeInterval(5 * 60)
                nextUpdateSeconds = max(0, Int(ceil(targetDate.timeIntervalSinceNow)))
            } else {
                nextUpdateSeconds = 0
            }

            debugRow("Next update:", value: "\(nextUpdateSeconds)s")
            debugRow(
                "Current stage:",
                value: g7Manager.debugCurrentProtocolStageLabel,
                valueColor: stageColor(g7Manager.debugCurrentProtocolStageLabel)
            )

            Divider().padding(.vertical, 2)

            bleChecklistSection

            Divider().padding(.vertical, 2)

            sectionHeader("CURRENT BLOCKER")
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
        }
        .font(.caption)
    }

    private var bleChecklistSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isBleChecklistExpanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("LATEST SESSION FUNNEL")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Spacer()
                        Image(systemName: isBleChecklistExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text(bleChecklistCaption)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ZStack {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(visibleBleChecklistGates) { item in
                        bleChecklistRow(label: item.gate.label, status: item.status)
                    }
                }
                .padding(.vertical, 6)

                bleChecklistOverflowOverlay
            }
        }
    }

    private var bleChecklistOverflowOverlay: some View {
        VStack(spacing: 0) {
            if bleChecklistHasHiddenAbove {
                ZStack(alignment: .top) {
                    LinearGradient(
                        colors: [Color.black.opacity(0.28), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 12)

                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.75))
                        .padding(.top, 1)
                }
            } else {
                Color.clear.frame(height: 12)
            }

            Spacer()

            if bleChecklistHasHiddenBelow {
                ZStack(alignment: .bottom) {
                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(0.28)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 12)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.75))
                        .padding(.bottom, 1)
                }
            } else {
                Color.clear.frame(height: 12)
            }
        }
        .allowsHitTesting(false)
    }

    private var logFilesView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Drain Files:")
                Spacer()
                Text("\(drainCount) files, \(formatBytes(drainBytes))")
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Watch Logs:")
                Spacer()
                Text("\(watchLogCount) files, \(formatBytes(watchLogBytes))")
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

    private var actionsView: some View {
        VStack(spacing: 8) {
            Button {
                Task {
                    await WatchLogger.shared.log("🔧 Debug: Force Reload tapped")
                }
                dataStore.forceReload(scheduleRetry: false)
                presentConfirmation(message: "Reload triggered")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    loadSnapshot()
                    loadLogFileStats(force: true)
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
                presentConfirmation(message: "Requesting fresh data")
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
            .disabled(isLoadingLogFiles)
        }
    }

    private func loadLogFileStats(force: Bool = false) {
        if isLoadingLogFiles {
            if force {
                pendingLogStatsReload = true
            }
            return
        }

        isLoadingLogFiles = true
        pendingLogStatsReload = false

        Task {
            let fileManager = FileManager.default
            var wlCount = 0
            var wlBytes: UInt64 = 0
            var dcCount = 0
            var dcBytes: UInt64 = 0

            let logDir = fileManager.urls(
                for: .documentDirectory, in: .userDomainMask
            ).first?.appendingPathComponent("logs", isDirectory: true)

            if let logDir,
               let files = try? fileManager.contentsOfDirectory(
                at: logDir,
                includingPropertiesForKeys: [.fileSizeKey]
               ) {
                for file in files
                where file.lastPathComponent.hasPrefix("watch_log_")
                    && file.lastPathComponent.hasSuffix(".txt")
                    && file.lastPathComponent != "watch_log_daily.txt" {
                    wlCount += 1
                    if let attrs = try? fileManager.attributesOfItem(atPath: file.path),
                       let size = attrs[.size] as? UInt64 {
                        wlBytes += size
                    }
                }
            }

            if let containerURL = ComplicationLogBuffer.sharedContainerURL() {
                let drainsDir = containerURL.appendingPathComponent("logs", isDirectory: true)
                if let files = try? fileManager.contentsOfDirectory(
                    at: drainsDir,
                    includingPropertiesForKeys: [.fileSizeKey]
                ) {
                    for file in files
                    where file.lastPathComponent.hasPrefix("complication_log.drain.")
                        && file.lastPathComponent.hasSuffix(".txt") {
                        dcCount += 1
                        if let attrs = try? fileManager.attributesOfItem(atPath: file.path),
                           let size = attrs[.size] as? UInt64 {
                            dcBytes += size
                        }
                    }
                }
            }

            let pCount = await WatchLogger.shared.getPendingPayloads().count

            await MainActor.run {
                watchLogCount = wlCount
                watchLogBytes = wlBytes
                drainCount = dcCount
                drainBytes = dcBytes
                pendingCount = pCount
                isLoadingLogFiles = false
                if pendingLogStatsReload {
                    loadLogFileStats(force: true)
                }
            }
        }
    }

    private func flushWatchLogs() {
        presentConfirmation(message: "Log flush requested")

        Task {
            await WatchLogger.shared.log("⌚️ DEBUG manual flush requested", force: true)
            await WatchLogger.shared.flushIfNeeded(force: true)
            await WatchLogger.shared.flushPersistedLogs()
            await MainActor.run {
                loadLogFileStats(force: true)
                presentConfirmation(message: "Log flush routine completed")
            }
        }
    }

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

    private func presentConfirmation(message: String) {
        confirmationMessage = message
        showConfirmation = true
        let token = UUID()
        confirmationToken = token

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard confirmationToken == token else { return }
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

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        return "\(bytes / 1024) KB"
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

    private var visibleBleChecklistIndices: [Int] {
        let total = bleChecklistGates.count
        guard !isBleChecklistExpanded, total > 5 else {
            return Array(bleChecklistGates.indices)
        }

        if let blockerIndex = firstUnsatisfiedChecklistIndex {
            var indices = Array(max(0, blockerIndex - 3)...min(total - 1, blockerIndex + 1))

            while indices.count < 5 {
                if let first = indices.first, first > 0 {
                    indices.insert(first - 1, at: 0)
                } else if let last = indices.last, last < total - 1 {
                    indices.append(last + 1)
                } else {
                    break
                }
            }

            return indices
        }

        return Array(max(0, total - 5) ..< total)
    }

    private var visibleBleChecklistGates: [VisibleBleChecklistGate] {
        visibleBleChecklistIndices.map { index in
            let gate = bleChecklistGates[index]
            return VisibleBleChecklistGate(
                gate: gate,
                status: bleChecklistStatus(for: gate, index: index)
            )
        }
    }

    private var bleChecklistHasHiddenAbove: Bool {
        guard !isBleChecklistExpanded, let first = visibleBleChecklistIndices.first else { return false }
        return first > 0
    }

    private var bleChecklistHasHiddenBelow: Bool {
        guard !isBleChecklistExpanded, let last = visibleBleChecklistIndices.last else { return false }
        return last < bleChecklistGates.count - 1
    }

    private var bleChecklistCaption: String {
        if isBleChecklistExpanded {
            return "Showing all \(bleChecklistGates.count) steps"
        }
        return "\(visibleBleChecklistIndices.count) of \(bleChecklistGates.count) shown"
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
            return value.replacingOccurrences(of: "no_required_characteristic", with: "No required characteristic")
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
