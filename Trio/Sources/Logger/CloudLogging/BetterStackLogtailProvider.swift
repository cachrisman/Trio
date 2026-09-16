import Foundation

/// Better Stack / Logtail provider.
///
/// Endpoint: POST <ingestion URL>
/// Success: HTTP 202 only
final class BetterStackLogtailProvider: CloudLogProvider {
    private let tokenProvider: () -> String?
    private let ingestionURLProvider: () -> URL?
    private let session: URLSession

    init(
        tokenProvider: @escaping () -> String?,
        ingestionURLProvider: @escaping () -> URL? = { URL(string: "https://in.logs.betterstack.com/") },
        session: URLSession = .shared
    ) {
        self.tokenProvider = tokenProvider
        self.ingestionURLProvider = ingestionURLProvider
        self.session = session
    }

    func upload(events: [CloudLogEvent]) async -> Result<Void, CloudLogUploadError> {
        guard !events.isEmpty else { return .success(()) }

        guard let token = tokenProvider(), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            debug(.service, "Cloud logging: not configured (no token)")
            return .failure(.notConfigured)
        }

        guard let url = ingestionURLProvider() else {
            debug(.service, "Cloud logging: invalid URL")
            return .failure(.invalidURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(events)
        } catch {
            debug(.service, "Cloud logging: encoding failed: \(error)")
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

                debug(
                    .service,
                    "Cloud logging upload failed: status=\(http.statusCode) events=\(events.count) bodyPreview=\(preview ?? "<non-utf8>")"
                )

                return .failure(.unexpectedStatus(code: http.statusCode, bodyPreview: preview))
            }

            return .success(())
        } catch {
            debug(.service, "Cloud logging: transport error: \(error)")
            return .failure(.transport(error))
        }
    }
}
