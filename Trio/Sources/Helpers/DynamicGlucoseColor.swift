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
    // Otherwise, use the static colors
    else {
        if glucoseValue >= highGlucoseColorValue {
            return Color.staticHigh
        } else if glucoseValue <= lowGlucoseColorValue {
            return Color.staticLow
        } else {
            return Color.staticInRange
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

// Discrete band colors sampled from the dynamic gradient above
public extension Color {
    static let dynamicRed = Color(hue: 0.0 / 360.0, saturation: 0.6, brightness: 0.9)
    static let dynamicOrange = Color(hue: 30.0 / 360.0, saturation: 0.6, brightness: 0.9)
    static let dynamicGreen = Color(hue: 120.0 / 360.0, saturation: 0.6, brightness: 0.9)
    static let dynamicTeal = Color(hue: 165.0 / 360.0, saturation: 0.6, brightness: 0.9)
    static let dynamicBlue = Color(hue: 200.0 / 360.0, saturation: 0.6, brightness: 0.9)
    static let dynamicIndigo = Color(hue: 235.0 / 360.0, saturation: 0.6, brightness: 0.9)
    static let dynamicPurple = Color(hue: 270.0 / 360.0, saturation: 0.6, brightness: 0.9)

    // Colors used when the Static Glucose Color Scheme is selected
    static let staticLow = Color.dynamicRed
    static let staticInRange = Color.dynamicGreen
    static let staticHigh = Color.dynamicPurple
}
