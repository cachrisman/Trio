//
//  ManualRefreshOverlay.swift
//  Trio Watch App Extension
//
//  Manual refresh UI overlay with spinner and success/error states
//
import SwiftUI

struct ManualRefreshOverlay: View {
    @Binding var isVisible: Bool
    @Binding var refreshState: RefreshState
    
    enum RefreshState {
        case idle
        case refreshing
        case success
        case error
    }
    
    var body: some View {
        if isVisible {
            ZStack {
                // Semi-transparent background
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                
                // Refresh indicator
                VStack(spacing: 12) {
                    switch refreshState {
                    case .idle:
                        EmptyView()
                    case .refreshing:
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.2)
                        Text("Refreshing...")
                            .font(.caption)
                            .foregroundColor(.white)
                    case .success:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.green)
                        Text("Refreshed")
                            .font(.caption)
                            .foregroundColor(.white)
                    case .error:
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.red)
                        Text("Refresh Failed")
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.8))
                )
            }
        }
    }
}
