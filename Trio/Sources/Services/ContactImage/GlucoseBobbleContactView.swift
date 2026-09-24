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
    /// Overrides the ring's angular gradient with a solid colour, e.g. to reflect loop status.
    var ringColor: Color? = nil

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
            case .insideRing: return 84
            }
        }

        var secondLineFontSize: CGFloat {
            switch self {
            case .outsideRing: return 26
            case .insideRing: return 31
            }
        }

        var vStackSpacing: CGFloat {
            switch self {
            case .outsideRing: return 4
            case .insideRing: return 5
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
                // Tip touches the ring's inner edge.
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
                // Keep the text clear of the arrow's orbit. At ±45° the arrow's base sits near the
                // text block's corners (about 0.71 × the base radius on each axis), so bounding the
                // width by the full base circle isn't enough; 0.78 × keeps the corners clear.
                return 2 * triangleBaseRadius * 0.78
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
                Text(glucoseText)
                    .font(.system(size: trendArrowPlacement.glucoseFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(glucoseColor)
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)

                if minutesAgoText != nil || deltaText != nil {
                    HStack(spacing: 8) {
                        if let minutesAgoText {
                            Text(minutesAgoText)
                        }
                        if let deltaText {
                            Text(deltaText)
                        }
                    }
                    .font(.system(size: trendArrowPlacement.secondLineFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                }
            }
            .frame(width: trendArrowPlacement.textWidth)
        }
        .frame(width: Layout.nativeSize, height: Layout.nativeSize)
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
