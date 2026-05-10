import SwiftUI
import WatchKit

struct ComplicationDebugView: View {
    @State private var snapshot: TrioComplicationSnapshot?
    @State private var showConfirmation = false
    @State private var confirmationMessage = ""

    @State private var watchLogCount: Int = 0
    @State private var watchLogBytes: UInt64 = 0
    @State private var drainCount: Int = 0
    @State private var drainBytes: UInt64 = 0
    @State private var pendingCount: Int = 0
    @State private var isLoadingLogFiles: Bool = false
    /// Ticks every second to drive live countdown, age display, and nav title
    /// regardless of whether snapshot has changed (snapshot is Equatable — unchanged
    /// readings produce no-op @State assignments and no re-render without this).
    @State private var now: Date = Date()

    private let dataStore = TrioComplicationDataStore.shared

    // Static formatter — allocated once, reused every 1s tick (item 21)
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Nav title (item 2)

    private var navTitle: String {
        guard let s = snapshot, s.readingDate != .distantPast else { return "Debug" }
        let t = trendSymbol(s.trend)
        var parts = [s.glucose, t, s.delta].filter { !$0.isEmpty }
        parts.append(nextReadingCountdown(s.readingDate, relativeTo: now))
        return parts.joined(separator: " ")
    }

    // MARK: - Body

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

                // SECTION 3: G7 Direct BLE
                sectionHeader("G7 DIRECT BLE")
                G7DirectBleDebugSection()

                Divider().padding(.vertical, 4)

