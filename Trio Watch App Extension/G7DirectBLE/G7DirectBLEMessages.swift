import Foundation

// MARK: - Auth challenge (observed, never owned)

/// Parses the authentication-characteristic notification described in
/// `G7SensorKit/Messages/AuthChallengeRxMessage.swift`.
///
/// Observer-only contract: Trio **reads** this to decide when to advance;
/// Trio **never writes** an auth challenge. Two `Bool` flags are exposed
/// (`isAuthenticated`, `isBonded`) — the advance condition is in the
/// observer, not here.
struct G7DirectAuthChallenge: Equatable {
    let isAuthenticated: Bool
    let isBonded: Bool
    let rawHexPrefix: String

    init?(data: Data) {
        guard data.count >= 3 else { return nil }
        guard data.first == G7DirectBLEConstants.authChallengeRxOpcode else { return nil }
        self.isAuthenticated = data[data.startIndex + 1] == 0x01
        self.isBonded = data[data.startIndex + 2] == 0x01
        self.rawHexPrefix = G7DirectBLEDataReader.hexPrefix(data)
    }
}

// MARK: - Glucose (EGV) control response

/// Parses the 19-byte `0x4e` EGV response from the control characteristic.
/// Byte layout mirrors `G7SensorKit/Messages/G7GlucoseMessage.swift` (and
/// the comment block in `DiaBLE/DexcomG7.swift` `.egv` case). Do not rename
/// fields casually — BetterStack filters match on the log field names.
struct G7DirectGlucoseMessage: Equatable {
    /// Seconds since pairing, when the message itself was built.
    let messageTimestamp: UInt32
    /// Sequence number.
    let sequence: UInt16
    /// Seconds between the sensor reading and the BLE comms.
    let age: UInt16
    /// mg/dL or nil if the sensor did not report a valid value.
    let glucose: UInt16?
    /// Algorithm state byte (see `AlgorithmState` in G7SensorKit).
    let algorithmState: UInt8
    /// Predicted glucose in mg/dL or nil.
    let predicted: UInt16?
    /// Trend rate in mg/dL per minute; nil if sensor reported 0x7f.
    let trendRate: Double?
    /// Display-only flag (calibration byte bit 0x10).
    let glucoseIsDisplayOnly: Bool
    /// Raw calibration byte.
    let calibration: UInt8

    /// Convenience: `messageTimestamp - age` — seconds since pairing at
    /// the moment the sensor reading was taken.
    var glucoseTimestamp: UInt32 {
        messageTimestamp &- UInt32(age)
    }

    init?(data: Data) {
        // 0  1  2 3 4 5  6 7  8  9 1011 1213 14 15 1617 18
        //      TTTTTTTT SQSQ       AGAG BGBG SS TR PRPR C
        // 0x4e 00 d5070000 0900 00 01 0500 6100 06 01 ffff 0e
        guard data.count >= 19 else { return nil }
        let base = data.startIndex
        guard data[base] == G7DirectBLEConstants.egvRequestOpcode else { return nil }
        guard data[base + 1] == 0x00 else { return nil }

        guard
            let messageTimestamp: UInt32 = G7DirectBLEDataReader.integer(
                from: data,
                range: (base + 2)..<(base + 6)
            ),
            let sequence: UInt16 = G7DirectBLEDataReader.integer(
                from: data,
                range: (base + 6)..<(base + 8)
            ),
            let age: UInt16 = G7DirectBLEDataReader.integer(
                from: data,
                range: (base + 10)..<(base + 12)
            )
        else { return nil }

        self.messageTimestamp = messageTimestamp
        self.sequence = sequence
        self.age = age

        let rawGlucose: UInt16 = G7DirectBLEDataReader.integerOrZero(
            from: data,
            range: (base + 12)..<(base + 14)
        )
        self.algorithmState = data[base + 14]

        let rawTrendByte = data[base + 15]
        if rawTrendByte == 0x7f {
            self.trendRate = nil
        } else {
            self.trendRate = Double(Int8(bitPattern: rawTrendByte)) / 10.0
        }

        let rawPredicted: UInt16 = G7DirectBLEDataReader.integerOrZero(
            from: data,
            range: (base + 16)..<(base + 18)
        )
        self.calibration = data[base + 18]

        if rawGlucose != 0xffff {
            self.glucose = rawGlucose & 0x0fff
            self.glucoseIsDisplayOnly = (self.calibration & 0x10) != 0
        } else {
            self.glucose = nil
            self.glucoseIsDisplayOnly = false
        }

        if rawPredicted != 0xffff {
            self.predicted = rawPredicted & 0x0fff
        } else {
            self.predicted = nil
        }
    }

