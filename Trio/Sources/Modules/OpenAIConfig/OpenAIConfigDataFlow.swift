import Combine
import Foundation

enum OpenAIConfig {
    enum Config {
        static let apiKeyKey = "OpenAIConfig.apiKey"
    }
}

protocol OpenAIConfigProvider: Provider {}