                // SECTION 4: Actions
                sectionHeader("ACTIONS")
                actionsView
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle(navTitle)
        .onAppear {
            loadSnapshot()
            loadLogFileStats()
        }
        // Unified 1s task — snapshot every tick, file stats every 5s (items 18, 20)
        // `now` updated unconditionally to drive countdown/age even when snapshot is unchanged.
        .task {
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                now = Date()
                loadSnapshot()
                tick += 1
                if tick % 5 == 0 {
                    loadLogFileStats()
                }
            }
        }
        .overlay(confirmationOverlay)
    }

    // MARK: - Data Store State Section (items 3–9)

    private var dataStoreStateView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let s = snapshot {
                HStack(spacing: 8) {
                    Text(s.glucose)
                        .foregroundColor(glucoseColor(for: s.glucose))
                        .fontWeight(.bold)
                    Text(s.trend.isEmpty ? "—" : trendSymbol(s.trend))
                    Text(s.delta)
                }
                .font(.title3)

                // item 3: source row
                HStack {
                    Text("Source:")
                    Spacer()
                    Text(s.source?.shortLabel ?? "?")
                        .foregroundColor(.cyan)
                }

                HStack {
                    Text("Reading:")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formatTime(s.readingDate))
                        Text("(\(Int(now.timeIntervalSince(s.readingDate)))s ago)")

                            .font(.caption2)
                            .foregroundColor(ageColor(s.readingDate, relativeTo: now))
                    }
                }

                // item 4: next reading countdown — only meaningful for BLE source where
                // 5-min cadence is authoritative. Phone/HK readings may be delayed,
                // backfilled, or gap-filled; showing a countdown would be misleading.
                if s.source == .g7DirectBLE {
                    HStack {
                        Text("Next:")
                        Spacer()
                        Text(nextReadingCountdown(s.readingDate, relativeTo: now))
                            .foregroundColor(nextReadingColor(s.readingDate, relativeTo: now))
                            .monospacedDigit()
                    }
                }

                HStack {
                    Text("Saved:")
                    Spacer()
                    Text(formatTime(s.date))
                }

            } else {
                Text("No snapshot available")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            // items 7–8: always visible — most useful when there's no snapshot yet
            HStack {
                Text("Last reload:")
                Spacer()
                Text("\(formatTime(dataStore.lastReloadTimestamp)) (\(Int(dataStore.secondsSinceLastReload))s ago)")
            }

            HStack {
                Text("Debounce:")
                Spacer()
                if dataStore.isDebounceActive {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("\(Int(dataStore.secondsUntilNextReloadAllowed))s")
                    }
                    .foregroundColor(.red)
                } else {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("Ready")
                    }
                    .foregroundColor(.green)
                }
            }
            // items 5, 6: State and Path rows removed
        }
        .font(.caption)
        // item 9: removed .id(refreshTrigger) — @State snapshot drives re-renders
    }

    // MARK: - Log Files Section (item 10)

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
            // item 10: composite upload status replaces bare Pending row
            HStack {
                Text("Upload status:")
                Spacer()
                uploadStatusView
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var uploadStatusView: some View {
        if pendingCount > 0 {
            // Fast phase: payload sent to phone, awaiting ACK
            HStack(spacing: 4) {
                Circle().fill(Color.yellow).frame(width: 8, height: 8)
                Text("ACK pending (\(pendingCount))")
                    .foregroundColor(.yellow)
            }
        } else if watchLogCount > 0 || drainCount > 0 {
            // Slow phase: files not yet transferred/deleted
            HStack(spacing: 4) {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
                Text("\(watchLogCount)L · \(drainCount)D queued")
                    .foregroundColor(.orange)
            }
        } else {
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Clean")
                    .foregroundColor(.green)
            }
        }
    }

    @MainActor private func loadLogFileStats() {
        guard !isLoadingLogFiles else { return }
        isLoadingLogFiles = true
        Task {
            // item 19: isLoadingLogFiles always cleared via MainActor.run at end;
            // no early returns inside Task body so this path is always reached.
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
                    if let attrs = try? fileManager.attributesOfItem(atPath: file.path),
                       let size = attrs[.size] as? UInt64 {
                        wlBytes += size
                    }
                }
            }

            if let containerURL = ComplicationLogBuffer.sharedContainerURL() {
                let drainsDir = containerURL.appendingPathComponent("logs", isDirectory: true)
                if let files = try? fileManager.contentsOfDirectory(
                    at: drainsDir, includingPropertiesForKeys: [.fileSizeKey]
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
                triggerConfirmation(message: "✅ Reload triggered!")
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
                triggerConfirmation(message: "📡 Requesting...")
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
                triggerConfirmation(message: "📤 Logs flushed")
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

    @MainActor private func loadSnapshot() {
        snapshot = dataStore.latestSnapshot()
    }

    // item 20: renamed from showConfirmation(message:) to eliminate property/method name collision
    @MainActor private func triggerConfirmation(message: String) {
        confirmationMessage = message
        showConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showConfirmation = false
        }
    }

    private func formatTime(_ date: Date) -> String {
        if date == .distantPast { return "--" }
        return Self.timeFormatter.string(from: date)
    }

    private func formatAge(_ date: Date, relativeTo now: Date = Date()) -> String {
        if date == .distantPast { return "--" }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    private func ageColor(_ date: Date, relativeTo now: Date = Date()) -> Color {
        if date == .distantPast { return .secondary }
        let age = now.timeIntervalSince(date)
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

    // item 2: trend arrow → unicode symbol for nav title
    private func trendSymbol(_ trend: String) -> String {
        switch trend {
        case "DoubleDown":    return "↓↓"
        case "SingleDown":    return "↓"
        case "FortyFiveDown": return "↘"
        case "Flat":          return "→"
        case "FortyFiveUp":   return "↗"
        case "SingleUp":      return "↑"
        case "DoubleUp":      return "↑↑"
        default:              return trend.isEmpty ? "" : "~"
        }
    }

    // item 4: countdown to anticipated next reading
    // G7 nominal cadence is 5 min; all current sources (BLE, Phone, HK) deliver on this schedule.
    private static let expectedReadingCadence: TimeInterval = 300

    private func nextReadingCountdown(_ date: Date, relativeTo now: Date = Date()) -> String {
        if date == .distantPast { return "--" }
        let remaining = Int(date.addingTimeInterval(Self.expectedReadingCadence).timeIntervalSince(now))
        if remaining < 0 { return "⚠️+\(abs(remaining))s" }
        return "\(remaining)s"
    }

    private func nextReadingColor(_ date: Date, relativeTo now: Date = Date()) -> Color {
        if date == .distantPast { return .secondary }
        return date.addingTimeInterval(Self.expectedReadingCadence).timeIntervalSince(now) < 0 ? .red : .primary
    }
}

/// G7 debug rows: read `WatchState` from this type's `body` so updates observe reliably (vs. a
/// `private var` on the parent). DATA STORE / log stats still use the unified 1s task poll.
private struct G7DirectBleDebugSection: View {
    // item 21: static formatter
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // item 12: status now reflects build 191 state machine via updated enum
            HStack {
                Text("Status:")
                Spacer()
                Text(WatchState.shared.g7DirectBleStatus.rawValue)
            }
            // items 13–14: bleLastConnectAt / bleLastEGVDate / bleLastEGVValue (updated by `G7WatchSensorAdapter`)
            HStack {
                Text("Last connect:")
                Spacer()
                Text(formatG7Time(WatchState.shared.bleLastConnectAt))
            }
            HStack {
                Text("Last BLE EGV:")
                Spacer()
                if let d = WatchState.shared.bleLastEGVDate,
                   let v = WatchState.shared.bleLastEGVValue {
                    Text("\(formatG7Time(d)) · \(v) mg/dL")
                } else {
                    Text("--")
                }
            }
            HStack {
                Text("Connects:")
                Spacer()
                Text("\(WatchState.shared.bleConnectsToday)")
            }
            HStack {
                Text("EGVs:")
                Spacer()
                Text("\(WatchState.shared.bleEGVsToday)")
            }
            // Phone-relay sensor name (UserDefaults via adapter) — must match WC `g7_active_sensor_name` sync.
            HStack {
                Text("Phone sensor filter:")
                Spacer()
                Text(G7WatchSensorAdapter.shared.telemetrySensorName)
                    .foregroundColor(.secondary)
            }
            // item 16: live WatchState source vs persisted snapshot — mismatches are diagnostic
            HStack {
                Text("Live source:")
                Spacer()
                Text(WatchState.shared.displayedReadingSource.watchBadgeText)
                    .foregroundColor(.cyan)
            }
            // item 15: Was Restored removed — structurally dead (observer pattern,
            // willRestoreState never fires for Trio's non-owning central)
        }
        .font(.caption)
    }

    private func formatG7Time(_ date: Date?) -> String {
        guard let date, date != .distantPast else { return "--" }
        return Self.timeFormatter.string(from: date)
    }
}

#Preview {
    NavigationStack {
        ComplicationDebugView()
    }
}
