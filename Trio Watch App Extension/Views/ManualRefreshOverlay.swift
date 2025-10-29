import SwiftUI

struct ManualRefreshOverlay: View {
    let isVisible: Bool
    let isSuccess: Bool

    var body: some View {
        Group {
            if isVisible {
                ZStack {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    VStack(spacing: 8) {
                        if isSuccess {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.system(size: 36))
                        } else {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                        Text(isSuccess ? "Updated" : "Refreshing…")
                            .font(.footnote)
                            .foregroundStyle(.primary)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .transition(.opacity)
            }
        }
    }
}
