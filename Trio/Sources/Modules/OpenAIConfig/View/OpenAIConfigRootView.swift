import SwiftUI

extension OpenAIConfig {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()
        @State private var showingDeleteAlert = false

        var body: some View {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("OpenAI API Key")
                            .font(.headline)
                        
                        if state.isKeyPresent && !state.hasUnsavedChanges {
                            HStack {
                                Text(state.maskedApiKey)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Replace") {
                                    state.replaceApiKey()
                                }
                                .foregroundColor(.orange)
                            }
                        } else {
                            SecureField("Enter your OpenAI API key", text: $state.apiKey)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .onChange(of: state.apiKey) { _ in
                                    state.updateApiKey(state.apiKey)
                                }
                        }
                        
                        if state.hasUnsavedChanges {
                            HStack {
                                Button("Save") {
                                    state.saveApiKey()
                                }
                                .foregroundColor(.blue)
                                .disabled(state.apiKey.isEmpty)
                                
                                Spacer()
                                
                                Button("Cancel") {
                                    state.loadApiKey()
                                }
                                .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Configuration")
                } footer: {
                    Text("Your API key is stored securely in the device keychain and is never shared.")
                }
                
                if state.isKeyPresent {
                    Section {
                        Button("Delete API Key") {
                            showingDeleteAlert = true
                        }
                        .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("OpenAI Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: configureView)
            .alert("Delete API Key", isPresented: $showingDeleteAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    state.deleteApiKey()
                }
            } message: {
                Text("Are you sure you want to delete the stored API key? This will disable the meal photo analysis feature.")
            }
            .alert("Success", isPresented: $state.showSuccessMessage) {
                Button("OK") { }
            } message: {
                Text("API key saved successfully")
            }
            .alert("Error", isPresented: $state.showErrorMessage) {
                Button("OK") { }
            } message: {
                Text(state.errorMessage)
            }
        }
    }
}