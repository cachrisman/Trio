import Foundation
import Testing

@testable import Trio

@Suite("Sleep mode provider") struct SleepModeProviderTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: hour, minute: minute))!
    }

    private func makeDefaults() -> UserDefaults {
        let name = "SleepModeProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeProvider(
        _ defaults: UserDefaults,
        log: @escaping (String) -> Void = { _ in }
    ) -> SleepModeProvider {
        let cal = calendar
        return SleepModeProvider(defaults: defaults, calendar: { cal }, log: log)
    }

    @Test("Default window 22:00-06:00 wraps midnight") func defaultWindow() {
        let p = makeProvider(makeDefaults())
        #expect(p.isAsleep(now: at(22)))
        #expect(p.isAsleep(now: at(23, 59)))
        #expect(p.isAsleep(now: at(0)))
        #expect(p.isAsleep(now: at(5, 59)))
        #expect(!p.isAsleep(now: at(6)))
        #expect(!p.isAsleep(now: at(12)))
        #expect(!p.isAsleep(now: at(21, 59)))
    }

    @Test("Custom same-day window") func customWindow() {
        let p = makeProvider(makeDefaults())
        p.quietStartMinutes = 13 * 60
        p.quietEndMinutes = 15 * 60
        #expect(p.isAsleep(now: at(14)))
        #expect(!p.isAsleep(now: at(15)))
        #expect(!p.isAsleep(now: at(23)))
    }

    @Test("Start equal to end is never asleep") func emptyWindow() {
        let p = makeProvider(makeDefaults())
        p.quietStartMinutes = 8 * 60
        p.quietEndMinutes = 8 * 60
        #expect(!p.isAsleep(now: at(8)))
        #expect(!p.isAsleep(now: at(23)))
    }

    @Test("Filter on then off overrides the window, including inside it") func filterOverrides() {
        let p = makeProvider(makeDefaults())
        p.reportFilter(isOn: false, at: at(12))
        #expect(!p.isAsleep(now: at(23))) // inside window, filter says awake
        p.reportFilter(isOn: true, at: at(13))
        #expect(p.isAsleep(now: at(12))) // outside window, filter says asleep
        p.reportFilter(isOn: false, at: at(14))
        #expect(!p.isAsleep(now: at(2)))
    }

    @Test("State survives a new provider on the same storage") func persistence() {
        let defaults = makeDefaults()
        let first = makeProvider(defaults)
        first.quietStartMinutes = 21 * 60 + 30
        first.reportFilter(isOn: true, at: at(12))
        let second = makeProvider(defaults)
        #expect(second.hasFilterReported)
        #expect(second.isAsleep(now: at(12)))
        #expect(second.quietStartMinutes == 21 * 60 + 30)
        second.reportFilter(isOn: false, at: at(13))
        #expect(!makeProvider(defaults).isAsleep(now: at(23)))
    }

    @Test("A transition is logged once, not on every evaluation") func logsOncePerTransition() {
        var lines: [String] = []
        let p = makeProvider(makeDefaults(), log: { lines.append($0) })
        #expect(!p.isAsleep(now: at(12)))
        #expect(lines.isEmpty) // cold start awake is not a transition
        _ = p.isAsleep(now: at(22, 5))
        _ = p.isAsleep(now: at(22, 10))
        #expect(lines == ["sleep_mode state=asleep source=quiet_window"])
        _ = p.isAsleep(now: at(6, 1))
        _ = p.isAsleep(now: at(6, 2))
        #expect(lines.count == 2)
        #expect(lines[1] == "sleep_mode state=awake source=quiet_window")
        p.reportFilter(isOn: true, at: at(12))
        _ = p.isAsleep(now: at(12, 1))
        #expect(lines.count == 3)
        #expect(lines[2] == "sleep_mode state=asleep source=focus_filter")
        p.reportFilter(isOn: false, at: at(13))
        #expect(lines.count == 4)
        #expect(lines[3] == "sleep_mode state=awake source=focus_filter")
    }

    @Test("An asleep filter report goes stale after 16 h and falls back to the window") func filterStaleness() {
        #expect(SleepModeProvider.filterStaleAfter == 16 * 3600)
        var lines: [String] = []
        let p = makeProvider(makeDefaults(), log: { lines.append($0) })
        let reportedAt = at(12)
        p.reportFilter(isOn: true, at: reportedAt)
        #expect(lines == ["sleep_mode state=asleep source=focus_filter"])
        #expect(p.isAsleep(now: reportedAt.addingTimeInterval(15 * 3600))) // 03:00, still counts
        #expect(lines.count == 1)
        // 17 h later is 05:00 next day: inside the quiet window, so still asleep, but the source changed.
        #expect(p.isAsleep(now: reportedAt.addingTimeInterval(17 * 3600)))
        #expect(p.isAsleep(now: reportedAt.addingTimeInterval(17 * 3600 + 60)))
        #expect(lines.count == 2)
        #expect(lines[1] == "sleep_mode state=asleep source=focus_filter_stale")
        // Outside the window the stale report reads as awake.
        #expect(!p.isAsleep(now: reportedAt.addingTimeInterval(30 * 3600))) // 18:00
        #expect(lines.last == "sleep_mode state=awake source=focus_filter_stale")
        // A new report restores normal behaviour.
        p.reportFilter(isOn: true, at: reportedAt.addingTimeInterval(30 * 3600))
        #expect(p.isAsleep(now: reportedAt.addingTimeInterval(31 * 3600)))
        #expect(lines.last == "sleep_mode state=asleep source=focus_filter")
    }

    @Test("An awake filter report never goes stale") func awakeReportNeverStale() {
        let p = makeProvider(makeDefaults())
        p.reportFilter(isOn: false, at: at(12))
        #expect(!p.isAsleep(now: at(12).addingTimeInterval(40 * 3600)))
        #expect(!p.isAsleep(now: at(23).addingTimeInterval(40 * 3600)))
    }

    @Test("Concurrent reports and evaluations end on the last report") func concurrencySmoke() async {
        let p = makeProvider(makeDefaults())
        let base = at(12)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask { p.reportFilter(isOn: i % 2 == 0, at: base) }
                group.addTask { _ = p.isAsleep(now: base) }
            }
        }
        p.reportFilter(isOn: true, at: base)
        #expect(p.isAsleep(now: base))
        p.reportFilter(isOn: false, at: base)
        #expect(!p.isAsleep(now: base))
        #expect(p.hasFilterReported)
    }
}
