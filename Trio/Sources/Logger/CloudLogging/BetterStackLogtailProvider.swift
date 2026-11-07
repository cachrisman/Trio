import Foundation
import os

/// Better Stack / Logtail provider.
///
/// Endpoint: POST <ingestion URL>
/// Success: HTTP 202 only
final class BetterStackLogtailProvider: CloudLogProvider {
    private let tokenProvider: () -> String?
    private let ingestionURLProvider: () -> URL?
    private let session: URLSession

    // Cloud logging must not use TrioLogger, otherwise upload failures would feed rows back into the queue.
    private let osLog = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.nightscout.Trio",
        category: "CloudLogging"
    )

    init(
        tokenProvider: @escaping () -> String?,
        ingestionURLProvider: @escaping () -> URL? = { URL(string: "https://in.logs.betterstack.com/") },
        session: URLSession = .shared
    ) {
        self.tokenProvider = tokenProvider
        self.ingestionURLProvider = ingestionURLProvider
        self.session = session
    }

    func encodedSize(of events: [CloudLogEvent]) -> Int? {
        try? JSONEncoder().encode(events).count
    }

    func upload(events: [CloudLogEvent]) async -> Result<Void, CloudLogUploadError> {
        guard !events.isEmpty else { return .success(()) }

        guard let token = tokenProvider(), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            osLog.debug("Cloud logging: not configured (no token)")
            return .failure(.notConfigured)
        }

        // The bearer token must never be sent in cleartext.
        guard let url = ingestionURLProvider(), url.scheme?.lowercased() == "https" else {
            osLog.debug("Cloud logging: invalid URL")
            return .failure(.invalidURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(events)
        } catch {
            osLog.error("Cloud logging: encoding failed: \(String(describing: error), privacy: .public)")
            return .failure(.encoding(error))
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }

            // Better Stack ingestion success is HTTP 202.
            guard http.statusCode == 202 else {
                let preview = String(data: data.prefix(4096), encoding: .utf8)

                osLog.error(
                    "Cloud logging upload failed: status=\(http.statusCode) events=\(events.count) bodyPreview=\(preview ?? "<non-utf8>", privacy: .public)"
                )

                return .failure(.unexpectedStatus(code: http.statusCode, bodyPreview: preview))
            }

            return .success(())
        } catch {
            osLog.error("Cloud logging: transport error: \(String(describing: error), privacy: .public)")
            return .failure(.transport(error))
        }
    }
}
