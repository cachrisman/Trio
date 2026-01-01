import Foundation
import UIKit

/// App lifecycle + periodic trigger wrapper.
///
/// - Manual trigger: `uploadNow()`
/// - Lifecycle triggers: foreground/background
/// - Periodic trigger: every 5 minutes while app is running
final class CloudLogUploadService {
    static let userDefaultsTokenKey = "cloudLogging.betterStackSourceToken"

    private let uploader: CloudLogUploader
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let tokenProvider: () -> String?
    private let ingestionURLProvider: () -> URL?

    init() {
        tokenProvider = {
            // Priority: AppGroup settings/BetterStack.json → UserDefaults (future UI) → Info.plist → Process environment (dev builds).
            if let settings = BetterStackSettingsStore.load(),
               let t = settings.BetterStackSourceToken,
               !t.isEmpty
            {
                return t
            }
            if let t = UserDefaults.standard.string(forKey: Self.userDefaultsTokenKey), !t.isEmpty { return t }
            if let t = Bundle.main.object(forInfoDictionaryKey: "BetterStackSourceToken") as? String, !t.isEmpty { return t }
            return ProcessInfo.processInfo.environment["BETTERSTACK_SOURCE_TOKEN"]
        }

        ingestionURLProvider = {
            if let settings = BetterStackSettingsStore.load(),
               let raw = settings.BetterStackIngestionUrl,
               let url = URL(string: raw)
            {
                return url
            }
            return URL(string: "https://in.logs.betterstack.com/")
        }

        let provider = BetterStackLogtailProvider(
            tokenProvider: tokenProvider,
            ingestionURLProvider: ingestionURLProvider
        )

        let pairs: [CloudLogUploader.RotatingPair] = [
            .init(
                currentPath: SimpleLogReporter.logFile,
                previousPath: SimpleLogReporter.logFilePrev,
                platform: .ios,
                parser: CloudLogLineParser.parseIOS
            ),
            .init(
                currentPath: SimpleLogReporter.watchLogFile,
                previousPath: SimpleLogReporter.watchLogFilePrev,
                platform: .watchos,
                parser: CloudLogLineParser.parseWatch
            )
        ]

        uploader = CloudLogUploader(provider: provider, pairs: pairs)

        start()
    }

    deinit {
        stop()
    }

    func uploadNow() {
        // Only run when configured (no privacy gating in this repo).
        guard let token = tokenProvider(), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        guard ingestionURLProvider() != nil else {
            return
        }

        Task {
            _ = await uploader.uploadNow()
        }
    }

    // MARK: - Scheduling

    private func start() {
        // Foreground + background triggers
        let center = NotificationCenter.default

        observers.append(
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.uploadNow()
            }
        )

        observers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.uploadNow()
            }
        )

        // Periodic trigger (while running)
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            self?.uploadNow()
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil

        let center = NotificationCenter.default
        for o in observers {
            center.removeObserver(o)
        }
        observers.removeAll()
    }
}

