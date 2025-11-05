import Foundation
import UIKit

struct VisionNutrition: Codable {
    let carbs: Float
    let fat: Float
    let protein: Float
}

protocol VisionNutritionAnalyzing {
    func analyzeMeal(image: UIImage, apiKey: String) async throws -> VisionNutrition
}

final class OpenAIVisionService: VisionNutritionAnalyzing {
    enum ServiceError: Error {
        case invalidImageData
        case badResponse
        case decodeFailed
        case httpError(Int)
        case missingChoices
    }

    private let session: URLSession
    private let endpoint: URL

    init(session: URLSession = .shared, endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!) {
        self.session = session
        self.endpoint = endpoint
    }

    func analyzeMeal(image: UIImage, apiKey: String) async throws -> VisionNutrition {
        guard let imageData = image.jpegData(compressionQuality: 0.85) else {
            throw ServiceError.invalidImageData
        }
        let base64 = imageData.base64EncodedString()

        let prompt = "You are a nutritionist. Estimate macronutrients for the meal in the image. Respond ONLY as strict JSON: {\"carbs\": Float, \"fat\": Float, \"protein\": Float}. Use grams."

        let payload: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/jpeg;base64,\(base64)"
                            ]
                        ]
                    ]
                ]
            ],
            "temperature": 0.2,
            "response_format": ["type": "json_object"]
        ]

        let request = try makeRequest(apiKey: apiKey, jsonBody: payload)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw ServiceError.httpError(http.statusCode) }

        struct ChoiceMessage: Decodable { let content: String }
        struct Choice: Decodable { let message: ChoiceMessage }
        struct CompletionResponse: Decodable { let choices: [Choice] }

        let completion = try JSONDecoder().decode(CompletionResponse.self, from: data)
        guard let content = completion.choices.first?.message.content.data(using: .utf8) else {
            throw ServiceError.missingChoices
        }
        let nutrition = try JSONDecoder().decode(VisionNutrition.self, from: content)
        return nutrition
    }

    private func makeRequest(apiKey: String, jsonBody: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        return request
    }
}
