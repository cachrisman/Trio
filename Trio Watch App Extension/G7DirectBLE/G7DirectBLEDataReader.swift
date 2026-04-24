import Foundation

/// Small endian-aware `Data` readers used by G7 message parsers.
///
/// Scoped to this module so we don't add to the global `Data` namespace.
/// Semantics match the helpers in `G7SensorKit/Common/Data.swift` — little-
/// endian `FixedWidthInteger` reads.
enum G7DirectBLEDataReader {
    /// Little-endian integer read from `data[range]`. If the range is
    /// out of bounds or incomplete, returns `nil`.
    static func integer<T: FixedWidthInteger>(from data: Data, range: Range<Int>) -> T? {
        guard range.lowerBound >= data.startIndex,
              range.upperBound <= data.endIndex,
              range.count >= MemoryLayout<T>.size
        else { return nil }

        let slice = data.subdata(in: range)
        return slice.withUnsafeBytes { raw -> T in
            var value: T = 0
            let bytes = min(raw.count, MemoryLayout<T>.size)
            withUnsafeMutableBytes(of: &value) { dst in
                for i in 0..<bytes {
                    dst[i] = raw[i]
                }
            }
            return T(littleEndian: value)
        }
    }

    /// Convenience: returns 0 on out-of-bounds, matches G7SensorKit's
    /// defaults (those parsers assume bounds; we guard anyway).
    static func integerOrZero<T: FixedWidthInteger>(from data: Data, range: Range<Int>) -> T {
        return integer(from: data, range: range) ?? 0
    }

    /// Hex preview of at most `maxBytes` for logging. Values are lowercase
    /// and unseparated (matches DiaBLE's `hexadecimalString`).
    static func hexPrefix(_ data: Data, maxBytes: Int = 12) -> String {
        let count = min(data.count, maxBytes)
        var out = ""
        out.reserveCapacity(count * 2)
        for i in 0..<count {
            out += String(format: "%02x", data[data.startIndex + i])
        }
        if data.count > maxBytes {
            out += "…(+\(data.count - maxBytes))"
        }
        return out
    }
}
