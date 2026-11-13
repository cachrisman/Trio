import SwiftUI

/// The "Glucose Bobble" contact image style: same ring, trend arrow and glucose number as the
/// HUD's `CurrentGlucoseView` bobble, reusing its `Triangle` shape. Rendered by `ContactPicture`
/// via `ImageRenderer` at `Layout.nativeSize` and scaled up from there.
struct GlucoseBobbleContactView: View {
    let glucoseText: String
    let minutesAgoText: String?
    let deltaText: String?
    let glucoseColor: Color
    let rotationDegrees: Double
    var trendArrowPlacement: TrendArrowPlacement = .outsideRing
    var trend: String? = nil
    /// Overrides the ring's angular gradient with a solid colour, e.g. to reflect loop status.
    var ringColor: Color? = nil
    /// Thin outline on inside-ring trend wedges (complication dark backdrop).
    var arrowOutlineColor: Color? = nil

    /// Where the trend arrow sits relative to the ring. The phone contact image keeps the arrow
    /// outside the (smaller) ring; a watch complication can use a larger ring with the arrow
    /// orbiting inside it instead.
    enum TrendArrowPlacement {
        case outsideRing
        case insideRing

        var ringDiameter: CGFloat {
            switch self {
            case .outsideRing: return Layout.ringDiameter
            case .insideRing: return Layout.insideRingDiameter
            }
        }

        var glucoseFontSize: CGFloat {
            switch self {
            case .outsideRing: return 66
            case .insideRing: return 104
            }
        }

        var secondLineFontSize: CGFloat {
            switch self {
            case .outsideRing: return 26
            case .insideRing: return 54
            }
        }

        var vStackSpacing: CGFloat {
            switch self {
            case .outsideRing: return 4
            case .insideRing: return 5
            }
        }

        var glucoseFontWeight: Font.Weight {
            switch self {
            case .outsideRing: return .bold
            case .insideRing: return .medium
            }
        }

        var glucoseFontDesign: Font.Design {
            switch self {
            case .outsideRing: return .rounded
            case .insideRing: return .default
            }
        }

        var glucoseMinimumScaleFactor: CGFloat {
            switch self {
            case .outsideRing: return 0.4
            case .insideRing: return 0.5
            }
        }

        var glucoseTextFrameWidth: CGFloat {
            switch self {
            case .outsideRing: return textWidth
            case .insideRing: return 196
            }
        }

        var secondLineTextFrameWidth: CGFloat {
            switch self {
            case .outsideRing: return textWidth
            case .insideRing: return 172
            }
        }

        var glucoseBaselineOffset: CGFloat {
            switch self {
            case .outsideRing: return 0
            case .insideRing: return -4
            }
        }

        var secondLineBaselineOffset: CGFloat {
            switch self {
            case .outsideRing: return 0
            case .insideRing: return 50
            }
        }

        var secondLineItemSpacing: CGFloat {
            switch self {
            case .outsideRing: return 8
            case .insideRing: return 5
            }
        }

        /// Centre of the ring stroke path (variant C seats the arrow on the ring).
        var ringStrokeRadius: CGFloat {
            ringDiameter / 2
        }

        /// Gap in the ring at the arrow, in degrees (symmetric about the arrow direction).
        var ringGapDegrees: CGFloat {
            switch self {
            case .outsideRing: return 0
            case .insideRing: return 30
            }
        }

        /// Distance from center to the triangle's base (its innermost drawn edge). Triangle draws
        /// from its frame's center (the tip) to one edge, so the visible arrow is triangleSize / 2
        /// deep and its tip sits at triangleOffset.
        var triangleBaseRadius: CGFloat {
            switch self {
            case .outsideRing:
                return Layout.ringOuterRadius
            case .insideRing:
                let ringInnerRadius = ringDiameter / 2 - Layout.ringLineWidth / 2
                return ringInnerRadius - Layout.triangleSize / 2
            }
        }

        var triangleOffset: CGFloat { triangleBaseRadius + Layout.triangleSize / 2 }

        var textWidth: CGFloat {
            switch self {
            case .outsideRing:
                return Layout.textWidth
            case .insideRing:
                return 200
            }
        }

        /// Variant C arrow geometry (mockup: 64×32 on the 256 canvas).
        var onRingArrowDepth: CGFloat {
            switch self {
            case .outsideRing: return 0
            case .insideRing: return 32
            }
        }

        var onRingArrowHalfWidth: CGFloat {
            switch self {
            case .outsideRing: return 0
            case .insideRing: return 32
            }
        }

        var onRingArrowTipRadius: CGFloat {
            switch self {
            case .outsideRing: return 0
            case .insideRing:
                return Layout.insideRingDiameter / 2 + Layout.ringLineWidth / 2
            }
        }
    }

    enum Layout {
        static let nativeSize: CGFloat = 256
        static let ringLineWidth: CGFloat = 9
        // Bounded by nativeSize: for the outside placement, ringOuterRadius + triangleSize must
        // stay under nativeSize / 2 (128) or the tip gets clipped by ImageRenderer, which snapshots
        // exactly nativeSize. 30 is close to that ceiling — it's as close to the HUD bobble's
        // proportions as this canvas allows without also resizing the ring.
        static let triangleSize: CGFloat = 30

