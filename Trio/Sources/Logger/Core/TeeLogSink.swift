import Foundation

// Reads come from the primary sink only; tees are write-only.
final class TeeLogSink: LogSink, Sendable {
    private let primary: any LogSink
    private let tees: [any LogSink]

    init(primary: any LogSink, tees: [any LogSink]) {
        self.primary = primary
        self.tees = tees
    }

    func accept(_ record: LogRecord) {
        primary.accept(record)
        for tee in tees {
            tee.accept(record)
        }
    }

    func flush() async {
        await primary.flush()
        for tee in tees {
            await tee.flush()
        }
    }

    func records(in window: DateInterval, minimumLevel: LogLevel) async -> [LogRecord] {
        await primary.records(in: window, minimumLevel: minimumLevel)
    }
}
