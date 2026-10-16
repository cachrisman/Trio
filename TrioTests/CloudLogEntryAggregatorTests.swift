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

    private func iosLine(_ n: Int) -> String {
        let s = String(format: "%02d", n)
        return "2026-01-01T08:32:\(s)+0100 [DeviceManager] Foo.swift - bar() - \(n) - INFO: line \(n)"
    }

    @Test("entry cap never splits a multi-line stack trace") func testCapKeepsStackTraceWhole() throws {
        let start = try NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T"#)

        // 3 single-line entries, then a 5-line trace (entry #4), then more entries. With a
        // physical-line cap of 5 the cut would land inside the trace; the entry cap must not.
        var lines: [String] = [iosLine(1), iosLine(2), iosLine(3)]
        let traceLines = [iosLine(4), "    at Frame.one()", "    at Frame.two()", "    at Frame.three()", "    at Frame.four()"]
        lines += traceLines
        lines += [iosLine(5), iosLine(6), iosLine(7)]

        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let split = CloudLogEntryAggregator.splitLines(data)
        #expect(split.lines == lines)

        let result = CloudLogEntryAggregator.aggregateCapped(
            lines: split.lines,
            byteCounts: split.byteCounts,
            startPattern: start,
            maxEntries: 5
        )

        #expect(result.entries.count == 5)
        #expect(result.entries[3] == traceLines.joined(separator: "\n"))
        #expect(result.entries[4] == iosLine(5))

        let returnedLines = lines.prefix(3 + 5 + 1)
        let expectedConsumed = returnedLines.reduce(0) { $0 + $1.utf8.count + 1 }
        #expect(result.consumedBytes == expectedConsumed)
        let rest = String(decoding: data.dropFirst(result.consumedBytes), as: UTF8.self)
        #expect(rest.hasPrefix(iosLine(6)))
    }

    @Test("byte accounting is exact with multi-byte and invalid UTF-8") func testExactByteAccounting() throws {
        let start = try NSRegularExpression(pattern: #"^\[\d{4}-\d{2}-\d{2}T"#)

        var data = Data()
        data.append(Data("[2026-01-01T08:35:51+0100] [WatchLogger.swift:169] flushToPhone() → ⌚️ ok\n".utf8))
        data.append(Data("[2026-01-01T08:35:52+0100] bad byte ".utf8))
        data.append(0xFF)
        data.append(Data(" here\n".utf8))
        let thirdStart = data.count
        data.append(Data("[2026-01-01T08:35:53+0100] third\n".utf8))

        let split = CloudLogEntryAggregator.splitLines(data)
        #expect(split.lines.count == 3)
        #expect(split.byteCounts.reduce(0, +) + split.byteCounts.count == data.count)
        // The invalid byte decodes to U+FFFD (3 bytes) but is counted as 1 raw byte.
        #expect(split.lines[1].utf8.count == split.byteCounts[1] + 2)

        let result = CloudLogEntryAggregator.aggregateCapped(
            lines: split.lines,
            byteCounts: split.byteCounts,
            startPattern: start,
            maxEntries: 2
        )
        #expect(result.entries.count == 2)
        #expect(result.consumedBytes == thirdStart)
        #expect(data[thirdStart] == UInt8(ascii: "["))
        #expect(String(decoding: data.dropFirst(result.consumedBytes), as: UTF8.self)
            .hasPrefix("[2026-01-01T08:35:53+0100]"))
    }

    @Test("no cap hit consumes the whole input") func testNoCapHitConsumesAll() throws {
        let start = try NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T"#)
        let lines = [iosLine(1), "{", "}", iosLine(2)]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let split = CloudLogEntryAggregator.splitLines(data)

        let result = CloudLogEntryAggregator.aggregateCapped(
            lines: split.lines,
            byteCounts: split.byteCounts,
            startPattern: start,
            maxEntries: 250
        )
        #expect(result.entries.count == 2)
        #expect(result.consumedBytes == data.count)
    }

    @Test("mid-entry start forms one leading entry that is counted") func testMidEntryStart() throws {
        let start = try NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T"#)
        let lines = ["    at Frame.tail1()", "    at Frame.tail2()", iosLine(1), iosLine(2)]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let split = CloudLogEntryAggregator.splitLines(data)

        let result = CloudLogEntryAggregator.aggregateCapped(
            lines: split.lines,
            byteCounts: split.byteCounts,
            startPattern: start,
            maxEntries: 1
        )
        #expect(result.entries == ["    at Frame.tail1()\n    at Frame.tail2()"])
        let expected = lines.prefix(2).reduce(0) { $0 + $1.utf8.count + 1 }
        #expect(result.consumedBytes == expected)
        #expect(String(decoding: data.dropFirst(result.consumedBytes), as: UTF8.self).hasPrefix(iosLine(1)))
    }
}
