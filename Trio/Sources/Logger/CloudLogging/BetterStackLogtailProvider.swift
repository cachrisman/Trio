import Foundation

/// Better Stack / Logtail provider.
///
/// Endpoint: POST https://in.logs.betterstack.com/
/// Success: HTTP 202 only
final class BetterStackLogtailProvider: CloudLogProvider {
    private let tokenProvider: () -> String?
    private let session: URLSession

    init(
        tokenProvider: @escaping () -> String?,
        session: URLSession = .shared
    ) {
        self.tokenProvider = tokenProvider
        self.session = session
    }

    func upload(events: [CloudLogEvent]) async -> Result<Void, CloudLogUploadError> {
        guard !events.isEmpty else { return .success(()) }

        guard let token = tokenProvider(), !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.notConfigured)
        }

        guard let url = URL(string: "https://in.logs.betterstack.com/") else {
            return .failure(.invalidURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(events)
        } catch {
            return .failure(.encoding(error))
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }

            // Critical: treat HTTP 202 only as success.
            guard http.statusCode == 202 else {
                let preview = String(data: data.prefix(512), encoding: .utf8)
                return .failure(.unexpectedStatus(code: http.statusCode, bodyPreview: preview))
            }

            return .success(())
        } catch {
            return .failure(.transport(error))
        }
    }
}

