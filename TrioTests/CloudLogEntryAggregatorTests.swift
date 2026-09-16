import Foundation
import Testing

@testable import Trio

@Suite("Cloud Log Entry Aggregation Tests") struct CloudLogEntryAggregatorTests {
    @Test("iOS multi-line entry aggregation groups by timestamp start") func testIOSAggregation() throws {
        let start = try NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T"#)

        let lines: [String] = [
            "2026-01-01T08:32:30+0100 [DeviceManager] Foo.swift - bar() - 1 - INFO: Starting request",
            "{",
            "  \"a\": 1,",
            "  \"b\": 2",
            "}",
            "2026-01-01T08:32:31+0100 [DeviceManager] Foo.swift - bar() - 2 - INFO: Done"
        ]

        let entries = CloudLogEntryAggregator.aggregate(lines: lines, startPattern: start)
        #expect(entries.count == 2)
        #expect(entries[0].contains("\n{\n  \"a\": 1,"))
        #expect(entries[0].hasPrefix("2026-01-01T08:32:30+0100"))
        #expect(entries[1].hasPrefix("2026-01-01T08:32:31+0100"))
    }

    @Test("watch multi-line entry aggregation groups by bracketed timestamp start") func testWatchAggregation() throws {
        let start = try NSRegularExpression(pattern: #"^\[\d{4}-\d{2}-\d{2}T"#)

        let lines: [String] = [
            "[2026-01-01T08:35:51+0100] [WatchLogger.swift:169] flushToPhone() → ⌚️ Something happened",
            "stacktrace line 1",
            "stacktrace line 2",
            "[2026-01-01T08:35:52+0100] [WatchState.swift:1] tick() → Next entry"
        ]

        let entries = CloudLogEntryAggregator.aggregate(lines: lines, startPattern: start)
        #expect(entries.count == 2)
        #expect(entries[0].contains("stacktrace line 1\nstacktrace line 2"))
        #expect(entries[0].hasPrefix("[2026-01-01T08:35:51+0100]"))
        #expect(entries[1].hasPrefix("[2026-01-01T08:35:52+0100]"))
    }
}
