import Foundation

/// Manages log folder cleanup based on app version changes.
/// Creates version-specific folders (e.g., `logs/0.6.0.4-55/`) and cleans up old version folders
/// to prevent accumulation. Keeps the last 3 versions and 2 days of logs within each version folder.
final class LogVersionManager {
    static let shared = LogVersionManager()

    private let fileManager = FileManager.default
    private let userDefaults = UserDefaults.standard

    // Keys for UserDefaults
    private enum Keys {
        static let lastKnownVersion = "LogVersionManager.lastKnownVersion"
        static let lastKnownBuildNumber = "LogVersionManager.lastKnownBuildNumber"
    }

    private init() {}

    /// Checks if the app version has changed and cleans up old version folders if necessary.
    /// This should be called early in the app lifecycle, ideally in AppDelegate.
    func checkAndRotateLogsIfNeeded() {
        let currentVersion = Bundle.main.appDevVersion ?? Bundle.main.releaseVersionNumber ?? "unknown"
        let currentBuildNumber = Bundle.main.buildVersionNumber ?? "unknown"

        let lastKnownVersion = userDefaults.string(forKey: Keys.lastKnownVersion)
        let lastKnownBuildNumber = userDefaults.string(forKey: Keys.lastKnownBuildNumber)

        // Check if this is a version change
        let versionChanged = lastKnownVersion != currentVersion || lastKnownBuildNumber != currentBuildNumber

        if versionChanged {
            debug(
                .default,
                "🔄 App version changed from \(lastKnownVersion ?? "nil")(\(lastKnownBuildNumber ?? "nil")) " +
                    "to \(currentVersion)(\(currentBuildNumber))"
            )

            // Clean up old version folders
            cleanupOldVersionFolders()

            // Update stored version info
            userDefaults.set(currentVersion, forKey: Keys.lastKnownVersion)
            userDefaults.set(currentBuildNumber, forKey: Keys.lastKnownBuildNumber)
        } else {
            debug(.default, "📝 App version unchanged: \(currentVersion)(\(currentBuildNumber))")
        }

        // Check if we should perform periodic cleanup
        checkAndPerformPeriodicCleanup()
    }

    /// Checks if periodic cleanup should be performed and executes it if needed.
    /// Cleanup is performed once per week to avoid accumulating too many rotated logs.
    private func checkAndPerformPeriodicCleanup() {
        let lastCleanup = PropertyPersistentFlags.shared.lastLogCleanupDate
        let now = Date()

        // Perform cleanup if it's been more than 7 days since last cleanup
        let cleanupInterval: TimeInterval = 7 * 24 * 60 * 60 // 7 days
        let shouldCleanup = lastCleanup == nil || now.timeIntervalSince(lastCleanup!) > cleanupInterval

        if shouldCleanup {
            debug(.default, "🧹 Performing periodic log cleanup")
            cleanupOldVersionFolders(keepCount: 3)
            PropertyPersistentFlags.shared.lastLogCleanupDate = now
        }
    }

    /// Cleans up old version folders, keeping only recent versions.
    private func cleanupOldVersionFolders() {
        let logsDirectory = SimpleLogReporter.getDocumentsDirectory().appendingPathComponent("logs")

        guard fileManager.fileExists(atPath: logsDirectory.path) else {
            debug(.default, "📁 No logs directory found")
            return
        }

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: logsDirectory.path)
            let versionFolders = contents.filter { $0.contains("-") && !$0.hasPrefix(".") }

            // Sort version folders by creation date (oldest first)
            let sortedFolders = versionFolders.compactMap { folderName -> (String, Date)? in
                let folderPath = logsDirectory.appendingPathComponent(folderName).path
                guard let attributes = try? fileManager.attributesOfItem(atPath: folderPath),
                      let creationDate = attributes[.creationDate] as? Date
                else {
                    return nil
                }
                return (folderPath, creationDate)
            }.sorted { $0.1 < $1.1 }

            // Keep only the 3 most recent versions
            let foldersToKeep = sortedFolders.suffix(3)
            let foldersToRemove = sortedFolders.dropLast(3)

            for (folderPath, _) in foldersToRemove {
                do {
                    try fileManager.removeItem(atPath: folderPath)
                    debug(.default, "🗑️ Removed old version folder: \(folderPath)")
                } catch {
                    debug(.default, "❌ Failed to remove old version folder \(folderPath): \(error)")
                }
            }

            debug(.default, "🧹 Cleaned up old version folders, keeping \(foldersToKeep.count) recent versions")

        } catch {
            debug(.default, "❌ Failed to list version folders: \(error)")
        }
    }

    /// Gets a list of all version folders for debugging purposes.
    func getVersionFolders() -> [String] {
        let logsDirectory = SimpleLogReporter.getDocumentsDirectory().appendingPathComponent("logs")

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: logsDirectory.path)
            return contents.filter { $0.contains("-") && !$0.hasPrefix(".") }
        } catch {
            debug(.default, "❌ Failed to list version folders: \(error)")
            return []
        }
    }

    /// Cleans up old version folders, keeping only the most recent ones.
    /// - Parameter keepCount: Number of versions to keep (default: 3)
    func cleanupOldVersionFolders(keepCount: Int = 3) {
        let logsDirectory = SimpleLogReporter.getDocumentsDirectory().appendingPathComponent("logs")

        guard fileManager.fileExists(atPath: logsDirectory.path) else {
            debug(.default, "📁 No logs directory found")
            return
        }

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: logsDirectory.path)
            let versionFolders = contents.filter { $0.contains("-") && !$0.hasPrefix(".") }

            // Sort version folders by creation date (oldest first)
            let sortedFolders = versionFolders.compactMap { folderName -> (String, Date)? in
                let folderPath = logsDirectory.appendingPathComponent(folderName).path
                guard let attributes = try? fileManager.attributesOfItem(atPath: folderPath),
                      let creationDate = attributes[.creationDate] as? Date
                else {
                    return nil
                }
                return (folderPath, creationDate)
            }.sorted { $0.1 < $1.1 }

            guard sortedFolders.count > keepCount else {
                debug(.default, "🧹 No cleanup needed: \(sortedFolders.count) versions (keeping \(keepCount))")
                return
            }

            // Remove oldest versions beyond keepCount
            let foldersToRemove = sortedFolders.prefix(sortedFolders.count - keepCount)

            for (folderPath, _) in foldersToRemove {
                do {
                    try fileManager.removeItem(atPath: folderPath)
                    debug(.default, "🗑️ Cleaned up old version folder: \(folderPath)")
                } catch {
                    debug(.default, "❌ Failed to remove old version folder \(folderPath): \(error)")
                }
            }

            debug(.default, "🧹 Cleanup completed: removed \(foldersToRemove.count) old versions")

        } catch {
            debug(.default, "❌ Failed to cleanup old version folders: \(error)")
        }
    }
}