        // Outside-ring geometry (.outsideRing): matches the HUD bobble's proportions.
        static let ringDiameter: CGFloat = 184
        // Circle().stroke centers the stroke on the path, so the ring's outer edge sits
        // ringLineWidth / 2 past ringDiameter / 2. Offset the triangle from there, not the bare
        // radius, or it overlaps the ring.
        static var ringOuterRadius: CGFloat { ringDiameter / 2 + ringLineWidth / 2 }
        static let textWidth: CGFloat = ringDiameter * 0.74

        // Inside-ring geometry (.insideRing): a larger ring, sized so its outer edge still fits
        // the nativeSize / 2 (128) half-canvas, leaving room for the arrow to orbit inside it.
        static let insideRingDiameter: CGFloat = 243
    }

    private var triangleColor: Color {
        Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902)
    }

    private var angularGradient: AngularGradient {
        AngularGradient(colors: [
            Color(red: 0.7215686275, green: 0.3411764706, blue: 1),
            Color(red: 0.6235294118, green: 0.4235294118, blue: 0.9803921569),
            Color(red: 0.4862745098, green: 0.5450980392, blue: 0.9529411765),
            Color(red: 0.3411764706, green: 0.6666666667, blue: 0.9254901961),
            Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902),
            Color(red: 0.7215686275, green: 0.3411764706, blue: 1)
        ], center: .center, startAngle: .degrees(270), endAngle: .degrees(-90))
    }

    var body: some View {
        switch trendArrowPlacement {
        case .outsideRing:
            outsideRingBody
        case .insideRing:
            insideRingBody
        }
    }

    private var outsideRingBody: some View {
        ZStack {
            // Must be a ZStack, not a Group: a modifier on a Group applies to each child
            // separately, so rotationEffect would spin the triangle around its own offset
            // instead of orbiting it around the ring.
            ZStack {
                Circle()
                    .stroke(
                        ringColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(angularGradient),
                        lineWidth: Layout.ringLineWidth
                    )
                    .frame(width: trendArrowPlacement.ringDiameter, height: trendArrowPlacement.ringDiameter)

                Triangle()
                    .fill(triangleColor)
                    .frame(width: Layout.triangleSize, height: Layout.triangleSize)
                    .rotationEffect(.degrees(90))
                    .offset(x: trendArrowPlacement.triangleOffset)
            }
            .rotationEffect(.degrees(rotationDegrees))

            VStack(spacing: trendArrowPlacement.vStackSpacing) {
                glucoseTextLine
                secondLine
            }
            .frame(width: trendArrowPlacement.textWidth)
        }
        .frame(width: Layout.nativeSize, height: Layout.nativeSize)
    }

    private var insideRingBody: some View {
        let gapTrim = trendArrowPlacement.ringGapDegrees / 360
        let halfGapTrim = gapTrim / 2

        return ZStack {
            ZStack {
                Circle()
                    .trim(from: halfGapTrim, to: 1 - halfGapTrim)
                    .stroke(
                        ringColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(angularGradient),
                        style: StrokeStyle(lineWidth: Layout.ringLineWidth, lineCap: .round)
                    )
                    .frame(
                        width: trendArrowPlacement.ringDiameter,
                        height: trendArrowPlacement.ringDiameter
                    )

                insideRingArrowLayer
            }
            .rotationEffect(.degrees(rotationDegrees))

            positionedInsideRingGlucoseText
            positionedInsideRingSecondLine
        }
        .frame(width: Layout.nativeSize, height: Layout.nativeSize)
    }

    @ViewBuilder private var glucoseTextLine: some View {
        Text(glucoseText)
            .font(
                .system(
                    size: trendArrowPlacement.glucoseFontSize,
                    weight: trendArrowPlacement.glucoseFontWeight,
                    design: trendArrowPlacement.glucoseFontDesign
                )
            )
            .foregroundStyle(glucoseColor)
            .minimumScaleFactor(trendArrowPlacement.glucoseMinimumScaleFactor)
            .lineLimit(1)
    }

    @ViewBuilder private var secondLine: some View {
        if minutesAgoText != nil || deltaText != nil {
            HStack(spacing: trendArrowPlacement.secondLineItemSpacing) {
                if let minutesAgoText {
                    Text(minutesAgoText)
                }
                if let deltaText {
                    Text(deltaText)
                }
            }
            .font(
                .system(
                    size: trendArrowPlacement.secondLineFontSize,
                    weight: trendArrowPlacement.glucoseFontWeight,
                    design: trendArrowPlacement.glucoseFontDesign
                )
            )
            .foregroundStyle(.white)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
        }
    }

    private var positionedInsideRingGlucoseText: some View {
        glucoseTextLine
            .frame(width: trendArrowPlacement.glucoseTextFrameWidth)
            .alignmentGuide(VerticalAlignment.center) { $0[.firstTextBaseline] }
            .offset(y: trendArrowPlacement.glucoseBaselineOffset)
    }

    private var positionedInsideRingSecondLine: some View {
        secondLine
            .frame(width: trendArrowPlacement.secondLineTextFrameWidth)
            .alignmentGuide(VerticalAlignment.center) { $0[.firstTextBaseline] }
            .offset(y: trendArrowPlacement.secondLineBaselineOffset)
    }

    @ViewBuilder private var insideRingArrowLayer: some View {
        let depth = trendArrowPlacement.onRingArrowDepth
        let halfWidth = trendArrowPlacement.onRingArrowHalfWidth
        let tipRadius = trendArrowPlacement.onRingArrowTipRadius
        let outlineColor = arrowOutlineColor ?? .black

        if Self.isMultiWedgeTrend(trend) {
            onRingWedge(
                tipRadius: tipRadius,
                depth: depth,
                halfWidth: halfWidth,
                fill: .white,
                outline: outlineColor
            )
            onRingWedge(
                tipRadius: tipRadius - depth / 2,
                depth: depth,
                halfWidth: halfWidth,
                fill: .white,
                outline: outlineColor
            )
        } else {
            onRingWedge(
                tipRadius: tipRadius,
                depth: depth,
                halfWidth: halfWidth,
                fill: .white,
                outline: outlineColor
            )
        }
    }

    private func onRingWedge(
        tipRadius: CGFloat,
        depth: CGFloat,
        halfWidth: CGFloat,
        fill: Color,
        outline: Color
    ) -> some View {
        OnRingTrendWedge(tipRadius: tipRadius, depth: depth, halfWidth: halfWidth)
            .fill(fill)
            .overlay {
                OnRingTrendWedge(tipRadius: tipRadius, depth: depth, halfWidth: halfWidth)
                    .stroke(outline, lineWidth: 1.5)
            }
    }

    static func isMultiWedgeTrend(_ trend: String?) -> Bool {
        switch trend {
        case "DoubleUp", "DoubleDown", "TripleUp", "TripleDown":
            return true
        default:
            return false
        }
    }
}

