import Foundation

/// Foundation-only HSB components for the dynamic glucose color.
///
/// This is the parity-sensitive part of the dynamic color scheme, shared by the phone
/// (`DynamicGlucoseColor.calculateHueBasedGlucoseColor`) and the watch
/// (`WatchGlucoseColorComputer`) so both sides compute an identical hue/saturation/brightness.
///
/// **No SwiftUI / UIKit imports** — this file must compile in the watch extension target,
/// which does not link UIKit. The SwiftUI `Color` wrapper stays phone-side; the watch turns
/// these components into a hex string locally (HSB → RGB → `#RRGGBB`).
struct GlucoseHueComponents {
    let hue: Double
    let saturation: Double
    let brightness: Double
}

/// Pure HSB math for the dynamic glucose color scheme. Mirrors the ROY-G-BIV sweep:
/// red at/below `low`, green at `target`, purple at/above `high`. Saturation 0.6, brightness 0.9
/// (must match `DynamicGlucoseColor`'s historical values for color parity).
func glucoseHueComponents(_ glucose: Decimal, high: Decimal, low: Decimal, target: Decimal) -> GlucoseHueComponents {
    let redHue = 0.0 / 360.0 // 0 degrees
    let greenHue = 120.0 / 360.0 // 120 degrees
    let purpleHue = 270.0 / 360.0 // 270 degrees

    let hue: Double
    if glucose <= low {
        hue = redHue
    } else if glucose >= high {
        hue = purpleHue
    } else if glucose <= target {
        // Interpolate between red and green
        let ratio = Double(truncating: (glucose - low) / (target - low) as NSNumber)
        hue = redHue + ratio * (greenHue - redHue)
    } else {
        // Interpolate between green and purple
        let ratio = Double(truncating: (glucose - target) / (high - target) as NSNumber)
        hue = greenHue + ratio * (purpleHue - greenHue)
    }
    return GlucoseHueComponents(hue: hue, saturation: 0.6, brightness: 0.9)
}
