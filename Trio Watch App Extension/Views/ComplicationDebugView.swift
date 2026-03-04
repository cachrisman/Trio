import SwiftUI
import WatchKit

struct ComplicationDebugView: View {
    @State private var snapshot: TrioComplicationSnapshot?
    @State private var showConfirmation = false
    @State private var confirmationMessage = ""
    @State private var refreshTrigger = UUID()

    private let dataStore = TrioComplicationDataStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // SECTION 1: Data Store State
                sectionHeader("DATA STORE")
                dataStoreStateView

                Divider().padding(.vertical, 4)

                // SECTION 2: Reload Status
                sectionHeader("RELOAD STATUS")
                reloadStatusView

                Divider().padding(.vertical, 4)

                // SECTION 3: Actions
                sectionHeader("ACTIONS")
                actionsView
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle("Debug")
        .onAppear { loadSnapshot() }
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

#Preview {
    NavigationStack {
        ComplicationDebugView()
    }
}
