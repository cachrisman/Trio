import SwiftUI
import WatchKit

struct ComplicationDebugView: View {
    @State private var snapshot: TrioComplicationSnapshot?
    @State private var showConfirmation = false
    @State private var confirmationMessage = ""
    @State private var refreshTrigger = UUID()

    @State private var watchLogCount: Int = 0
    @State private var watchLogBytes: UInt64 = 0
    @State private var drainCount: Int = 0
    @State private var drainBytes: UInt64 = 0
    @State private var pendingCount: Int = 0
    @State private var isLoadingLogFiles: Bool = false

    private let dataStore = TrioComplicationDataStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // SECTION 1: Data Store State
                sectionHeader("DATA STORE")
                dataStoreStateView

                Divider().padding(.vertical, 4)

                // SECTION 2: Log Files
                sectionHeader("LOG FILES")
                logFilesView

                Divider().padding(.vertical, 4)

                // SECTION 3: Reload Status
                sectionHeader("RELOAD STATUS")
                reloadStatusView

                Divider().padding(.vertical, 4)

                // SECTION 4: G7 Direct BLE
                sectionHeader("G7 DIRECT BLE")
                G7DirectBleDebugSection()

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
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                loadSnapshot()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                loadLogFileStats()
                refreshTrigger = UUID()
            }
        }
        .overlay(confirmationOverlay)
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
        }
        .font(.caption)
        .id(refreshTrigger)
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
        .id(refreshTrigger)
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
}

/// G7 debug rows: read `WatchState` from this type’s `body` so updates observe reliably (vs. a
/// `private var` on the parent). DATA STORE / log stats still use `refreshTrigger` and `.task` poll.
private struct G7DirectBleDebugSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Status:")
                Spacer()
                Text(WatchState.shared.g7DirectBleStatus.rawValue)
            }
            HStack {
                Text("Last connect:")
                Spacer()
                if let t = WatchState.shared.bleLastConnectAt {
                    Text(formatG7Time(t))
                } else {
                    Text("--")
                }
            }
            HStack {
                Text("Last BLE EGV:")
                Spacer()
                if let d = WatchState.shared.bleLastEGVDate, let v = WatchState.shared.bleLastEGVValue {
                    Text("\(formatG7Time(d)) · \(v) mg/dL")
                } else {
                    Text("--")
                }
            }
            HStack {
                Text("Connects / today:")
                Spacer()
                Text("\(WatchState.shared.bleConnectsToday)")
            }
            HStack {
                Text("EGVs / today:")
                Spacer()
                Text("\(WatchState.shared.bleEGVsToday)")
            }
            HStack {
                Text("MOD-E / today:")
                Spacer()
                Text("\(WatchState.shared.bleConnectionEventsToday)")
            }
            HStack {
                Text("Was restored:")
                Spacer()
                Text(WatchState.shared.bleWasRestored ? "Yes" : "No")
            }
        }
        .font(.caption)
    }

    private func formatG7Time(_ date: Date) -> String {
        if date == .distantPast { return "--" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}

#Preview {
    NavigationStack {
        ComplicationDebugView()
    }
}
