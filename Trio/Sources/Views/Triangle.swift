import SwiftUI

// Trend-arrow shape used by the home-screen glucose HUD (CurrentGlucoseView) and the Glucose Bobble contact image, kept in its own file so other targets can share it.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.midX, y: rect.minY + 15))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))

        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.midY + 10))

        path.closeSubpath()

        return path
    }
}
