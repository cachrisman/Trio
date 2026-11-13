import Combine
import CoreData
import Foundation

// Forwards each new OrefDetermination to the cloud sink (only; the in-app export already reads them from
// CoreData). Subscribes the same way IOBService does.
final class CloudDeterminationLogger: @unchecked Sendable {
    static let shared = CloudDeterminationLogger()

    private let queue = DispatchQueue(label: "CloudDeterminationLogger.queue", qos: .utility)
    private var subscription: AnyCancellable?
    // Confined to `queue`
    private var dedupe = DeterminationDedupe<NSManagedObjectID>(capacity: 100)
    private var started = false

    func start() {
        // Synchronous: entityChangePublisher doesn't replay, so subscribe before start() returns
        queue.sync {
            guard !self.started else { return }
            self.started = true
            self.subscription = CoreDataStack.shared.entityChangePublisher
                .receive(on: self.queue)
                .filteredByEntityName("OrefDetermination")
                .sink { [weak self] ids in self?.handle(ids) }
        }
    }

    private func handle(_ ids: Set<NSManagedObjectID>) {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "cloudDeterminationLogger"
        let lines: [(NSManagedObjectID, Bool, Date?, String)] = context.performAndWait {
            ids.compactMap { id in
                guard let determination = try? context.existingObject(with: id) as? OrefDetermination else { return nil }
                return (
                    id,
                    determination.enacted,
                    determination.deliverAt ?? determination.timestamp,
                    LogExport.algorithmText(determination)
                )
            }
        }
        for (id, enacted, date, text) in lines {
            switch dedupe.observe(id: id, enacted: enacted, date: date) {
            case .new:
                emit("Determination \(text)", at: date ?? Date())
            case .enactedFlip:
                let deliverAt = date.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
                emit("Determination enacted (deliverAt \(deliverAt))", at: Date())
            case .none:
                break
            }
        }
    }

    private func emit(_ message: String, at date: Date) {
        CloudLogSink.shared.accept(LogRecord(
            timestamp: date,
            level: .info,
            category: "Algorithm",
            message: message,
            file: #fileID,
            function: #function,
            line: #line,
            launchID: LaunchID.current
        ))
    }
}
