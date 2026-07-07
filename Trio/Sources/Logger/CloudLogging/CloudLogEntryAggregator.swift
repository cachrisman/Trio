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
}
