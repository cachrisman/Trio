import Foundation
import UIKit

enum OpenAIVisionError: LocalizedError {
    case noAPIKey
    case invalidImage
    case invalidResponse
    case networkError(Error)
    case decodingError
    case apiError(String)
    
    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "OpenAI API key not configured. Please add your API key in Settings > Services > OpenAI."
        case .invalidImage:
            return "Unable to process the image. Please try another photo."
        case .invalidResponse:
            return "Received invalid response from OpenAI. Please try again."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError:
            return "Unable to parse nutrition data from response."
        case .apiError(let message):
            return "OpenAI API error: \(message)"
        }
    }
}

struct NutritionEstimate {
    let carbs: Float
    let fat: Float
    let protein: Float
}

class OpenAIVisionService {
    private let apiEndpoint = "https://api.openai.com/v1/chat/completions"
    private let model = "gpt-4o" // GPT-4 Omni with vision capabilities
    
    func analyzeMealPhoto(
        image: UIImage,
        apiKey: String,
        completion: @escaping (Result<NutritionEstimate, OpenAIVisionError>) -> Void
    ) {
        // Convert image to base64
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            completion(.failure(.invalidImage))
            return
        }
        
        let base64Image = imageData.base64EncodedString()
        
        // Prepare the request
        guard let url = URL(string: apiEndpoint) else {
            completion(.failure(.invalidResponse))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Construct the prompt for nutritional analysis
        let prompt = """
        Analyze this meal photo and estimate the nutritional content. 
        Provide your response ONLY as a JSON object with these exact keys: "carbs", "fat", "protein".
        All values should be in grams and be numbers (not strings).
        Be as accurate as possible based on typical portion sizes.
        
        Example response format:
        {"carbs": 45.5, "fat": 12.3, "protein": 25.0}
        
        Do not include any other text or explanation, only the JSON object.
        """
        
        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": prompt
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
            "max_tokens": 300
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            completion(.failure(.decodingError))
            return
        }
        
        // Make the API call
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(.networkError(error)))
                return
            }
            
            guard let data = data else {
                completion(.failure(.invalidResponse))
                return
            }
            
            // Parse the response
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failure(.invalidResponse))
                    return
                }
                
                // Check for API errors
                if let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    completion(.failure(.apiError(message)))
                    return
                }
                
                // Extract the nutrition data from the response
                guard let choices = json["choices"] as? [[String: Any]],
                      let firstChoice = choices.first,
                      let message = firstChoice["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    completion(.failure(.invalidResponse))
                    return
                }
                
                // Parse the JSON from the content
                let nutritionData = self.extractNutritionData(from: content)
                
                switch nutritionData {
                case .success(let estimate):
                    completion(.success(estimate))
                case .failure(let error):
                    completion(.failure(error))
                }
            } catch {
                completion(.failure(.decodingError))
            }
        }
        
        task.resume()
    }
    
    private func extractNutritionData(from content: String) -> Result<NutritionEstimate, OpenAIVisionError> {
        // Try to extract JSON from the content
        // Sometimes the model might include markdown code blocks, so we need to handle that
        var jsonString = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove markdown code blocks if present
        if jsonString.hasPrefix("```json") {
            jsonString = jsonString.replacingOccurrences(of: "```json", with: "")
            jsonString = jsonString.replacingOccurrences(of: "```", with: "")
        } else if jsonString.hasPrefix("```") {
            jsonString = jsonString.replacingOccurrences(of: "```", with: "")
        }
        
        jsonString = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Parse the JSON
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.decodingError)
        }
        
        // Extract the values
        guard let carbs = self.extractFloat(from: json["carbs"]),
              let fat = self.extractFloat(from: json["fat"]),
              let protein = self.extractFloat(from: json["protein"]) else {
            return .failure(.decodingError)
        }
        
        let estimate = NutritionEstimate(carbs: carbs, fat: fat, protein: protein)
        return .success(estimate)
    }
    
    private func extractFloat(from value: Any?) -> Float? {
        if let floatValue = value as? Float {
            return floatValue
        } else if let doubleValue = value as? Double {
            return Float(doubleValue)
        } else if let intValue = value as? Int {
            return Float(intValue)
        } else if let stringValue = value as? String,
                  let floatValue = Float(stringValue) {
            return floatValue
        }
        return nil
    }
}
