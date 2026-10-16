import Foundation

enum CloudLogEntryAggregator {
    /// Aggregates physical log lines into logical log entries using a start-of-entry regex.
    ///
    /// - Important: `lines` must be physical lines (already split on `\n`) and must not contain trailing `\n`.
    static func aggregate(lines: [String], startPattern: NSRegularExpression) -> [String] {
        guard !lines.isEmpty else { return [] }

        var entries: [String] = []
        var current: [String] = []

        func isStart(_ line: String) -> Bool {
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            return startPattern.firstMatch(in: line, range: range) != nil
        }

        for line in lines {
            if isStart(line) {
                if !current.isEmpty {
                    entries.append(current.joined(separator: "\n"))
                }
                current = [line]
            } else {
                if current.isEmpty {
                    // If we start mid-entry (e.g., offset in the middle), treat it as a single entry.
                    current = [line]
                } else {
                    current.append(line)
                }
            }
        }

        if !current.isEmpty {
            entries.append(current.joined(separator: "\n"))
        }

        return entries
    }

    /// Splits newline-terminated data into physical lines at the byte level.
    ///
    /// Splitting on raw `0x0A` bytes (instead of decoding first) keeps exact byte accounting:
    /// an invalid UTF-8 byte decodes to U+FFFD (3 bytes), so re-encoding a decoded line would no
    /// longer match what is on disk. `byteCounts[i]` is the raw size of `lines[i]` excluding its newline.
    ///
    /// - Important: `data` must end with `0x0A`. Invariant: `byteCounts.reduce(0, +) + byteCounts.count == data.count`.
    static func splitLines(_ data: Data) -> (lines: [String], byteCounts: [Int]) {
        var lines: [String] = []
        var byteCounts: [Int] = []

        var sliceStart = data.startIndex
        for idx in data.indices where data[idx] == 0x0A {
            let slice = data[sliceStart ..< idx]
            lines.append(String(decoding: slice, as: UTF8.self))
            byteCounts.append(slice.count)
            sliceStart = data.index(after: idx)
        }
        // Anything after the last newline would be a partial line; callers guarantee there is none.

        return (lines, byteCounts)
    }

    /// Like `aggregate`, but stops after `maxEntries` complete logical entries so a multi-line
    /// entry is never split by the cap.
    ///
    /// `consumedBytes` is the raw byte length (line bytes plus one newline each) of the physical
    /// lines belonging to the returned entries, so the next pass can resume exactly at the start
    /// line of the first un-returned entry. When the cap is not hit, all lines are consumed.
    ///
    /// - Precondition: `maxEntries >= 1` and `lines.count == byteCounts.count`. For non-empty
    ///   `lines` at least one entry is always returned, so progress is unconditional.
    static func aggregateCapped(
        lines: [String],
        byteCounts: [Int],
        startPattern: NSRegularExpression,
        maxEntries: Int
    ) -> (entries: [String], consumedBytes: Int) {
        precondition(maxEntries >= 1)
        precondition(lines.count == byteCounts.count)
        guard !lines.isEmpty else { return ([], 0) }

        var entries: [String] = []
        var current: [String] = []
        var consumedBytes = 0

        func isStart(_ line: String) -> Bool {
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            return startPattern.firstMatch(in: line, range: range) != nil
        }

        for (index, line) in lines.enumerated() {
            if isStart(line), !current.isEmpty {
                entries.append(current.joined(separator: "\n"))
                current = []
                if entries.count == maxEntries {
                    // `consumedBytes` covers every line before this start line.
                    return (entries, consumedBytes)
                }
            }
            // A mid-entry start (continuation lines first) simply forms the leading entry.
            current.append(line)
            consumedBytes += byteCounts[index] + 1
        }

        entries.append(current.joined(separator: "\n"))
        return (entries, consumedBytes)
    }
}
