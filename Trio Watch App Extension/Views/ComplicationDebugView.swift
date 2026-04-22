import Combine
import SwiftUI

struct ComplicationDebugView: View {
    private enum HelpSheet: String, Identifiable {
        case dataStore
        case directBleOverview
        case lifecycle
        case runtimeCycle
        case attachContext
        case retrieval
        case sessionFunnel
        case currentBlocker
        case logFiles
        case reloadStatus
        case actions

        var id: String { rawValue }

        var navigationTitle: String {
            switch self {
            case .dataStore: return "Data store"
            case .directBleOverview: return "Direct G7 BLE"
            case .lifecycle: return "Lifecycle"
            case .runtimeCycle: return "Runtime + cycle"
            case .attachContext: return "Attach context"
            case .retrieval: return "Retrieval"
            case .sessionFunnel: return "Session funnel"
            case .currentBlocker: return "Current blocker"
            case .logFiles: return "Log files"
            case .reloadStatus: return "Reload status"
            case .actions: return "Actions"
            }
        }
    }

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
    @State private var activeHelpSheet: HelpSheet?

    private let dataStore = TrioComplicationDataStore.shared
    private let snapshotRefreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    private let logStatsRefreshTimer = Timer.publish(every: 10.0, on: .main, in: .common).autoconnect()

    private var g7Manager: G7DirectBLEManager {
        watchState.g7DebugManager
    }

    /// True when any blocker-related debug field should be shown (non-empty category/source/reasons or a timestamp).
    private var hasCurrentBlockerSectionContent: Bool {
        if hasNonEmptyOptionalString(g7Manager.lastBlockerCategory) { return true }
        if hasNonEmptyOptionalString(g7Manager.lastBlockerSource) { return true }
        if hasNonEmptyOptionalString(g7Manager.lastBlockerReasonRaw) { return true }
        if hasNonEmptyOptionalString(g7Manager.lastBlockedReason) { return true }
        if g7Manager.lastBlockerAt != nil { return true }
        return false
    }

    private func hasNonEmptyOptionalString(_ s: String?) -> Bool {
        guard let s = s?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !s.isEmpty else { return false }
        return true
    }

    /// Cycle anchor label with optional ` (bootstrap)` suffix; bootstrap without anchor → `bootstrap (no anchor)`.
    private func cycleAnchorDisplayString() -> String {
        let raw = g7Manager.debugCurrentCycleAnchorSource?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        if g7Manager.debugCurrentCycleBootstrap == true {
            if raw.isEmpty {
                return "bootstrap (no anchor)"
            }
            return "\(humanizeDebugValue(g7Manager.debugCurrentCycleAnchorSource)) (bootstrap)"
        }
        return humanizeDebugValue(g7Manager.debugCurrentCycleAnchorSource)
    }

    /// Prefer direct-BLE EGV time; fall back to the saved complication snapshot so the ring is useful before BLE succeeds.
    private var arcReferenceReadingDate: Date? {
        g7Manager.lastReadingDate ?? snapshot?.readingDate
    }

