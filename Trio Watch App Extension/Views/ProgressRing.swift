import SwiftUI

@available(watchOS 26.0, *)
struct ProgressRingView: View {
    let arcReferenceReadingDate: Date?
    let tick: Date  // driven externally so this view stays dumb

    var body: some View {
        let fraction: Double = {
            guard let referenceDate = arcReferenceReadingDate else { return 0 }
            return min(1.0, max(0.0, tick.timeIntervalSince(referenceDate) / 300.0))
        }()
        let arcColor: Color = fraction < 0.9 ? .green : (fraction < 0.95 ? .yellow : .red)
        let lineWidth: CGFloat = 8

        GeometryReader { _ in
            ConcentricRectangle()
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
                .animation(.linear(duration: 0.95), value: tick)
        }
        .allowsHitTesting(false)
    }
}
