import Foundation
import UIKit

struct NutritionEstimate: Codable {
    let carbs: Float
    let fat: Float
    let protein: Float
}

enum OpenAIVisionError: Error, LocalizedError {
    case invalidApiKey
    case networkError(Error)
    case invalidResponse
    case parsingError(Error)
    case imageProcessingError
    
    var errorDescription: String? {
        switch self {
        case .invalidApiKey:
            return "Invalid API key. Please check your OpenAI configuration."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from OpenAI API"
        case .parsingError(let error):
            return "Failed to parse response: \(error.localizedDescription)"
        case .imageProcessingError:
            return "Failed to process image"
        }
    }
}

protocol OpenAIVisionServiceProtocol {
    func analyzeMealPhoto(_ image: UIImage, apiKey: String, completion: @escaping (Result<NutritionEstimate, OpenAIVisionError>) -> Void)
}

class OpenAIVisionService: OpenAIVisionServiceProtocol {
    private let baseURL = "https://api.openai.com/v1/chat/completions"
    
    func analyzeMealPhoto(_ image: UIImage, apiKey: String, completion: @escaping (Result<NutritionEstimate, OpenAIVisionError>) -> Void) {
        guard !apiKey.isEmpty else {
            completion(.failure(.invalidApiKey))
            return
        }
        
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            completion(.failure(.imageProcessingError))
            return
        }
        
        let base64Image = imageData.base64EncodedString()
        
        let requestBody: [String: Any] = [
            "model": "gpt-4-vision-preview",
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": "Analyze this meal photo and estimate the nutritional content. Return ONLY a JSON object with the following format: {\"carbs\": number, \"fat\": number, \"protein\": number}. The numbers should be in grams. Be conservative in your estimates and focus on visible food items only."
                        ],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/jpeg;base64,\(base64Image)"
                            ]
                        ]
                    ]
                ]
            ],
            "max_tokens": 150,
            "temperature": 0.1
        ]
        
        guard let url = URL(string: baseURL) else {
            completion(.failure(.invalidResponse))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            completion(.failure(.parsingError(error)))
            return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(.networkError(error)))
                }
                return
            }
            
            guard let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(.invalidResponse))
                }
                return
            }
            
            do {
                let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
                
                guard let content = response.choices.first?.message.content else {
                    DispatchQueue.main.async {
                        completion(.failure(.invalidResponse))
                    }
                    return
                }
                
                // Extract JSON from the response content
                let jsonString = extractJSON(from: content)
                guard let jsonData = jsonString.data(using: .utf8) else {
                    DispatchQueue.main.async {
                        completion(.failure(.parsingError(NSError(domain: "JSONParsing", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to convert response to data"]))))
                    }
                    return
                }
                
                let nutritionEstimate = try JSONDecoder().decode(NutritionEstimate.self, from: jsonData)
                
                DispatchQueue.main.async {
                    completion(.success(nutritionEstimate))
                }
                
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(.parsingError(error)))
                }
            }
        }.resume()
    }
    
    private func extractJSON(from content: String) -> String {
        // Look for JSON object in the response
        if let range = content.range(of: "\\{[^}]*\"carbs\"[^}]*\\}", options: .regularExpression) {
            return String(content[range])
        }
        
        // Fallback: try to find any JSON-like structure
        if let startIndex = content.firstIndex(of: "{"),
           let endIndex = content.lastIndex(of: "}") {
            return String(content[startIndex...endIndex])
        }
        
        return content
    }
}

// MARK: - Response Models

private struct OpenAIResponse: Codable {
    let choices: [Choice]
}

private struct Choice: Codable {
    let message: Message
}

private struct Message: Codable {
    let content: String
}