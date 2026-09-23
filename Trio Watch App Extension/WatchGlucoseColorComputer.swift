import Foundation
import SwiftUI

/// Computes glucose colors on the watch, reproducing the phone's exact rules so the WC payload
/// no longer has to carry per-reading color strings (build 205 / W5 + P2).
///
/// Two rules, matching `AppleWatchManager` + `getDynamicGlucoseColor`:
/// - **chart points** are always colored;
/// - the **current-glucose bubble** is white strictly inside the settings range `(low, high)`,
///   colored only at/below low or at/above high.
///
/// Color math is always in canonical **mg/dL**. The cached display `units` are used only to
/// convert chart Y-values for rendering (`displayValue(forMgDl:)`), never for color thresholds.
///
/// Settings live in the watch app's `UserDefaults.standard` (not App Group): only the watch app
/// computes color; the complication widget renders the baked snapshot hex.
final class WatchGlucoseColorComputer {
    static let shared = WatchGlucoseColorComputer()

    // Thresholds are canonical INTEGER mg/dL (avoids Decimal(Double) parity drift).
    private(set) var low: Int = 70
    private(set) var high: Int = 180
    private(set) var target: Int = 100
    private(set) var isDynamic: Bool = false
    /// Display units as sent on the wire (`WatchMessageKeys.units`): "mg/dL" or "mmol/L".
    /// Stored as the raw string to avoid pulling the phone's `GlucoseUnits`/`BloodGlucose.swift`
    /// (and its dependencies) into the watch target. Color math never reads this.
    private(set) var cachedUnitsRaw: String = "mg/dL"

    var isMmolL: Bool { cachedUnitsRaw == "mmol/L" }

    // Hard-coded dynamic-hue bounds — must match AppleWatchManager.swift (55/220).
    private let dynamicLow = Decimal(55)
    private let dynamicHigh = Decimal(220)

    // Static-scheme hex — captured from the real phone `toHexString()` path on the iOS 26.5
    // simulator (UIColor(Color.X).getRed() then Int(x*255) truncation, ambient/light traits).
    // SwiftUI's Color.red/.green/.orange are NOT pure RGB and NOT UIColor.system* — see build205 plan.
    private let staticHighHex = "#FF8D28" // == toHexString(.orange), light (255,141,40)
    private let staticLowHex = "#FF383C" // == toHexString(.red),    light (255,56,60)
    private let staticInRangeHex = "#34C759" // == toHexString(.green),  light (52,199,89)
    private let bubbleWhiteHex = "#ffffff" // matches AppleWatchManager hardcoded lowercase white

    /// mg/dL → mmol/L exchange rate. Constructed identically to the phone's `GlucoseUnits.exchangeRate`
    /// (a `Decimal` from the `0.0555` float literal) so the two are bit-identical and scale-1 rounding
    /// can't diverge on a half-boundary (review low).
    private let exchangeRate: Decimal = 0.0555

    private let defaults = UserDefaults.standard
    private enum K {
        static let low = "WatchGlucoseColor.low"
        static let high = "WatchGlucoseColor.high"
        static let target = "WatchGlucoseColor.target"
        static let dynamic = "WatchGlucoseColor.dynamic"
        static let units = "WatchGlucoseColor.units"
    }

    init() { load() }

    /// Apply settings pushed from the phone (P2). Thresholds are integer mg/dL; `unitsRaw` is the
    /// wire string from `WatchMessageKeys.units` and is display-only.
    func apply(low: Int, high: Int, target: Int, dynamic: Bool, unitsRaw: String) {
        self.low = low
        self.high = high
        self.target = target
        isDynamic = dynamic
        cachedUnitsRaw = unitsRaw
        defaults.set(low, forKey: K.low)
        defaults.set(high, forKey: K.high)
        defaults.set(target, forKey: K.target)
        defaults.set(dynamic, forKey: K.dynamic)
        defaults.set(unitsRaw, forKey: K.units)
    }

    func load() {
        low = (defaults.object(forKey: K.low) as? Int) ?? 70
        high = (defaults.object(forKey: K.high) as? Int) ?? 180
        target = (defaults.object(forKey: K.target) as? Int) ?? 100
        isDynamic = defaults.bool(forKey: K.dynamic)
        cachedUnitsRaw = defaults.string(forKey: K.units) ?? "mg/dL"
    }

    // MARK: - Hex (canonical — this is what gets baked into the snapshot)

