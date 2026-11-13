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

    #if !CLOUD_LOG_HARNESS
        // MARK: - Cloud log upload failure policy

        func testUploadFailurePolicyRejectsSelectedClientErrorsAndEncoding() {
            XCTAssertEqual(
                CloudLogUploadFailurePolicy.action(for: .unexpectedStatus(code: 400, bodyPreview: nil)),
                .rejectRows
            )
            XCTAssertEqual(
                CloudLogUploadFailurePolicy.action(for: .unexpectedStatus(code: 413, bodyPreview: nil)),
                .rejectRows
            )
            XCTAssertEqual(
                CloudLogUploadFailurePolicy.action(for: .unexpectedStatus(code: 422, bodyPreview: nil)),
                .rejectRows
            )
            XCTAssertEqual(
                CloudLogUploadFailurePolicy.action(for: .encoding(NSError(domain: "t", code: 1))),
                .rejectRows
            )
        }

        func testUploadFailurePolicyRetriesAuthRateLimitAndServerErrors() {
            for code in [401, 403, 404, 408, 429] {
                XCTAssertEqual(
                    CloudLogUploadFailurePolicy.action(for: .unexpectedStatus(code: code, bodyPreview: nil)),
                    .retryLater,
                    "code \(code)"
                )
            }
            XCTAssertEqual(
                CloudLogUploadFailurePolicy.action(for: .unexpectedStatus(code: 503, bodyPreview: nil)),
                .retryLater
            )
            XCTAssertEqual(
                CloudLogUploadFailurePolicy.action(for: .transport(NSError(domain: "t", code: 1))),
                .retryLater
            )
            XCTAssertEqual(
                CloudLogUploadFailurePolicy.action(for: .invalidResponse),
                .retryLater
            )
        }

        // MARK: - Cloud log batch upload drain

        private func testCloudCommon() -> CloudLogCommonAttributes {
            CloudLogCommonAttributes(build: "99", appVersion: "1.0", env: "test")
        }

        private func itemEvents(prefix: String, count: Int) -> [CloudLogEvent] {
            (0 ..< count).map { CloudLogEvent(message: "\(prefix)-\($0)", dt: nil, attributes: nil) }
        }

        private func itemEnds(count: Int, base: UInt64 = 10) -> [CloudLogQueue.Cursor] {
            (0 ..< count).map { CloudLogQueue.Cursor(segment: 1, offset: base + UInt64($0) * 100) }
        }

        private func drainWithFakeUpload(
            itemCount: Int,
            rejectMessage: String?,
            rejectCode: Int = 422,
            permanentReject: Bool = true,
            maxRequests: Int = 100,
            failAll: CloudLogUploadError? = nil
        ) async -> (
            outcome: CloudLogBatchUploadDrain.Outcome,
            requests: Int,
            uploadSizes: [Int],
            commits: [CloudLogQueue.Cursor],
            droppedRows: UInt64,
            visibility: [String]
        ) {
            final class Box: @unchecked Sendable {
                var uploadSizes: [Int] = []
                var commits: [CloudLogQueue.Cursor] = []
                var droppedRows: UInt64 = 0
                var visibility: [String] = []
            }
            let box = Box()
            let events = itemEvents(prefix: "item", count: itemCount)
            let ends = itemEnds(count: itemCount)
            let handlers = CloudLogBatchUploadDrain.Handlers(
                encodedSize: { _ in nil },
                upload: { batch in
                    let payloads = batch.filter { $0.message.hasPrefix("item-") }
                    box.uploadSizes.append(payloads.count)
                    if let failAll {
                        return .failure(failAll)
                    }
                    if let rejectMessage,
                       permanentReject,
                       payloads.contains(where: { $0.message == rejectMessage })
                    {
                        return .failure(.unexpectedStatus(code: rejectCode, bodyPreview: nil))
                    }
                    return .success(())
                },
                commit: { cursor, _ in box.commits.append(cursor) },
                addDropped: { box.droppedRows += $0 },
                logRejectedRow: { _ in },
                uploadDropVisibility: { event in box.visibility.append(event.message) }
            )
            let context = CloudLogBatchUploadDrain.Context(
                itemEvents: events,
                itemEnds: ends,
                itemSkips: Array(repeating: 0, count: itemCount),
                persistedDropped: 0,
                rangeStart: CloudLogQueue.Cursor(segment: 1, offset: 0),
                common: testCloudCommon(),
                maxRequestBytes: 1_000_000,
                maxRequestsPerPass: maxRequests
            )
            var requests = 0
            let outcome = await CloudLogBatchUploadDrain.drain(handlers: handlers, context: context, requests: &requests)
            return (outcome, requests, box.uploadSizes, box.commits, box.droppedRows, box.visibility)
        }

        func testDrainDropsPermanentlyRejectedMiddleRowAndContinues() async {
            let ends = itemEnds(count: 5)
            let result = await drainWithFakeUpload(itemCount: 5, rejectMessage: "item-2", rejectCode: 422)
            XCTAssertEqual(result.outcome, .batchComplete)
            XCTAssertEqual(result.commits, [ends[1], ends[2], ends[4]])
            XCTAssertEqual(result.droppedRows, 1)
            XCTAssertEqual(result.requests, 6)
            XCTAssertTrue(result.visibility.first?.contains("status=422") == true)
            XCTAssertTrue(result.visibility.first?.contains("rows=1") == true)
            XCTAssertTrue(result.visibility.first?.contains("range=1:110..1:210") == true)
        }

        func testDrainStopsOn401WithoutCommitOrDrop() async {
            let result = await drainWithFakeUpload(
                itemCount: 3,
                rejectMessage: nil,
                failAll: .unexpectedStatus(code: 401, bodyPreview: nil)
            )
            XCTAssertEqual(result.outcome, .stopPass)
            XCTAssertTrue(result.commits.isEmpty)
            XCTAssertEqual(result.droppedRows, 0)
            XCTAssertEqual(result.requests, 1)
        }

        func testDrainBisects413OnFourItemBatch() async {
            let result = await drainWithFakeUpload(
                itemCount: 4,
                rejectMessage: "item-0",
                rejectCode: 413,
                maxRequests: 50
            )
            // First attempts bisect the failing range before dropping singleton rows.
            XCTAssertEqual(Array(result.uploadSizes.prefix(3)), [4, 2, 1])
            XCTAssertEqual(result.outcome, .batchComplete)
        }
    #endif
}
