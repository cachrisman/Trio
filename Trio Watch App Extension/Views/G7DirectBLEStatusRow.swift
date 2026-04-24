import SwiftUI

/// Compact status row rendered on the main watch view's page 0 (below the
/// glucose bobble, above the toolbar). Shows:
///
/// - a small filled circle colored by observer state,
/// - `BLE:<state>` text,
/// - `src:<source>` indicating which ingestion path delivered the currently
///   displayed glucose reading,
/// - `<age>` since the last direct-BLE EGV was received.
///
/// The row is hidden entirely when all three signals are at their defaults
/// (observer `.off`, no `latestReadingSource`, no `lastG7BLEReadingAt`) so a
/// cold watch UI looks identical to the pre-feature baseline. See
/// `docs/in-progress/watch-g7-direct-ble-observer/01-design.md` §14.
struct G7DirectBLEStatusRow: View {
    let state: WatchState
    let deviceFontSize: CGFloat

    private var shouldRender: Bool {
        state.g7ObserverSnapshot.status != .off
            || state.latestReadingSource != nil
            || state.g7ObserverSnapshot.lastEGVAt != nil
    }

    private var statusColor: Color {
        switch state.g7ObserverSnapshot.status {
        case .active: return Color.green
        case .connecting, .searching: return Color.yellow
        case .stalled: return Color.orange
        case .off, .unavailable: return Color.gray
        }
    }

    private var stateLabel: String {
        state.g7ObserverSnapshot.status.shortLabel
    }

    private var sourceLabel: String {
        state.latestReadingSource?.shortLabel ?? "—"
    }

    private var lastEGVAgeLabel: String {
        guard let at = state.g7ObserverSnapshot.lastEGVAt else { return "—" }
        let age = Int(Date().timeIntervalSince(at))
        if age < 60 { return "\(age)s" }
        let mins = age / 60
        return "\(mins)m"
    }

    var body: some View {
        if shouldRender {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text("BLE:\(stateLabel)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("src:\(sourceLabel)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(lastEGVAgeLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .font(.system(size: deviceFontSize))
            .padding(.horizontal, 4)
        } else {
            EmptyView()
        }
    }
}
