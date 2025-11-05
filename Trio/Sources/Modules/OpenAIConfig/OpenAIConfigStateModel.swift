import Combine
import SwiftUI

extension OpenAIConfig {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var keychain: Keychain!
        
        @Published var apiKey = ""
        @Published var message = ""
        @Published var showSaveButton = false
        @Published var keyIsMasked = true
        
        private var originalKey = ""
        
        override func subscribe() {
            // Load API key from keychain on initialization
            if let storedKey = keychain.getValue(String.self, forKey: Config.apiKeyKey),
               case .success(let key) = storedKey {
                originalKey = key
                apiKey = String(repeating: "•", count: min(key.count, 20))
            } else {
                originalKey = ""
                apiKey = ""
                keyIsMasked = false
            }
            
            // Monitor changes to show/hide save button
            $apiKey
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] newValue in
                    guard let self = self else { return }
                    if self.keyIsMasked {
                        // If masked and user starts typing, unmask
                        self.showSaveButton = false
                    } else {
                        // Show save button only if key has changed
                        self.showSaveButton = newValue != self.originalKey && !newValue.isEmpty
                    }
                }
                .store(in: &lifetime)
        }
        
        func hasAPIKey() -> Bool {
            return !originalKey.isEmpty
        }
        
        func revealKey() {
            if !originalKey.isEmpty {
                apiKey = originalKey
                keyIsMasked = false
                showSaveButton = false
            }
        }
        
        func save() {
            guard !apiKey.isEmpty else {
                message = "API key cannot be empty"
                return
            }
            
            let result = keychain.setValue(apiKey, forKey: Config.apiKeyKey)
            switch result {
            case .success:
                message = "API key saved successfully"
                originalKey = apiKey
                showSaveButton = false
                // Mask the key after saving
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self = self else { return }
                    self.apiKey = String(repeating: "•", count: min(self.originalKey.count, 20))
                    self.keyIsMasked = true
                    self.message = ""
                }
            case .failure(let error):
                message = "Failed to save: \(error.localizedDescription)"
            }
        }
        
        func delete() {
            let result = keychain.removeObject(forKey: Config.apiKeyKey)
            switch result {
            case .success:
                message = "API key deleted successfully"
                originalKey = ""
                apiKey = ""
                keyIsMasked = false
                showSaveButton = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.message = ""
                }
            case .failure(let error):
                message = "Failed to delete: \(error.localizedDescription)"
            }
        }
    }
}
