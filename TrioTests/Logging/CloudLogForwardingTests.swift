import Foundation
import XCTest

#if CLOUD_LOG_HARNESS
    @testable import Logic
#else
    @testable import Trio
#endif

final class CloudLogForwardingTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    // MARK: Filter

    func testForwardsErrorAndConnectionTypes() {
        XCTAssertTrue(DeviceLogForwardingFilter.shouldForward(typeRawValue: "error", message: "boom"))
        XCTAssertTrue(DeviceLogForwardingFilter.shouldForward(typeRawValue: "connection", message: "linked"))
    }

    func testForwardsLatencyAndConnectedTraces() {
        XCTAssertTrue(DeviceLogForwardingFilter.shouldForward(typeRawValue: "delegate", message: "connect latency 1.2s"))
        XCTAssertTrue(DeviceLogForwardingFilter.shouldForward(typeRawValue: "receive", message: "state CONNECTED"))
    }

    func testDropsHexAndDelegateTraffic() {
        for type in ["send", "receive", "delegate", "delegateResponse"] {
            XCTAssertFalse(DeviceLogForwardingFilter.shouldForward(typeRawValue: type, message: "0x4A 0B 11 FF"), type)
        }
    }

    func testLevelMapping() {
        XCTAssertTrue(DeviceLogForwardingFilter.isWarning(typeRawValue: "error"))
        XCTAssertFalse(DeviceLogForwardingFilter.isWarning(typeRawValue: "connection"))
    }

    // MARK: Message

    func testMessageFormat() {
        let decision = DeviceLogForwardingPolicy().decide(managerIdentifier: "G7", typeRawValue: "error", message: "bad")
        XCTAssertEqual(decision, .init(isWarning: true, text: "G7 [error] bad"))
    }

    func testTruncatesTo1000Characters() {
        let decision = DeviceLogForwardingPolicy().decide(
            managerIdentifier: "G7",
            typeRawValue: "error",
            message: String(repeating: "x", count: 5000)
        )
        XCTAssertEqual(decision?.text.count, 1000)
        XCTAssertTrue(decision?.text.hasPrefix("G7 [error] xxx") == true)
    }

    // MARK: Backfill rate limit

    func testBackfillRateLimitAndSuppressedCount() {
        let clock = Clock()
        let policy = DeviceLogForwardingPolicy(clock: { clock.now })
        let message = "Backfill frame of unexpected length 7"
        func decide() -> DeviceLogForwardingPolicy.Decision? {
            policy.decide(managerIdentifier: "G7", typeRawValue: "error", message: message)
        }
        XCTAssertEqual(decide()?.text, "G7 [error] \(message)")
        clock.advance(10)
        XCTAssertNil(decide())
        clock.advance(100)
        XCTAssertNil(decide())
        clock.advance(300)
        XCTAssertEqual(decide()?.text, "G7 [error] \(message) (+2 suppressed)")
        clock.advance(1)
        XCTAssertNil(decide())
        clock.advance(300)
        XCTAssertEqual(decide()?.text, "G7 [error] \(message) (+1 suppressed)")
    }

    func testBackfillSuffixStaysWithinLimit() {
        let clock = Clock()
        let policy = DeviceLogForwardingPolicy(clock: { clock.now })
        let message = "Backfill frame of unexpected length " + String(repeating: "y", count: 2000)
        _ = policy.decide(managerIdentifier: "G7", typeRawValue: "error", message: message)
        _ = policy.decide(managerIdentifier: "G7", typeRawValue: "error", message: message)
        clock.advance(301)
        let text = policy.decide(managerIdentifier: "G7", typeRawValue: "error", message: message)?.text
        XCTAssertEqual(text?.count, 1000)
        XCTAssertTrue(text?.hasSuffix(" (+1 suppressed)") == true)
    }

    func testOtherMessagesAreNotRateLimited() {
        let policy = DeviceLogForwardingPolicy()
        XCTAssertNotNil(policy.decide(managerIdentifier: "G7", typeRawValue: "error", message: "a"))
        XCTAssertNotNil(policy.decide(managerIdentifier: "G7", typeRawValue: "error", message: "a"))
    }

    // MARK: Determination dedupe

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testDedupeReportsNewOnce() {
        var dedupe = DeterminationDedupe<Int>()
        XCTAssertEqual(dedupe.observe(id: 1, enacted: false, date: now, now: now), .new)
        XCTAssertEqual(dedupe.observe(id: 1, enacted: false, date: now, now: now), .none)
    }

    func testEnactedFlipReportedOnce() {
        var dedupe = DeterminationDedupe<Int>()
        XCTAssertEqual(dedupe.observe(id: 1, enacted: false, date: now, now: now), .new)
        XCTAssertEqual(dedupe.observe(id: 1, enacted: true, date: now, now: now), .enactedFlip)
        XCTAssertEqual(dedupe.observe(id: 1, enacted: true, date: now, now: now), .none)
    }

    func testAlreadyEnactedNewIsNotFlip() {
        var dedupe = DeterminationDedupe<Int>()
        XCTAssertEqual(dedupe.observe(id: 1, enacted: true, date: now, now: now), .new)
        XCTAssertEqual(dedupe.observe(id: 1, enacted: true, date: now, now: now), .none)
    }

    func testMemoryIsBounded() {
        var dedupe = DeterminationDedupe<Int>(capacity: 100)
        for id in 0 ..< 1000 {
            XCTAssertEqual(dedupe.observe(id: id, enacted: false, date: now, now: now), .new)
        }
        XCTAssertEqual(dedupe.count, 100)
        // Evicted IDs are forgotten; recent ones are still deduped
        XCTAssertEqual(dedupe.observe(id: 999, enacted: false, date: now, now: now), .none)
        XCTAssertEqual(dedupe.observe(id: 0, enacted: false, date: now, now: now), .new)
    }

    func testStaleOrFutureUnseenDeterminationIsIgnored() {
        var dedupe = DeterminationDedupe<Int>()
        XCTAssertEqual(dedupe.observe(id: 1, enacted: false, date: now.addingTimeInterval(-16 * 60), now: now), .none)
        XCTAssertEqual(dedupe.observe(id: 2, enacted: false, date: now.addingTimeInterval(16 * 60), now: now), .none)
        XCTAssertEqual(dedupe.count, 0)
    }

    func testNilDateIsIgnored() {
        var dedupe = DeterminationDedupe<Int>()
        XCTAssertEqual(dedupe.observe(id: 1, enacted: false, date: nil, now: now), .none)
    }

    func testRecentDeterminationIsNew() {
        var dedupe = DeterminationDedupe<Int>()
        XCTAssertEqual(dedupe.observe(id: 1, enacted: false, date: now.addingTimeInterval(-14 * 60), now: now), .new)
    }

    func testEnactedFlipWithStaleDateIsIgnored() {
        var dedupe = DeterminationDedupe<Int>()
        XCTAssertEqual(dedupe.observe(id: 1, enacted: false, date: now, now: now), .new)
        let later = now.addingTimeInterval(20 * 60)
        XCTAssertEqual(dedupe.observe(id: 1, enacted: true, date: now, now: later), .none)
        XCTAssertEqual(dedupe.observe(id: 1, enacted: true, date: later, now: later), .none)
    }
}
