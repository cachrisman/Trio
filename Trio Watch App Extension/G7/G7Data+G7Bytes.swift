import Foundation

// Byte helpers following G7SensorKit `Common/Data.swift` patterns (G7SensorKit/Common/Data.swift).

extension Data {
    fileprivate func g7_toDefaultEndian<T: FixedWidthInteger>(_: T.Type) -> T {
        withUnsafeBytes { raw in
            guard raw.count >= MemoryLayout<T>.size, let base = raw.baseAddress else { return 0 }
            return base.loadUnaligned(as: T.self)
        }
    }

    func g7To<T: FixedWidthInteger>(_ type: T.Type) -> T {
        T(littleEndian: g7_toDefaultEndian(T.self))
    }

    /// Four-byte little-endian value (e.g. message timestamp).
    func g7ToUInt32() -> UInt32 {
        g7To(UInt32.self)
    }

    func g7ToUInt16() -> UInt16 {
        g7To(UInt16.self)
    }
}
