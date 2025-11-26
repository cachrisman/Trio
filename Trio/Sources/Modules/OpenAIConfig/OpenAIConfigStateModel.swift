import Foundation
import SwiftUI

extension OpenAIConfig {
    final class StateModel: BaseStateModel<OpenAIConfig.Provider> {
        @Injected() var keychain: Keychain!
        @Published var apiKey: String = ""
        @Published var maskedApiKey: String = ""
        @Published var isKeyPresent: Bool = false
        @Published var hasUnsavedChanges: Bool = false
        @Published var showSuccessMessage: Bool = false
        @Published var showErrorMessage: Bool = false
        @Published var errorMessage: String = ""

        override func subscribe() {
            loadApiKey()
        }

        func loadApiKey() {
            switch keychain.getValue(String.self, forKey: OpenAIConfig.Config.apiKeyKey) {
            case .success(let key):
                if let key = key {
                    apiKey = key
                    maskedApiKey = String(repeating: "•", count: min(key.count, 20))
                    isKeyPresent = true
                } else {
                    apiKey = ""
                    maskedApiKey = ""
                    isKeyPresent = false
                }
            case .failure:
                apiKey = ""
                maskedApiKey = ""
                isKeyPresent = false
            }
            hasUnsavedChanges = false
        }

        func updateApiKey(_ newKey: String) {
            apiKey = newKey
            hasUnsavedChanges = newKey != (keychain.getValue(String.self, forKey: OpenAIConfig.Config.apiKeyKey).value ?? "")
        }

        func saveApiKey() {
            let result = keychain.setValue(apiKey.isEmpty ? nil : apiKey, forKey: OpenAIConfig.Config.apiKeyKey)
            
            switch result {
            case .success:
                loadApiKey()
                showSuccessMessage = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.showSuccessMessage = false
                }
            case .failure(let error):
                errorMessage = "Failed to save API key: \(error.localizedDescription)"
                showErrorMessage = true
            }
        }

        func deleteApiKey() {
            let result = keychain.removeObject(forKey: OpenAIConfig.Config.apiKeyKey)
            
            switch result {
            case .success:
                apiKey = ""
                maskedApiKey = ""
                isKeyPresent = false
                hasUnsavedChanges = false
                showSuccessMessage = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.showSuccessMessage = false
                }
            case .failure(let error):
                errorMessage = "Failed to delete API key: \(error.localizedDescription)"
                showErrorMessage = true
            }
        }

        func replaceApiKey() {
            apiKey = ""
            maskedApiKey = ""
            isKeyPresent = false
            hasUnsavedChanges = true
        }
    }
}