    private var readingCycleProgressArcOverlay: some View {
        _ = autoRefreshTick
        return GeometryReader { _ in
            let elapsed = Date().timeIntervalSince(arcReferenceReadingDate ?? .distantPast)
            let fraction = min(1.0, max(0.0, elapsed / 300.0))
            let arcColor: Color = fraction < 0.7 ? .green : (fraction < 0.9 ? .yellow : .red)
            let lineWidth: CGFloat = 4

            ZStack {
                ContainerRelativeShape()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: fraction)
                    .stroke(
                        arcColor,
                        style: StrokeStyle(
                            lineWidth: lineWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
            }
            .allowsHitTesting(false)
            .animation(.linear(duration: 0.95), value: autoRefreshTick)
        }
        .allowsHitTesting(false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("DATA STORE", help: .dataStore)
                dataStoreStateView

                Divider().padding(.vertical, 4)

                sectionHeader("DIRECT G7 BLE", help: .directBleOverview)
                directBleObserverView

                Divider().padding(.vertical, 4)

                sectionHeader("LOG FILES", help: .logFiles)
                logFilesView

                Divider().padding(.vertical, 4)

                sectionHeader("RELOAD STATUS", help: .reloadStatus)
                reloadStatusView

                Divider().padding(.vertical, 4)

                sectionHeader("ACTIONS", help: .actions)
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
        .overlay {
            readingCycleProgressArcOverlay
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .overlay(confirmationOverlay)
        .sheet(item: $activeHelpSheet) { sheet in
            NavigationStack {
                ScrollView {
                    helpContent(for: sheet)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .navigationTitle(sheet.navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { activeHelpSheet = nil }
                    }
                }
            }
        }
    }

    private var dataStoreStateView: some View {
        _ = autoRefreshTick
        return VStack(alignment: .leading, spacing: 4) {
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
        // `G7DirectBLEManager` is `@ObservationIgnored` on `WatchState`; depend on the same 1s tick as
        // `formatTime` so these rows refresh without requiring unrelated `WatchState` mutations.
        _ = autoRefreshTick
        return VStack(alignment: .leading, spacing: 6) {
            sectionHeader("LIFECYCLE", help: .lifecycle)
            debugRow(
                "Current lifecycle:",
                value: g7Manager.debugCurrentProtocolStageLabel,
                valueColor: stageColor(g7Manager.debugCurrentProtocolStageLabel)
            )
            debugRow("Terminal outcome:", value: humanizeDebugValue(g7Manager.lastTerminalOutcome))
            if hasNonEmptyOptionalString(g7Manager.lastTerminalReason) {
                debugMultilineRow("Terminal reason:", value: humanizeDebugValue(g7Manager.lastTerminalReason))
            }
            if hasNonEmptyOptionalString(g7Manager.lastTerminalStage) {
                debugRow("Terminal stage:", value: humanizeDebugValue(g7Manager.lastTerminalStage))
            }
            debugRow("Timeout stage:", value: humanizeDebugValue(g7Manager.debugTimeoutStage))
            if hasNonEmptyOptionalString(g7Manager.lastDisconnectReason) {
                debugMultilineRow("Disconnect reason:", value: humanizeDebugValue(g7Manager.lastDisconnectReason))
            }
            debugRow("Last stage change:", value: formatOptionalTime(g7Manager.lastStageTransitionAt))
            debugRow("Last terminal at:", value: formatOptionalTime(g7Manager.lastTerminalAt))

            Divider().padding(.vertical, 2)

            sectionHeader("RUNTIME + CYCLE", help: .runtimeCycle)
            debugRow(
                "Runtime state:",
                value: g7Manager.debugRuntimeStateLabel,
                valueColor: runtimeStateColor(g7Manager.debugRuntimeStateLabel)
            )
            debugRow("Runtime active:", value: boolLabel(g7Manager.isExtendedRuntimeSessionActive))
            debugRow(
                "Cycle state:",
                value: g7Manager.debugCycleStatusLabel,
                valueColor: cycleStateColor(g7Manager.debugCycleStatusLabel)
            )
            debugMultilineRow("Session ID:", value: truncateDebugId(g7Manager.currentG7SessionId))
            debugMultilineRow("Cycle ID:", value: truncateDebugId(g7Manager.debugCurrentCycleID))
            debugRow(
                "Cycle anchor:",
                value: cycleAnchorDisplayString()
            )
            debugRow(
                "Expected reading:",
                value: formatOptionalTime(g7Manager.debugCurrentCycleExpectedReadingDate)
            )
            debugRow(
                "Lead window:",
                value: formatOptionalTime(g7Manager.debugCurrentCycleLeadWindowDate)
            )
            debugRow(
                "Grace close:",
                value: formatOptionalTime(g7Manager.debugCurrentCycleGraceCloseDate)
            )

            Divider().padding(.vertical, 2)

            sectionHeader("ATTACH CONTEXT", help: .attachContext)
            debugRow(
                "Rendered data source:",
                value: watchState.isUsingPhoneRelayForCurrentWatchData ? "Phone relay" : "Direct BLE"
            )
            debugRow("Attach source:", value: humanizeDebugValue(g7Manager.lastAttachSource))
            debugRow("Active filter:", value: humanizeDebugValue(g7Manager.activePeripheralName))
            debugRow("Filter armed:", value: boolLabel(g7Manager.hasActivePeripheralNameFilter))
            debugRow("Last seen peripheral:", value: humanizeDebugValue(g7Manager.lastSeenPeripheralName))
            debugRow("RSSI:", value: intLabel(g7Manager.debugDisplayRssi))
            debugRow("Seen at:", value: formatOptionalTime(g7Manager.lastSeenPeripheralAt))
            if hasNonEmptyOptionalString(g7Manager.lastPersistedPeripheralIdentifierShort) {
                debugRow("Persisted ID:", value: humanizeDebugValue(g7Manager.lastPersistedPeripheralIdentifierShort))
            }
            debugRow("Peripheral state:", value: peripheralStateLabel(g7Manager.lastPreConnectPeripheralState))
            debugRow("Central state:", value: centralStateLabel(g7Manager.lastPreConnectCentralState))
            debugRow("Connectable:", value: connectableLabel(g7Manager.lastPreConnectIsConnectable))
            debugRow("Preserved session:", value: boolLabel(g7Manager.lastPreConnectPreservedSession))
            debugRow(
                "Allocated in startScanning:",
                value: boolLabel(g7Manager.lastPreConnectAllocatedCentralInStartScanning)
            )

            Divider().padding(.vertical, 2)

            sectionHeader("RETRIEVAL", help: .retrieval)
            debugRow("Identifier count:", value: intLabel(g7Manager.lastRetrievedIdentifierCount))
            debugRow("Connected count:", value: intLabel(g7Manager.lastRetrievedConnectedCount))
            Button("Clear stored identifier") {
                g7Manager.clearStoredPeripheralIdentifier()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            if hasNonEmptyOptionalString(g7Manager.lastIdentifierRetrievalSkipReason) {
                debugMultilineRow(
                    "Identifier skip reason:",
                    value: humanizeDebugValue(g7Manager.lastIdentifierRetrievalSkipReason)
                )
            }
            if hasNonEmptyOptionalString(g7Manager.lastIdentifierRetrievalPeripheralName) {
                debugRow(
                    "Identifier skip peripheral:",
                    value: humanizeDebugValue(g7Manager.lastIdentifierRetrievalPeripheralName)
                )
            }

            Divider().padding(.vertical, 2)

            sectionHeader("SESSION FUNNEL", help: .sessionFunnel)
            bleChecklistSection

            Divider().padding(.vertical, 2)

            sectionHeader("CURRENT BLOCKER", help: .currentBlocker)
            if !hasCurrentBlockerSectionContent {
                Text("No active blocker — attach / GATT / observation paths have not recorded a blocking condition for this session.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if hasNonEmptyOptionalString(g7Manager.lastBlockerCategory) {
                    debugRow("Category:", value: humanizeDebugValue(g7Manager.lastBlockerCategory))
                }
                if hasNonEmptyOptionalString(g7Manager.lastBlockerSource) {
                    debugRow("Source:", value: humanizeDebugValue(g7Manager.lastBlockerSource))
                }
                if hasNonEmptyOptionalString(g7Manager.lastBlockerReasonRaw) {
                    debugMultilineRow(
                        "Reason:",
                        value: humanizeDebugValue(g7Manager.lastBlockerReasonRaw),
                        valueColor: blockerColor(g7Manager.lastBlockerReasonRaw)
                    )
                }
                if hasNonEmptyOptionalString(g7Manager.lastBlockedReason) {
                    debugMultilineRow(
                        "Last blocked reason:",
                        value: humanizeDebugValue(g7Manager.lastBlockedReason),
                        valueColor: blockerColor(g7Manager.lastBlockedReason)
                    )
                }
                if g7Manager.lastBlockerAt != nil {
                    debugRow("Last blocker at:", value: formatOptionalTime(g7Manager.lastBlockerAt))
                }
            }
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
        _ = autoRefreshTick
        return VStack(alignment: .leading, spacing: 4) {
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

    private func sectionHeader(_ title: String, help: HelpSheet? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            if let help {
                Button {
                    activeHelpSheet = help
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    /// Short prefix for UUID/session strings on a small watch screen (full values remain in remote logs).
    private func truncateDebugId(_ raw: String?, prefixLength: Int = 8) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "--"
        }
        if raw.count <= prefixLength { return raw }
        return String(raw.prefix(prefixLength)) + "…"
    }

    @ViewBuilder
    private func helpContent(for sheet: HelpSheet) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch sheet {
            case .dataStore:
                helpLine("Glucose / trend / delta", "Latest values from the saved complication snapshot (may be phone relay or direct BLE).")
                helpLine("Reading", "CGM reading time embedded in the payload; age is wall-clock vs now.")
                helpLine("Saved", "When this snapshot was written to the shared data store.")
                helpLine("State", "Optional warning string from the snapshot pipeline.")
            case .directBleOverview:
                helpLine("Purpose", "Foreground Dexcom G7 direct-BLE session: scan, connect, auth, passive EGV, snapshot save.")
                helpLine("Outer ring", "Progress vs 5 minutes since the last reading time: direct-BLE `lastReadingDate` when set, otherwise the data-store snapshot’s `readingDate` (e.g. phone relay). Green → yellow → red; updates every second.")
                helpLine("Subsections", "Use the info buttons on Lifecycle, Runtime, Attach, etc. for field-level detail.")
                helpLine("Refresh", "Rows refresh every second; the BLE manager is not `@Observable` on `WatchState`.")
            case .lifecycle:
                helpLine("Current lifecycle", "High-level protocol stage label (scanning, connecting, GATT, awaiting EGV, …).")
                helpLine("Terminal outcome / reason / stage", "Last session end classification if the session reached a terminal state.")
                helpLine("Timeout / disconnect", "Last timeout stage and CB disconnect reason string.")
                helpLine("Timestamps", "When the stage last changed and when a terminal outcome was recorded.")
            case .runtimeCycle:
                helpLine("Runtime", "WKExtendedRuntimeSession state for keeping BLE alive while foreground.")
                helpLine("Cycle", "Cadence planner state within the current glucose cycle (attach window, lead, grace, …).")
                helpLine("Session / cycle ID", "Truncated identifiers; full UUIDs appear in structured logs.")
                helpLine("Cycle anchor", "Timing anchor source; `(bootstrap)` suffix when the cycle is bootstrapped, or `bootstrap (no anchor)` when bootstrapped without an anchor string.")
                helpLine("Expected / lead / grace", "Scheduled times for reading, lead window, and cycle close.")
            case .attachContext:
                helpLine("Rendered data source", "Whether the watch UI last updated from phone relay or direct BLE snapshot.")
                helpLine("Attach source", "scan, retrieved_*, connection_event — how attach started.")
                helpLine("Filter", "Phone-supplied active sensor name filter for connect decisions.")
                helpLine("RSSI", "Prefer RSSI captured when the last glucose EGV was processed; else last advertisement/connect RSSI.")
                helpLine("Pre-connect fields", "Snapshot of CB peripheral/central state and advertisement connectable flag at connect attempt.")
            case .retrieval:
                helpLine("Identifier count", "Peripherals returned when resolving the stored CB UUID.")
                helpLine("Connected count", "System-connected peripherals matching G7 services.")
                helpLine("Skip reason", "Why a retrieved peripheral was not used (e.g. filter mismatch).")
            case .sessionFunnel:
                helpLine("Purpose", "Gate checklist for the latest attach attempt (filter → connect → GATT → auth → EGV → snapshot).")
                helpLine("Expand", "Tap the header to show all gates; collapsed view scrolls around the first failing gate.")
                helpLine("Pre-connect context", "May show pending (not blocking) when attach did not start from a scan advertisement.")
            case .currentBlocker:
                helpLine("When empty", "No attach/auth/observation blocker was recorded — normal when the session is healthy.")
                helpLine("When set", "`setBlockerDebugState` recorded a reason (missing filter, GATT failure, passive gate, …). Cleared on `resetDebugSessionContext` (e.g. new scan).")
                helpLine("Last blocked reason", "Separate internal `lastBlockedReason` string when present (e.g. notify/GATT path).")
            case .logFiles:
                helpLine("Drain files", "Complication log drains in the app group container.")
                helpLine("Watch logs", "On-device watch_log_* chunks pending upload.")
                helpLine("Pending", "Count of log payloads queued for transfer.")
            case .reloadStatus:
                helpLine("Last reload", "When the complication last triggered a timeline reload.")
                helpLine("Elapsed / debounce", "Cooldown to avoid reload storms; red while debounced.")
            case .actions:
                helpLine("Force reload", "Requests complication timeline reload from the data store.")
                helpLine("Request data", "Asks the phone for a fresh WatchConnectivity payload.")
                helpLine("Flush logs", "Forces logger flush / upload routines for debugging.")
            }
        }
    }

    private func helpLine(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
            Text(detail)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

    private func formatOptionalTime(_ date: Date?) -> String {
        guard let date else { return "--" }
        return formatTime(date)
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
        let lowered = stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.hasPrefix("timed out") || lowered.hasPrefix("failed") {
            return .red
        }
        if lowered.hasPrefix("disconnected") {
            return .orange
        }
        if lowered == "waiting for next reading" || lowered.hasPrefix("completed") {
            return .green
        }
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
            "awaiting_runtime_activation",
            "connecting",
            "discovering_characteristics",
            "discovering_services",
            "executing_attach_window",
            "scanning":
            return .yellow
        default:
            return .secondary
        }
    }

    private func runtimeStateColor(_ state: String) -> Color {
        switch normalizedStageKey(state) {
        case "active":
            return .green
        case "expiring", "starting":
            return .yellow
        case "invalidated":
            return .orange
        default:
            return .secondary
        }
    }

    private func cycleStateColor(_ state: String) -> Color {
        switch normalizedStageKey(state) {
        case "connected_in_cycle":
            return .green
        case "awaiting_egv",
            "awaiting_runtime_activation",
            "executing_attach_window",
            "same-cycle_retry_scheduled",
            "waiting_for_lead_window":
            return .yellow
        case "cycle_overdue", "runtime_invalidated":
            return .orange
        default:
            return .secondary
        }
    }

    private var bleChecklistGates: [BleChecklistGate] {
        [
            BleChecklistGate(label: "Filter armed", isSatisfied: g7Manager.latestSessionFilterArmed),
            BleChecklistGate(label: "Target matched", isSatisfied: g7Manager.latestSessionTargetMatched),
            BleChecklistGate(label: "Pre-connect context", isSatisfied: g7Manager.latestSessionPreConnectSane),
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
            BleChecklistGate(label: "Communication notify enabled", isSatisfied: g7Manager.latestSessionCommunicationNotifyEnabled),
            BleChecklistGate(label: "Control notify enabled", isSatisfied: g7Manager.latestSessionControlNotifyEnabled),
            BleChecklistGate(label: "Passive observation armed", isSatisfied: g7Manager.latestSessionPassiveObservationArmed),
            BleChecklistGate(label: "Fallback 0x4E sent", isSatisfied: g7Manager.latestSessionFallbackEgvRequestSent),
            BleChecklistGate(label: "0x4E received", isSatisfied: g7Manager.latestSessionEgvResponseReceived),
            BleChecklistGate(label: "Snapshot saved", isSatisfied: g7Manager.latestSessionSnapshotSaved)
        ]
    }

    private var firstUnsatisfiedChecklistIndex: Int? {
        bleChecklistGates.indices.first { index in
            let gate = bleChecklistGates[index]
            if gate.isSatisfied {
                return false
            }
            if gate.label == "Pre-connect context", g7Manager.lastAttachSource != "scan" {
                return false
            }
            return true
        }
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
        if gate.label == "Pre-connect context", g7Manager.lastAttachSource != "scan" {
            return .pending
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

    private func boolLabel(_ value: Bool?) -> String {
        guard let value else { return "--" }
        return value ? "Yes" : "No"
    }

    private func connectableLabel(_ value: String?) -> String {
        switch value {
        case "true":
            return "Yes"
        case "false":
            return "No"
        case let value?:
            return humanizeDebugValue(value)
        case nil:
            return "--"
        }
    }

    private func intLabel(_ value: Int?) -> String {
        guard let value else { return "--" }
        return String(value)
    }

    private func peripheralStateLabel(_ rawValue: Int?) -> String {
        switch rawValue {
        case 0:
            return "Disconnected"
        case 1:
            return "Connecting"
        case 2:
            return "Connected"
        case 3:
            return "Disconnecting"
        case let value?:
            return String(value)
        case nil:
            return "--"
        }
    }

    private func centralStateLabel(_ rawValue: Int?) -> String {
        switch rawValue {
        case 0:
            return "Unknown"
        case 1:
            return "Resetting"
        case 2:
            return "Unsupported"
        case 3:
            return "Unauthorized"
        case 4:
            return "Powered off"
        case 5:
            return "Powered on"
        case let value?:
            return String(value)
        case nil:
            return "--"
        }
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
