//
//  ManualRefreshOverlay.swift
//  Trio Watch App Extension
//
//  Manual refresh overlay with spinner and success feedback
//

import SwiftUI

struct ManualRefreshOverlay: View {
    let isRefreshing: Bool
    let showSuccess: Bool
    let message: String
    
    var body: some View {
        ZStack {
            if isRefreshing || showSuccess {
                Color.black.opacity(0.7)
                    .edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 12) {
                    if isRefreshing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.2)
                        
                        Text("Refreshing...")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                    } else if showSuccess {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.green)
                        
                        Text(message.isEmpty ? "Updated" : message)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(white: 0.2))
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isRefreshing)
        .animation(.easeInOut(duration: 0.2), value: showSuccess)
    }
}

struct ManualRefreshOverlay_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ManualRefreshOverlay(isRefreshing: true, showSuccess: false, message: "")
                .previewDisplayName("Refreshing")
            
            ManualRefreshOverlay(isRefreshing: false, showSuccess: true, message: "Refreshing...")
                .previewDisplayName("Success")
        }
    }
}