    // MARK: - Derived display fields

    /// Maps the trend rate to the Nightscout-style arrow string the
    /// watch UI / `WatchState.trend` expects downstream. Thresholds match
    /// `WatchState.hkTrendString` so BLE and HK-derived snapshots produce
    /// equivalent arrow strings for the same slope.
    ///
    /// `trendRate` here is mg/dL per minute. The HK helper uses mg/dL per
    /// 5-minute reading delta, so we multiply by 5 before bucketing.
    var nightscoutArrowString: String {
        guard let trendRate else { return "" }
        let fiveMinDelta = trendRate * 5.0
        switch fiveMinDelta {
        case ..<(-30): return "DoubleDown"
        case -30 ..< -20: return "SingleDown"
        case -20 ..< -10: return "FortyFiveDown"
        case -10 ..< 10: return "Flat"
        case 10 ..< 20: return "FortyFiveUp"
        case 20 ..< 30: return "SingleUp"
        default: return "DoubleUp"
        }
    }

    /// mg/dL display string ("--" if no valid glucose).
    var glucoseDisplayString: String {
        guard let glucose else { return "--" }
        return String(glucose)
    }

    /// `readingDate` given a known sensor activation date. Prefer computing
    /// `activationDate` from this message's own `messageTimestamp` when no
    /// prior activation anchor exists — see observer §3.10.
    func readingDate(activationDate: Date) -> Date {
        activationDate.addingTimeInterval(TimeInterval(glucoseTimestamp))
    }
}

// MARK: - Backfill (observed, not forwarded in this POC)

/// Parses a 9-byte backfill packet. See
/// `G7SensorKit/G7CGMManager/G7BackfillMessage.swift`. Observer logs
/// these but does not currently push them into the data store
/// (design §11).
struct G7DirectBackfillMessage: Equatable {
    let timestamp: UInt32
    let glucose: UInt16?
    let glucoseIsDisplayOnly: Bool
    let algorithmState: UInt8
    let trendRate: Double?

    init?(data: Data) {
        //    0 1 2  3  4 5  6  7  8
        //   TTTTTT    BGBG SS    TR
        //   45a100 00 9600 06 0f fc
        guard data.count == 9 else { return nil }
        let base = data.startIndex
        // 24-bit LE timestamp read as a UInt32 over bytes 0..3, masked to
        // the low 3 bytes.
        guard let ts24: UInt32 = G7DirectBLEDataReader.integer(
            from: data,
            range: base..<(base + 4)
        ) else { return nil }
        self.timestamp = ts24 & 0x00ffffff

        let rawGlucose: UInt16 = G7DirectBLEDataReader.integerOrZero(
            from: data,
            range: (base + 4)..<(base + 6)
        )
        if rawGlucose != 0xffff {
            self.glucose = rawGlucose & 0x0fff
        } else {
            self.glucose = nil
        }

        self.algorithmState = data[base + 6]
        self.glucoseIsDisplayOnly = (data[base + 7] & 0x10) != 0

        let rawTrendByte = data[base + 8]
        if rawTrendByte == 0x7f {
            self.trendRate = nil
        } else {
            self.trendRate = Double(Int8(bitPattern: rawTrendByte)) / 10.0
        }
    }
}
