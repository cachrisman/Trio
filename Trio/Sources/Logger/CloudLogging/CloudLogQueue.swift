import Foundation
import os

// The upload cursor is a (segment, byte offset) pair rather than a timestamp: watch rows arrive hours late
// carrying their original timestamps, so a "last uploaded timestamp" would skip them or re-send everything.
// The queue is strictly FIFO in arrival order, and the cursor marks the next unread line in that order.
final class CloudLogQueue: @unchecked Sendable {
    static let shared = CloudLogQueue()

    struct Cursor: Codable, Equatable {
        var segment: UInt64
        var offset: UInt64
    }

    struct Batch {
        var start: Cursor
        var items: [(record: LogRecord, end: Cursor)]
        /// Rows skipped immediately before each item (parallel to `items`); never persisted.
        var itemSkips: [Int]
        /// Cursor after everything this batch read; equals the last item's end when there are items.
        var end: Cursor
        /// Part of the dropped counter that is persisted in state; `commit` subtracts it.
        var persistedDropped: UInt64
        /// Undecodable or over-long rows skipped while reading this batch; reported once, not persisted.
        var skippedInBatch: UInt64

        var droppedToReport: UInt64 { persistedDropped &+ skippedInBatch }
    }

    private struct State: Codable {
        var segment: UInt64
        var offset: UInt64
        var dropped: UInt64
    }

    private struct Segment {
        let seq: UInt64
        let url: URL
    }

