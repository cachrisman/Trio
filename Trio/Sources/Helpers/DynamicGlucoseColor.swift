import Foundation
import SwiftUI

// Helper function to decide how to pick the glucose color
public func getDynamicGlucoseColor(
    glucoseValue: Decimal,
    highGlucoseColorValue: Decimal,
    lowGlucoseColorValue: Decimal,
    targetGlucose: Decimal,
    glucoseColorScheme: GlucoseColorScheme
) -> Color {
    // Only use calculateHueBasedGlucoseColor if the setting is enabled in preferences
    if glucoseColorScheme == .dynamicColor {
        return calculateHueBasedGlucoseColor(
            glucoseValue: glucoseValue,
            highGlucose: highGlucoseColorValue,
            lowGlucose: lowGlucoseColorValue,
            targetGlucose: targetGlucose
        )
    }
    // Otheriwse, use static (orange = high, red = low, green = range)
    else {
        if glucoseValue >= highGlucoseColorValue {
            return Color.orange
        } else if glucoseValue <= lowGlucoseColorValue {
            return Color.red
        } else {
            return Color.green
        }
    }
}

// Dynamic color - Define the hue values for the key points
// We'll shift color gradually one glucose point at a time
// We'll shift through the rainbow colors of ROY-G-BIV from low to high
// Start at red for lowGlucose, green for targetGlucose, and violet for highGlucose
//
// The parity-sensitive HSB math lives in the Foundation-only `glucoseHueComponents`
// (GlucoseHueColor.swift), shared with the watch so both sides compute identical colors.
// This wrapper only adds the SwiftUI `Color` (phone-only — the watch builds hex from the
// same components locally). Refactored in place (no symbol move) for build 205 / W5.
public func calculateHueBasedGlucoseColor(
    glucoseValue: Decimal,
    highGlucose: Decimal,
    lowGlucose: Decimal,
    targetGlucose: Decimal
) -> Color {
    let components = glucoseHueComponents(
        glucoseValue,
        high: highGlucose,
        low: lowGlucose,
        target: targetGlucose
    )
    return Color(
        hue: components.hue,
        saturation: components.saturation,
        brightness: components.brightness
    )
}
