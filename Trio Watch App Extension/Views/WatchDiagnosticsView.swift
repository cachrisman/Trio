import G7SensorKit // C-217-D1/D2: G7BLEDiagnosticsSnapshot
import SwiftUI
import WatchKit

struct WatchDiagnosticsView: View {
    @State private var snapshot: TrioComplicationSnapshot?
    @State private var showConfirmation = false
    @State private var confirmationMessage = ""
    @State private var confirmationClearWorkItem: DispatchWorkItem? // W10: coalesce overlapping clears

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

    /// C-217-D1/D2: BLE diagnostics snapshot for the G7 section. Refreshed ONLY on the 5s branch
    /// of the polling task (and once in `.onAppear`) — `bleDiagnostics()` is a blocking
    /// `managerQueue.sync` hop and must NEVER be called at the 1 Hz tick rate.
    @State private var bleDiag: G7BLEDiagnosticsSnapshot?

    /// Scene phase, used **only** to drive the `isActive` `@State` flag via `.onChange`.
    /// **Do not read directly from inside the `.task` polling loop** — the task closure captures
    /// `self` (a value-type view struct) at task creation, so a captured `scenePhase` would be
    /// frozen at its initial value and would never reflect later scene-phase transitions.
    /// `isActive` (below) is the actual gate the loop reads, because `@State`-backed values are
    /// observed through SwiftUI's storage and are safe to read from a long-lived concurrent Task.
    @Environment(\.scenePhase) private var scenePhase

    /// `true` while the watch app is in `.active` scene phase. Mirror of `scenePhase` written via
    /// `.onChange(of: scenePhase)` and read from the 1Hz polling task to gate per-second work.
    /// Defaults to `true` so the very first ticks after `.onAppear` (before any scene-phase
    /// transition is observed) are not unnecessarily suppressed.
    @State private var isActive: Bool = true

    // C-217 D-7: watch-local kill-switches for the Task-2 wedge escalation and Task-4 central
    // re-init. Keys MUST match G7WatchSensorAdapter.Keys.killSwitch* (applied to the fork's
    // G7BackgroundHints flags at launch by applyKillSwitchesFromDefaults). Default ON.
    @AppStorage("G7WatchAdapter.killSwitch.connectWedgeEscalation") private var wedgeEscalationEnabled = true
    @AppStorage("G7WatchAdapter.killSwitch.centralReinit") private var centralReinitEnabled = true

    // C-217 D-8: live-tunable edge-ring geometry (dial in on-wrist, then hardcode as defaults).
    // Behavioral values (fraction math, color thresholds) are deliberately NOT tunable.
    @AppStorage("g7.ring.cornerRadius") private var ringCornerRadius: Double = 37
    @AppStorage("g7.ring.lineWidth") private var ringLineWidth: Double = 6
    @AppStorage("g7.ring.insetX") private var ringInsetX: Double = 4
    @AppStorage("g7.ring.insetY") private var ringInsetY: Double = 3
    @AppStorage("g7.ring.trackOpacity") private var ringTrackOpacity: Double = 0

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
                glucoseHeadlineView

                Divider().padding(.vertical, 4)

                sectionHeader("G7 DIRECT BLE")
                G7DirectBleDebugSection(now: now, diag: bleDiag)

                Divider().padding(.vertical, 4)

                sectionHeader("LOGS")
                logFilesView

                Divider().padding(.vertical, 4)

                sectionHeader("DATA STORE")
                dataStoreStateView

                Divider().padding(.vertical, 4)

                sectionHeader("ESCALATION")
                escalationControlsView

                Divider().padding(.vertical, 4)

                sectionHeader("ACTIONS")
                actionsView
                    .padding(.bottom, 8)

                Divider().padding(.vertical, 4)

