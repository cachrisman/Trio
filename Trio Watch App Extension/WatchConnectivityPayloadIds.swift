import Foundation

/// Normalizes watch ↔ phone payload identifiers from `WCSession` dictionaries.
/// Accepts `String`, `NSString`, `UUID`, and `NSUUID` only (rejects `NSNumber` and other types).
enum WatchConnectivityPayloadIds {
    private static func debugLogUnexpected(_ value: Any?) {
        #if DEBUG
        if let value {
            let typeName = String(describing: type(of: value))
            debugPrint("WatchConnectivityPayloadIds: unexpected payload id type \(typeName)")
        }
        #endif
    }

    /// Returns a canonical UUID string, or `nil` if the value is not a supported type.
    static func payloadIdString(_ value: Any?) -> String? {
        switch value {
        case let s as String:
            return s
        case let s as NSString:
            return s as String
        case let u as UUID:
            return u.uuidString
        case let u as NSUUID:
            return u.uuidString
        case is NSNumber:
            debugLogUnexpected(value)
            return nil
        default:
            if value != nil {
                debugLogUnexpected(value)
            }
            return nil
        }
    }

    /// Extracts payload id strings from an array or `NSArray` value (e.g. `ackIds`, `payloadIds`).
    static func payloadIdStrings(from value: Any?) -> [String] {
        guard let value else { return [] }

        if let anyArray = value as? [Any] {
            return anyArray.compactMap { payloadIdString($0) }
        }

        if let nsArray = value as? NSArray {
            var out: [String] = []
            out.reserveCapacity(nsArray.count)
            for i in 0 ..< nsArray.count {
                if let s = payloadIdString(nsArray[i]) {
                    out.append(s)
                }
            }
            return out
        }

        debugLogUnexpected(value)
        return []
    }
}