    /// Chart points — always colored (no white-in-range).
    func chartColorHex(for mgDl: Int) -> String { colorHex(for: mgDl) }

    /// Current-glucose bubble — white STRICTLY inside (low, high); else the chart color.
    func bubbleColorHex(for mgDl: Int) -> String {
        // Phone colors when mgDl <= low OR mgDl >= high (AppleWatchManager), so white is strict.
        if mgDl > low, mgDl < high { return bubbleWhiteHex }
        return colorHex(for: mgDl)
    }

    private func colorHex(for mgDl: Int) -> String {
        if isDynamic {
            // Shared HSB math (parity) + watch-local HSB→hex (no UIKit).
            let components = glucoseHueComponents(
                Decimal(mgDl),
                high: dynamicHigh,
                low: dynamicLow,
                target: Decimal(target)
            )
            return hexFromHSB(components)
        }
        if mgDl >= high { return staticHighHex }
        if mgDl <= low { return staticLowHex }
        return staticInRangeHex
    }

    /// HSB → RGB → "#RRGGBB". Matches the phone's `toHexString()` byte-for-byte: `Int(x*255)`
    /// **truncation** (not rounding) and **uppercase** `%02X` (so a string-level parity check passes).
    private func hexFromHSB(_ c: GlucoseHueComponents) -> String {
        let (r, g, b) = hsbToRGB(hue: c.hue, saturation: c.saturation, brightness: c.brightness)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    /// Standard HSB→RGB. Verified to reproduce the phone's `UIColor(Color(hue:saturation:brightness:))`
    /// output for the dynamic sweep (55→#E55B5B … 220→#A05BE5) after truncation.
    private func hsbToRGB(hue: Double, saturation: Double, brightness: Double) -> (Double, Double, Double) {
        if saturation <= 0 { return (brightness, brightness, brightness) }
        let h6 = (hue - floor(hue)) * 6.0 // wrap hue into [0, 6)
        let i = Int(h6)
        let f = h6 - Double(i)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        switch i % 6 {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }

    // MARK: - Color accessors (derive from the canonical hex)

    func chartColor(for mgDl: Int) -> Color { chartColorHex(for: mgDl).toColor() }
    func bubbleColor(for mgDl: Int) -> Color { bubbleColorHex(for: mgDl).toColor() }

    // MARK: - Display-unit conversion (chart Y-values only)

    /// mg/dL → display value for the chart. Replicates the phone's `Int.asMmolL`
    /// (× 0.0555, rounded to 1 decimal, plain) so chart points sit on the phone-sent y-axis.
    func displayValue(forMgDl mgDl: Int) -> Double {
        guard isMmolL else { return Double(mgDl) }
        var product = Decimal(mgDl) * exchangeRate
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 1, .plain)
        return NSDecimalNumber(decimal: rounded).doubleValue
    }

    // MARK: - Display strings (current-glucose bubble + delta)

    /// Display-ready string for a glucose value, matching the phone's `Int.formatted(for:)`:
    /// mmol/L → "5.6" (one decimal); mg/dL → "100" (bare integer). The snapshot sanitizer
    /// (`TrioComplicationSnapshot.sanitizedGlucose`) collapses whole-number mmol (e.g. "10.0" → "10").
    func displayString(forMgDl mgDl: Int) -> String {
        guard isMmolL else { return String(mgDl) }
        return String(format: "%.1f", displayValue(forMgDl: mgDl))
    }

    /// Display-ready signed string for a glucose delta. mmol/L → "+0.1"/"-0.2"; mg/dL → "+5"/"-3".
    /// mmol converts EACH operand to scale-1 mmol (matching the phone's per-reading `asMmolL`
    /// rounding, which subtracts the two rounded values) so watch and phone can't disagree on a
    /// half-boundary. The snapshot sanitizer normalizes sign/precision (e.g. "+0.0" → "+0").
    func displayDeltaString(previousMgDl prev: Int, currentMgDl curr: Int) -> String {
        guard isMmolL else { return String(format: "%+d", curr - prev) }
        var prevProduct = Decimal(prev) * exchangeRate
        var prevRounded = Decimal()
        NSDecimalRound(&prevRounded, &prevProduct, 1, .plain)
        var currProduct = Decimal(curr) * exchangeRate
        var currRounded = Decimal()
        NSDecimalRound(&currRounded, &currProduct, 1, .plain)
        return String(format: "%+.1f", NSDecimalNumber(decimal: currRounded - prevRounded).doubleValue)
    }
}