    private static let log = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.nightscout.Trio",
        category: "CloudLogging"
    )

    private static let newline = UInt8(ascii: "\n")
    private static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CloudLogQueue", isDirectory: true)
    }

    private let directory: URL
    private let segmentMaxBytes: Int
    private let maxTotalBytes: Int
    private let maxAge: TimeInterval
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "org.nightscout.Trio.CloudLogQueue", qos: .utility)
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // Everything below is confined to `queue`.
    private var cursor = Cursor(segment: 1, offset: 0)
    private var dropped: UInt64 = 0
    private var activeSeq: UInt64 = 1
    private var activeSize: UInt64 = 0

    init(
        directory: URL = CloudLogQueue.defaultDirectory,
        segmentMaxBytes: Int = 1_000_000,
        maxTotalBytes: Int = 32_000_000,
        maxAge: TimeInterval = 7 * 24 * 60 * 60,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.segmentMaxBytes = segmentMaxBytes
        self.maxTotalBytes = maxTotalBytes
        self.maxAge = maxAge
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder

        queue.sync { self.setUp() }
    }

    func append(_ records: [LogRecord]) {
        guard !records.isEmpty else { return }
        queue.async { self.write(records) }
    }

    func appendSync(_ records: [LogRecord]) {
        guard !records.isEmpty else { return }
        queue.sync { self.write(records) }
    }

    func addDropped(_ n: UInt64) {
        guard n > 0 else { return }
        queue.async {
            self.dropped &+= n
            self.saveState()
        }
    }

    func nextBatch(maxBytes: Int, maxRecords: Int) async -> Batch? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.readBatch(maxBytes: maxBytes, maxRecords: maxRecords))
            }
        }
    }

    func commit(through end: Cursor, droppedReported: UInt64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if Self.precedes(self.cursor, end) {
                    self.cursor = end
                }
                self.dropped = self.dropped >= droppedReported ? self.dropped - droppedReported : 0
                for segment in self.listSegments() where segment.seq < self.cursor.segment && segment.seq != self.activeSeq {
                    self.removeFile(segment.url)
                }
                self.saveState()
                continuation.resume()
            }
        }
    }

    // MARK: - Setup

    private func setUp() {
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: Self.protection]
            )
            try fileManager.setAttributes([.protectionKey: Self.protection], ofItemAtPath: directory.path)
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            Self.log.error("Queue directory setup failed: \(error.localizedDescription, privacy: .public)")
        }

        var segments = listSegments()
        if segments.isEmpty {
            createSegment(seq: 1)
            segments = listSegments()
        }
        guard let oldest = segments.first, let active = segments.last else { return }
        activeSeq = active.seq

        var loaded: State?
        if let data = try? Data(contentsOf: stateURL) {
            loaded = try? JSONDecoder().decode(State.self, from: data)
        }
        if let loaded {
            cursor = Cursor(segment: loaded.segment, offset: loaded.offset)
            dropped = loaded.dropped
        } else {
            cursor = Cursor(segment: oldest.seq, offset: 0)
            dropped = 0
        }

        if let current = segments.first(where: { $0.seq == cursor.segment }) {
            let size = fileSize(current.url)
            if cursor.offset > size { cursor.offset = size }
        } else {
            cursor = Cursor(segment: oldest.seq, offset: 0)
        }

        activeSize = fileSize(active.url)
        if activeSize > 0, lastByte(of: active.url, size: activeSize) != Self.newline {
            writeToActive(Data([Self.newline]))
        }

        enforceCaps()
        saveState()
    }

    // MARK: - Writing

    private func write(_ records: [LogRecord]) {
        var buffer = Data()
        for record in records {
            guard var line = try? encoder.encode(record) else {
                dropped &+= 1
                continue
            }
            line.append(Self.newline)
            if activeSize > 0, activeSize + UInt64(buffer.count) + UInt64(line.count) > UInt64(segmentMaxBytes) {
                writeToActive(buffer)
                buffer.removeAll(keepingCapacity: true)
                rotate()
            }
            buffer.append(line)
        }
        writeToActive(buffer)
        if activeSize >= UInt64(segmentMaxBytes) {
            rotate()
        }
        enforceCaps()
    }

    private func writeToActive(_ data: Data) {
        guard !data.isEmpty else { return }
        let url = segmentURL(activeSeq)
        if !fileManager.fileExists(atPath: url.path) {
            createSegment(seq: activeSeq)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            activeSize += UInt64(data.count)
        } catch {
            dropped &+= UInt64(data.reduce(0) { $1 == Self.newline ? $0 + 1 : $0 })
            Self.log.error("Segment write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rotate() {
        guard activeSize > 0 else { return }
        activeSeq += 1
        activeSize = 0
        createSegment(seq: activeSeq)
    }

    private func createSegment(seq: UInt64) {
        let url = segmentURL(seq)
        if !fileManager.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: Self.protection]) {
            Self.log.error("Could not create segment \(seq)")
        }
    }

    // MARK: - Caps

    private func enforceCaps() {
        var changed = false
        while true {
            let segments = listSegments()
            guard let oldest = segments.first else { break }
            let total = segments.reduce(UInt64(0)) { $0 + fileSize($1.url) }
            let modified = (try? fileManager.attributesOfItem(atPath: oldest.url.path)[.modificationDate]) as? Date
            let tooBig = total > UInt64(maxTotalBytes)
            let tooOld = modified.map { Date().timeIntervalSince($0) > maxAge } ?? false
            guard tooBig || tooOld else { break }

            if oldest.seq == activeSeq {
                if segments.count > 1 { break }
                if activeSize == 0 {
                    activeSeq += 1
                    createSegment(seq: activeSeq)
                } else {
                    rotate()
                }
            }

            dropped &+= unreadLines(in: oldest)
            removeFile(oldest.url)
            if let next = listSegments().first, cursor.segment <= oldest.seq {
                cursor = Cursor(segment: next.seq, offset: 0)
            }
            changed = true
        }
        if changed { saveState() }
    }

    private func unreadLines(in segment: Segment) -> UInt64 {
        if segment.seq < cursor.segment { return 0 }
        guard let data = try? Data(contentsOf: segment.url) else { return 0 }
        let start = segment.seq == cursor.segment ? Int(min(cursor.offset, UInt64(data.count))) : 0
        var count: UInt64 = 0
        for byte in data[start...] where byte == Self.newline {
            count += 1
        }
        return count
    }

    // MARK: - Reading

    private func readBatch(maxBytes: Int, maxRecords: Int) -> Batch? {
        let start = cursor
        var pos = cursor
        var items: [(record: LogRecord, end: Cursor)] = []
        var itemSkips: [Int] = []
        var pendingSkips = 0
        var bytes = 0
        var limitHit = false
        var skippingOverlongLine = false

        while !limitHit {
            let segments = listSegments()
            guard let segment = segments.first(where: { $0.seq == pos.segment }) else {
                guard let next = segments.first(where: { $0.seq > pos.segment }) else { break }
                pos = Cursor(segment: next.seq, offset: 0)
                continue
            }
            let isActive = segment.seq == activeSeq

            guard let data = readWindow(of: segment.url, offset: pos.offset, length: maxBytes), !data.isEmpty else {
                if !isActive, let next = segments.first(where: { $0.seq > segment.seq }) {
                    pos = Cursor(segment: next.seq, offset: 0)
                    continue
                }
                break
            }

            var consumed = 0
            let windowStart = pos.offset
            while consumed < data.count {
                let from = data.startIndex + consumed
                guard let newlineIndex = data[from...].firstIndex(of: Self.newline) else { break }
                let lineLength = newlineIndex - from + 1
                if !items.isEmpty, bytes + lineLength > maxBytes {
                    limitHit = true
                    break
                }
                let lineEnd = Cursor(segment: segment.seq, offset: windowStart + UInt64(consumed + lineLength))
                consumed += lineLength
                if skippingOverlongLine {
                    // Tail of an over-long row already counted as one skip
                    skippingOverlongLine = false
                } else if lineLength > 1 {
                    let line = Data(data[from..<newlineIndex])
                    if let record = try? decoder.decode(LogRecord.self, from: line) {
                        items.append((record, lineEnd))
                        itemSkips.append(pendingSkips)
                        pendingSkips = 0
                        bytes += lineLength
                    } else {
                        pendingSkips += 1
                    }
                }
                pos = lineEnd
                if items.count >= maxRecords || bytes >= maxBytes {
                    limitHit = true
                    break
                }
            }
            if limitHit { break }

            if consumed == 0 {
                if data.count >= maxBytes {
                    let skipEnd = Cursor(segment: segment.seq, offset: pos.offset + UInt64(data.count))
                    if !skippingOverlongLine { pendingSkips += 1 }
                    skippingOverlongLine = true
                    pos = skipEnd
                } else if !isActive, let next = segments.first(where: { $0.seq > segment.seq }) {
                    pos = Cursor(segment: next.seq, offset: 0)
                } else {
                    break
                }
            }
        }

        // Skips after the last item are re-read (and counted) by the next batch, so only earlier ones count here.
        let skipped = items.isEmpty ? pendingSkips : itemSkips.reduce(0, +)

        if items.isEmpty, skipped == 0, Self.precedes(cursor, pos) {
            cursor = pos
            saveState()
        } else if dropped != 0 {
            saveState()
        }

        if items.isEmpty, dropped == 0, skipped == 0 { return nil }
        return Batch(
            start: start,
            items: items,
            itemSkips: itemSkips,
            end: items.last?.end ?? pos,
            persistedDropped: dropped,
            skippedInBatch: UInt64(skipped)
        )
    }

    private func readWindow(of url: URL, offset: UInt64, length: Int) -> Data? {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: length)
        } catch {
            Self.log.error("Segment read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Files

    private var stateURL: URL {
        directory.appendingPathComponent("state.json")
    }

    private func segmentURL(_ seq: UInt64) -> URL {
        directory.appendingPathComponent("seg-" + String(format: "%020llu", seq) + ".jsonl")
    }

    private func listSegments() -> [Segment] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> Segment? in
            guard name.hasPrefix("seg-"), name.hasSuffix(".jsonl") else { return nil }
            let digits = name.dropFirst(4).dropLast(6)
            guard let seq = UInt64(digits) else { return nil }
            return Segment(seq: seq, url: directory.appendingPathComponent(name))
        }
        .sorted { $0.seq < $1.seq }
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        return size?.uint64Value ?? 0
    }

    private func lastByte(of url: URL, size: UInt64) -> UInt8? {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: size - 1)
            return try handle.read(upToCount: 1)?.first
        } catch {
            Self.log.error("Segment tail read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func removeFile(_ url: URL) {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            Self.log.error("Segment delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveState() {
        let state = State(segment: cursor.segment, offset: cursor.offset, dropped: dropped)
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.log.error("State save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func precedes(_ lhs: Cursor, _ rhs: Cursor) -> Bool {
        lhs.segment != rhs.segment ? lhs.segment < rhs.segment : lhs.offset < rhs.offset
    }
}