// Variant C wedge seated on the ring (tip at +x on the 256-unit canvas).
private struct OnRingTrendWedge: Shape {
    var tipRadius: CGFloat
    var depth: CGFloat
    var halfWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let tipX = center.x + tipRadius
        let baseX = tipX - depth
        let controlX = baseX + depth / 3

        var path = Path()
        path.move(to: CGPoint(x: tipX, y: center.y))
        path.addLine(to: CGPoint(x: baseX, y: center.y - halfWidth))
        path.addQuadCurve(
            to: CGPoint(x: baseX, y: center.y + halfWidth),
            control: CGPoint(x: controlX, y: center.y)
        )
        path.closeSubpath()
        return path
    }
}

extension GlucoseBobbleContactView {
    // Keyed on raw direction strings so targets without the phone's BloodGlucose model can share it.
    static func rotationDegrees(forTrend trend: String?) -> Double {
        switch trend {
        case "DoubleUp",
             "SingleUp",
             "TripleUp":
            return -90
        case "FortyFiveUp":
            return -45
        case "Flat":
            return 0
        case "FortyFiveDown":
            return 45
        case "DoubleDown",
             "SingleDown",
             "TripleDown":
            return 90
        default:
            return 0
        }
    }
}

#Preview("Outside ring (contact image)") {
    GlucoseBobbleContactView(
        glucoseText: "128",
        minutesAgoText: "1m",
        deltaText: "-6",
        glucoseColor: .green,
        rotationDegrees: -45,
        trendArrowPlacement: .outsideRing
    )
    .frame(width: 256, height: 256)
    .background(Color.black)
}

#Preview("Inside ring — flat") {
    GlucoseBobbleContactView(
        glucoseText: "128",
        minutesAgoText: "1m",
        deltaText: "-6",
        glucoseColor: Color(hue: 164 / 360, saturation: 0.45, brightness: 1),
        rotationDegrees: 0,
        trendArrowPlacement: .insideRing,
        arrowOutlineColor: .black
    )
    .frame(width: 256, height: 256)
    .background(Color.black.opacity(0.3))
}

#Preview("Inside ring — mmol") {
    GlucoseBobbleContactView(
        glucoseText: "12.8",
        minutesAgoText: "59m",
        deltaText: "-0.6",
        glucoseColor: Color(hue: 164 / 360, saturation: 0.45, brightness: 1),
        rotationDegrees: 45,
        trendArrowPlacement: .insideRing,
        trend: "FortyFiveDown",
        arrowOutlineColor: .black
    )
    .frame(width: 256, height: 256)
    .background(Color.black.opacity(0.3))
}

#Preview("Inside ring — double up") {
    GlucoseBobbleContactView(
        glucoseText: "199",
        minutesAgoText: "9m",
        deltaText: "+7",
        glucoseColor: Color(hue: 245 / 360, saturation: 0.45, brightness: 1),
        rotationDegrees: -90,
        trendArrowPlacement: .insideRing,
        trend: "DoubleUp",
        arrowOutlineColor: .black
    )
    .frame(width: 256, height: 256)
    .background(Color.black.opacity(0.3))
}
