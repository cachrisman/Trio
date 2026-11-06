import SwiftUI
import UIKit

/// Pull distance via layout frames — iOS 17 fallback only.
struct HomePullOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Streams the pull-down distance from the scroll geometry on iOS 18+.
struct HomePullOffsetReader: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                -(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, pull in
                onChange(pull)
            }
        } else {
            content
        }
    }
}

// MARK: - Pull-down-to-force-loop

extension Home.RootView {
    /// Forcing a cycle only means something where Trio enacts one.
    var canForceLoop: Bool { state.dosingMode.automation != .off }

    /// Pull hint while dragging; spinner while Nightscout backfill or the loop runs.
    @ViewBuilder var pullToRefreshIndicator: some View {
        if !canForceLoop {
            EmptyView()
        } else if isForcingLoop {
            HStack(spacing: 8) {
                ProgressView()
                if isBackfillingGlucose {
                    Text("Fetching Nightscout glucose…")
                } else {
                    Text("Forcing loop…")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: HomeLayout.refreshIndicatorHeight)
            .frame(maxWidth: .infinity)
            .transition(.opacity)
        } else if pullOffset > 4 {
            let progress = min(pullOffset / HomeLayout.refreshTriggerDistance, 1)
            HStack(spacing: 8) {
                Image(systemName: "arrow.down")
                    .rotationEffect(.degrees(progress * 180))
                Text("Pull down to force loop")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .opacity(progress)
            .frame(height: HomeLayout.refreshIndicatorHeight)
            .frame(maxWidth: .infinity)
        }
    }

    /// Arms once per pull at the threshold; re-arms after the pull settles.
    func handlePullChange(_ offset: CGFloat) {
        pullOffset = offset
        guard canForceLoop, !isForcingLoop else { return }
        if offset >= HomeLayout.refreshTriggerDistance, !isRefreshArmed {
            isRefreshArmed = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            forceLoop()
        } else if offset <= 1, isRefreshArmed {
            isRefreshArmed = false
        }
    }

    /// Backfills Nightscout glucose, then triggers the loop heartbeat and holds the indicator while it runs.
    private func forceLoop() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isForcingLoop = true
            isBackfillingGlucose = true
        }
        Task {
            await state.backfillGlucoseFromNightscout()
            withAnimation(.easeInOut(duration: 0.2)) { isBackfillingGlucose = false }
            state.runLoop()
            let start = Date()
            while !state.isLooping, Date().timeIntervalSince(start) < 3 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            while state.isLooping, Date().timeIntervalSince(start) < 30 {
                try? await Task.sleep(for: .milliseconds(200))
            }
            // Minimum visible duration.
            if Date().timeIntervalSince(start) < 1 {
                try? await Task.sleep(for: .seconds(1))
            }
            withAnimation(.easeInOut(duration: 0.25)) { isForcingLoop = false }
        }
    }
}
