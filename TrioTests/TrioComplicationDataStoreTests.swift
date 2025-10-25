import Foundation
import Testing
@testable import Trio

@Suite("TrioComplicationDataStore Tests") struct TrioComplicationDataStoreTests {
    func makeTempStore() throws -> (TrioComplicationDataStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrioComplicationDataStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let store = TrioComplicationDataStore(
            sharedContainerURLProvider: { tempDir },
            fileManager: FileManager.default,
            shouldMirrorToDocuments: false
        )
        return (store, tempDir)
    }

    @Test("Snapshot sanitization") func testSnapshotSanitizesValues() {
        let snapshot = TrioComplicationSnapshot(
            glucose: " 110 mg/dL ",
            trend: "Flat",
            delta: "0.45",
            readingDate: Date(),
            date: Date()
        )
        #expect(snapshot.glucose == "110")
        #expect(snapshot.trend == "Flat")
        #expect(snapshot.delta == "+0.5")
    }

    @Test("Save and load round-trip") func testSaveAndLoadRoundTrip() throws {
        let (store, tempDir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let timestamp = Date(timeIntervalSince1970: 12345)
        let snapshot = TrioComplicationSnapshot(
            glucose: "123",
            trend: "Flat",
            delta: "+1",
            readingDate: timestamp,
            date: timestamp
        )

        store.save(snapshot)

        let reloaded = store.latestSnapshot()
        #expect(reloaded != nil)
        #expect(reloaded?.glucose == "123")
        #expect(reloaded?.trend == "Flat")
        #expect(reloaded?.delta == "+1")
    }

    @Test("Missing file returns fallback") func testLatestSnapshotMissingFileReturnsFallback() throws {
        let (store, tempDir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fallback = store.latestSnapshot()
        #expect(fallback != nil)
        #expect(fallback?.glucose == "--")
        #expect(fallback?.state == "!!")
    }
}
