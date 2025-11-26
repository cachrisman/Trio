enum OpenAIConfig {
    enum Config {
        static let apiKeyKey = "openai_api_key"
    }
}

protocol OpenAIConfigProvider: Provider {}