                sectionHeader("RING TUNING")
                ringTuningView
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle(navTitle)
        .onAppear {
            loadSnapshot()
            loadLogFileStats()
            bleDiag = G7WatchSensorAdapter.shared.bleDiagnostics() // C-217-D1: seed once; 5s tick thereafter
        }
        .onChange(of: scenePhase) { _, newPhase in
            isActive = (newPhase == .active)
        }
        // Unified 1s task — snapshot every tick, file stats every 5s (items 18, 20).
        // `now` updated unconditionally to drive countdown/age even when snapshot is unchanged.
        //
        // **Invariant:** the loop continues running while the view exists, but skips work
        // (no `now` tick, no `loadSnapshot()`, no `loadLogFileStats()`) whenever the watch app
        // is not in `.active` scene phase. This eliminates 1Hz log-store reads (and the
        // `latestSnapshot()` cascade) while the user is on the watch face or in another app.
        //
        // **Correctness note:** the gate reads `isActive` (a `@State`-backed mirror of
        // `scenePhase`) instead of `scenePhase` directly. The `.task` closure captures `self`
        // by value at task creation, so a directly-captured `@Environment(\.scenePhase)` would
        // be **frozen** at the value present at view first-appear and would never observe later
        // background ↔ active transitions, defeating the suspension entirely.
        .task {
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard isActive else { continue }
                now = Date()
                loadSnapshot()
                tick += 1
                if tick % 5 == 0 {
                    loadLogFileStats()
                    // C-217-D1/D2: refresh at the 5s cadence ONLY — bleDiagnostics() blocks on the
                    // sensor's managerQueue (queue-sync hop); never move this to the 1 Hz path.
                    bleDiag = G7WatchSensorAdapter.shared.bleDiagnostics()
                }
            }
        }
        .overlay(edgeCycleRing)
        .overlay(confirmationOverlay)
    }

    // MARK: - Glucose Headline

    @ViewBuilder
    private var glucoseHeadlineView: some View {
        if let s = snapshot {
            HStack(spacing: 8) {
                Text(s.glucose)
                    .foregroundColor(glucoseColor(for: s.glucose))
                    .fontWeight(.bold)
                Text(s.trend.isEmpty ? "—" : trendSymbol(s.trend))
                Text(s.delta)
            }
            .font(.title)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
        } else {
            Text("No snapshot available")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Escalation kill-switches (C-217 D-7)

    private var escalationControlsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $wedgeEscalationEnabled) {
                Text("Wedge escalation (T2)")
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .onChange(of: wedgeEscalationEnabled) { _, newValue in
                G7BackgroundHints.isConnectWedgeEscalationEnabled = newValue
                G7WatchSensorAdapter.shared.logKillSwitchToggled("connect_wedge_escalation", enabled: newValue)
            }
            Toggle(isOn: $centralReinitEnabled) {
                Text("Central re-init (T4)")
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .onChange(of: centralReinitEnabled) { _, newValue in
                G7BackgroundHints.isCentralReinitEnabled = newValue
                G7WatchSensorAdapter.shared.logKillSwitchToggled("central_reinit", enabled: newValue)
            }
        }
    }

    // MARK: - Edge cycle ring (C-217 D-8)

    /// Full-perimeter ring tracing the screen edge; fills clockwise from top-center over the 5-min
    /// CGM cycle (reference = the displayed reading's date). Stepped from the 1 Hz `now` tick — NO
    /// `.animation` (resume-sweep glitch); trim-based — NO `.rotationEffect`.
    private var edgeCycleRing: some View {
        let fraction = g7CountdownFraction(from: WatchState.shared.bleLastConnectAt, to: now) // C-218 E-1: next-connect cycle, matches the "Next connect:" row
        return ZStack {
            EdgeRingShape(cornerRadius: CGFloat(ringCornerRadius), insetX: CGFloat(ringInsetX), insetY: CGFloat(ringInsetY))
                .stroke(Color.white.opacity(ringTrackOpacity), lineWidth: CGFloat(ringLineWidth))
            EdgeRingShape(cornerRadius: CGFloat(ringCornerRadius), insetX: CGFloat(ringInsetX), insetY: CGFloat(ringInsetY))
                .trim(from: 0, to: fraction)
                .stroke(g7CountdownRingColor(fraction), style: StrokeStyle(lineWidth: CGFloat(ringLineWidth), lineCap: .round))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var ringTuningView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ringStepper("Corner", $ringCornerRadius, range: 20...80, step: 1, format: "%.0f")
            ringStepper("Width", $ringLineWidth, range: 1...6, step: 1, format: "%.0f")
            ringStepper("Inset X", $ringInsetX, range: -12...12, step: 1, format: "%.0f")
            ringStepper("Inset Y", $ringInsetY, range: -12...12, step: 1, format: "%.0f")
            ringStepper("Track", $ringTrackOpacity, range: 0...0.5, step: 0.02, format: "%.2f")
        }
        .font(.caption)
    }

    private func ringStepper(_ label: String, _ value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: String) -> some View {
        // C-218 E-3/E-4: plain -/+ Buttons instead of a native Stepper. The watchOS Stepper binds the
        // Digital Crown to its value (so the crown adjusted a knob instead of scrolling the view) and
        // its focus-mode buttons occluded the wrapping label. Plain Buttons don't capture the crown, so
        // the ScrollView keeps it for vertical scroll; +/- adjust the value, clamped to `range`.
        HStack(spacing: 4) {
            Text(label)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 2)
            Text(String(format: format, value.wrappedValue))
                .monospacedDigit()
                .foregroundColor(.secondary)
                .lineLimit(1)
            Button {
                value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            Button {
                value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Data Store State Section (items 3–9)

    private var dataStoreStateView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let s = snapshot {
                // item 3: source row
                HStack {
                    Text("Source:")
                    Spacer()
                    Text(s.source?.shortLabel ?? "?")
                        .foregroundColor(.cyan)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }

                HStack {
                    Text("Reading:")
                    Spacer()
                    Text(formatTime(s.readingDate))
                        .foregroundColor(ageColor(s.readingDate, relativeTo: now))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }

                HStack {
                    Text("Saved:")
                    Spacer()
                    Text(formatTime(s.date))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }

            // items 7–8: always visible — most useful when there's no snapshot yet
            HStack {
                Text("Last reload:")
                Spacer()
                Text(formatTime(dataStore.lastReloadTimestamp))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            HStack {
                Text("Debounce:")
                Spacer()
                if dataStore.isDebounceActive {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("\(Int(dataStore.secondsUntilNextReloadAllowed))s")
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .foregroundColor(.red)
                } else {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("Ready")
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
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
                Text("Upload:").lineLimit(1)
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
                Text("ACK (\(pendingCount))")
                    .foregroundColor(.yellow)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        } else if watchLogCount > 0 || drainCount > 0 {
            // Slow phase: files not yet transferred/deleted
            HStack(spacing: 4) {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
                Text("\(watchLogCount)L · \(drainCount)D queued")
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        } else {
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Clean")
                    .foregroundColor(.green)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
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
            // C-216 (Task D): telemetry-only recovery marker — lets the user self-report "I
            // restarted the app/watch to fix a stalled signal" so the moment correlates against
            // surrounding BLE diagnostics. No other behavior change.
            Button {
                G7WatchSensorAdapter.shared.logManualRecoveryMarker()
                triggerConfirmation(message: "📝 Marked")
            } label: {
                HStack {
                    Image(systemName: "bandage")
                    Text("Mark: restarted to fix signal")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.gray)

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
        // W10: cancel the prior 1.5s clear before scheduling a new one, so rapid taps don't let an
        // earlier clear hide a later confirmation.
        confirmationClearWorkItem?.cancel()
        let work = DispatchWorkItem { showConfirmation = false }
        confirmationClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func formatTime(_ date: Date) -> String {
        if date == .distantPast { return "--" }
        return Self.timeFormatter.string(from: date)
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
        // UI-207-3: match the main bubble — use the shared user-threshold / dynamic-color computer (W5)
        // instead of hard-coded 70/180, so the debug header color tracks the user's settings.
        return WatchGlucoseColorComputer.shared.bubbleColor(for: Int(glucose.rounded()))
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
    /// Driven by parent's 1s tick so countdown rows re-render even when underlying state is unchanged.
    let now: Date

    /// C-217-D1/D2: BLE diagnostics polled by the PARENT at the 5s cadence only (blocking
    /// `managerQueue.sync` hop inside `bleDiagnostics()` — never refresh at 1 Hz). nil until first poll.
    let diag: G7BLEDiagnosticsSnapshot?

    /// G7 nominal cadence (matches `WatchDiagnosticsView.expectedReadingCadence`).
    private static let expectedCadence: TimeInterval = 300

    // item 21: static formatter
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Capture (slots):")
                Spacer()
                Text(slotCaptureText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            HStack {
                Text("Last connect:")
                Spacer()
                Text(formatG7Time(WatchState.shared.bleLastConnectAt))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            HStack {
                Text("Next connect:")
                Spacer()
                Text(nextConnectCountdown(WatchState.shared.bleLastConnectAt))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            HStack {
                Text("Last BLE EGV:")
                Spacer()
                if let d = WatchState.shared.bleLastEGVDate,
                   let v = WatchState.shared.bleLastEGVValue {
                    Text("\(formatG7Time(d)) · \(v)")
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                } else {
                    Text("--")
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            HStack {
                Text("Since EGV:")
                Spacer()
                Text(sinceEGVDisplay)
                    .foregroundColor(sinceEGVColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            HStack {
                Text("Pre-EGV disconnects:")
                Spacer()
                Text("\(G7WatchSensorAdapter.shared.consecutivePreEGVDisconnectsCount)")
                    .foregroundColor(G7WatchSensorAdapter.shared.consecutivePreEGVDisconnectsCount > 2 ? .red : .secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            HStack {
                Text("Status:")
                Spacer()
                Text(WatchState.shared.g7DirectBleStatus.rawValue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            HStack {
                Text("BLE link:")
                Spacer()
                Text(bleLinkText)
                    .foregroundColor(bleLinkColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            HStack {
                Text("Signal:")
                Spacer()
                Text(signalText)
                    .foregroundColor(signalColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            HStack {
                Text("Stall:")
                Spacer()
                Text(stallText + (G7WatchSensorAdapter.shared.lastDirectBleStallFault.map { " · " + ($0 == "dexcom_side" ? "dex" : "trio") } ?? ""))
                    .foregroundColor(stallColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            HStack {
                Text("Ext session:")
                Spacer()
                Text(extSessionDisplay)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            HStack(alignment: .top) {
                Text("Sensor:")
                Spacer()
                if sensorRowConverged {
                    Text("\(G7WatchSensorAdapter.shared.expectedSensorName ?? "—") ✓")
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                } else {
                    // C-218 E-6: on divergence, stack the three identities so each stays legible
                    // (the old one-line form truncated to noise). exp = phone-pushed expected,
                    // bnd = live G7Sensor binding, ph = WC phone-relay name.
                    VStack(alignment: .trailing, spacing: 1) {
                        sensorDivergenceRow("exp", G7WatchSensorAdapter.shared.expectedSensorName ?? "—")
                        sensorDivergenceRow("bnd", G7WatchSensorAdapter.shared.boundSensorName ?? "—")
                        sensorDivergenceRow("ph", G7WatchSensorAdapter.shared.telemetrySensorName)
                    }
                    .foregroundColor(.yellow)
                }
            }
            HStack {
                Text("Live source:")
                Spacer()
                Text(WatchState.shared.displayedReadingSource.watchBadgeText)
                    .foregroundColor(.cyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            HStack {
                Text("Today:")
                Spacer()
                Text("\(WatchState.shared.bleConnectsToday)c · \(WatchState.shared.bleEGVsToday)e · \(eligibleSlots)w · \(WatchState.shared.gatedSlotsToday)g")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            HStack {
                Text("Was restored:")
                Spacer()
                Text(formatG7Time(WatchState.shared.bleLastRestoreAt))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .font(.caption)
    }

    private var sensorRowConverged: Bool {
        let phone = G7WatchSensorAdapter.shared.telemetrySensorName
        let expected = G7WatchSensorAdapter.shared.expectedSensorName ?? "—"
        let bound = G7WatchSensorAdapter.shared.boundSensorName ?? "—"
        return expected != "—" && phone == expected && bound == expected
    }

    private func sensorDivergenceRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundColor(.secondary)
            Text(value).lineLimit(1).minimumScaleFactor(0.6)
        }
        .font(.caption2)
    }

    private var extSessionDisplay: String {
        let state = G7WatchSensorAdapter.shared.extSessionState
        if state == "nil" {
            return G7WatchSensorAdapter.shared.extSessionLastKnownActive ? "active?" : "nil"
        }
        // C-217-D4: append the true session age ("running · 47m") and a reanchor-eligibility tag
        // (session .running and >= sessionReanchorAge — the C-212-5 inline-swap window).
        var display = state
        if let ageS = G7WatchSensorAdapter.shared.extSessionAgeSeconds {
            display += " · \(ageS / 60)m"
        }
        if G7WatchSensorAdapter.shared.isReanchorEligibleNow {
            display += " · reanchor-ok"
        }
        return display
    }

    // C-217-D1: peripheral-state name + connect-pending age. `diag` nil (no poll yet) and
    // `activePeripheralStateRaw` nil (no active peripheral) both render "—".
    private var bleLinkText: String {
        guard let raw = diag?.activePeripheralStateRaw else { return "—" }
        switch raw {
        case 0:
            return "disconnected"
        case 1:
            let base: String
            if let age = diag?.connectPendingAgeS {
                base = "connecting · \(age)s"
            } else {
                base = "connecting (unwatched)"
            }
            return base + " · ticks:\(G7WatchSensorAdapter.shared.connectingTicksCount)"
        case 2:
            return "connected"
        case 3:
            return "disconnecting"
        default:
            return "state:\(raw)"
        }
    }

    private var bleLinkColor: Color {
        guard let raw = diag?.activePeripheralStateRaw else { return .secondary }
        if raw == 1 { return diag?.connectPendingAgeS == nil ? .red : .yellow }
        return raw == 2 ? .green : .secondary
    }

    // C-217-D2: "-82 dBm · 2m"; RSSI 127 (BT "not available") or nil ⇒ "—".
    private var signalText: String {
        guard let diag, let rssi = diag.lastDiscoverRSSI, rssi != 127 else { return "—" }
        let ageText: String
        if let s = diag.secondsSinceLastDiscover {
            ageText = s < 60 ? "\(s)s" : "\(s / 60)m"
        } else {
            ageText = "—"
        }
        return "\(rssi) dBm · \(ageText)"
    }

    private var signalColor: Color {
        guard let diag, let rssi = diag.lastDiscoverRSSI, rssi != 127 else { return .secondary }
        if rssi >= -70 { return .green }
        if rssi >= -90 { return .yellow }
        return .red
    }

    // C-217-D3: DirectBleStallTier (C-210-4): none / stalled / unavailable.
    private var stallText: String {
        switch WatchState.shared.directBleStall {
        case .none: return "—"
        case .stalled: return "stalled"
        case .unavailable: return "unavailable"
        }
    }

    private var stallColor: Color {
        switch WatchState.shared.directBleStall {
        case .none: return .green
        case .stalled: return .yellow
        case .unavailable: return .red
        }
    }

    private var sinceEGVDisplay: String {
        let m = G7WatchSensorAdapter.shared.minutesSinceLastEGV()
        return m < 0 ? "—" : "\(m)m"
    }

    private var sinceEGVColor: Color {
        let m = G7WatchSensorAdapter.shared.minutesSinceLastEGV()
        if m < 0 { return .secondary }
        if m < 6 { return .green }
        if m <= 15 { return .yellow }
        return .red
    }

    private func formatG7Time(_ date: Date?) -> String {
        guard let date, date != .distantPast else { return "--" }
        return Self.timeFormatter.string(from: date)
    }

    /// Mirrors `WatchDiagnosticsView.nextReadingCountdown` semantics: "Ns" when in the future,
    /// "⚠️+Ns" when overdue (last connect + cadence has already passed). "--" if no connect yet.
    private func nextConnectCountdown(_ lastConnect: Date?) -> String {
        guard let lastConnect, lastConnect != .distantPast else { return "--" }
        let remaining = Int(lastConnect.addingTimeInterval(Self.expectedCadence).timeIntervalSince(now))
        if remaining < 0 { return "⚠️+\(abs(remaining))s" }
        return "\(remaining)s"
    }

    /// C-209-1 (B1): analytical eligible windows — elapsed wall-clock slots since midnight minus
    /// ineligible (no sensor identity) minus C1-gated. Computed at display time, so it cannot
    /// freeze during background suspension the way the old timer-accumulated counter did.
    private var slotStats: G7WatchSensorAdapter.DailySlotStats {
        G7WatchSensorAdapter.shared.dailySlotStats()
    }

    private var eligibleSlots: Int {
        slotStats.eligibleSlots
    }

    /// UI-207-1: honest slot capture "EGVs / eligibleWindows", **un-clamped** so a >100% ratio (backfill
    /// or multiple reads per slot) stays visible. Falls back to the raw EGV count when no eligible
    /// windows are known yet. Replaces the old `countWithDenominator`, which clamped the numerator with
    /// `min(count, denom)` and was wrongly applied to the event-based Connects row too — making both
    /// rows read e.g. `61/61` and hiding the real totals.
    private var slotCaptureText: String {
        let stats = slotStats
        let denom = stats.eligibleSlots
        guard denom > 0 else { return "\(stats.egvs)" }
        return "\(stats.egvs) / \(denom)"
    }
}

// C-217-D6: caller-side ring helpers — fraction of the 5-min cadence elapsed since `reference`,
// clamped to [0, 1] (computed from the existing 1 Hz `now` tick); yellow at 90%, red once overdue.
private func g7CountdownFraction(from reference: Date?, to now: Date) -> Double {
    guard let reference, reference != .distantPast else { return 0 }
    return min(1, max(0, now.timeIntervalSince(reference) / 300))
}

private func g7CountdownRingColor(_ fraction: Double) -> Color {
    if fraction < 0.9 { return .green }
    if fraction < 1.0 { return .yellow }
    return .red
}

// C-217 D-8: rounded-rect perimeter traced from TOP-CENTER clockwise, so a caller's
// `.trim(from: 0, to: fraction)` fills clockwise from 12 o'clock without any rotation. y-down
// SwiftUI space. Corner radius + insets are supplied from the live tuning panel. If the arc renders
// counter-clockwise on device, flip the `clockwise:` booleans (geometry is dialed in on-wrist).
private struct EdgeRingShape: Shape {
    var cornerRadius: CGFloat
    var insetX: CGFloat
    var insetY: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetX, dy: insetY)
        let cr = min(cornerRadius, min(r.width, r.height) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))                       // top-center
        p.addLine(to: CGPoint(x: r.maxX - cr, y: r.minY))              // top edge -> right
        p.addArc(center: CGPoint(x: r.maxX - cr, y: r.minY + cr), radius: cr,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - cr))             // right edge -> bottom
        p.addArc(center: CGPoint(x: r.maxX - cr, y: r.maxY - cr), radius: cr,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + cr, y: r.maxY))             // bottom edge -> left
        p.addArc(center: CGPoint(x: r.minX + cr, y: r.maxY - cr), radius: cr,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + cr))            // left edge -> top
        p.addArc(center: CGPoint(x: r.minX + cr, y: r.minY + cr), radius: cr,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: r.midX, y: r.minY))                 // close at top-center
        return p
    }
}

#Preview {
    NavigationStack {
        WatchDiagnosticsView()
    }
}
