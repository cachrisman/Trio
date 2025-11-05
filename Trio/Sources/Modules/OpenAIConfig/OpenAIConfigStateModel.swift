import Combine
import SwiftUI

extension OpenAIConfig {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var keychain: Keychain!
        @Injected() private var settings: SettingsManager!

        @Published var apiKey: String = ""
        @Published var originalApiKey: String = ""
        @Published var message: String = ""
        @Published var isSaving: Bool = false
        @Published var isDeleting: Bool = false

        override func subscribe() {
            apiKey = keychain.getValue(String.self, forKey: Config.apiKeyKey) ?? ""
            originalApiKey = apiKey
        }

        var hasExistingKey: Bool { !originalApiKey.isEmpty }
        var hasChanges: Bool { apiKey != originalApiKey }

        func save() {
            guard hasChanges else { return }
            isSaving = true
            message = ""
            keychain.setValue(apiKey.isEmpty ? nil : apiKey, forKey: Config.apiKeyKey)
            originalApiKey = apiKey
            isSaving = false
            message = String(localized: "Saved")
        }

        func deleteKey() {
            isDeleting = true
            keychain.removeObject(forKey: Config.apiKeyKey)
            apiKey = ""
            originalApiKey = ""
            isDeleting = false
            message = String(localized: "Deleted")
        }
    }
}
