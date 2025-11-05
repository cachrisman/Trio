import SwiftUI
import Swinject

extension OpenAIConfig {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()
        
        @State private var showDeleteAlert = false
        
        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState
        
        var body: some View {
            Form {
                Section(
                    header: Text("OpenAI API Configuration"),
                    footer: Text("Your API key is stored securely in the device Keychain and is only used for meal photo analysis.")
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("API Key")
                                .foregroundColor(.secondary)
                            Spacer()
                            if state.hasAPIKey() && state.keyIsMasked {
                                Button("Reveal") {
                                    state.revealKey()
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .font(.footnote)
                            }
                        }
                        
                        TextField("Enter your OpenAI API key", text: $state.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .onChange(of: state.apiKey) { _, newValue in
                                if state.keyIsMasked && !newValue.contains("•") {
                                    state.keyIsMasked = false
                                }
                            }
                        
                        if !state.message.isEmpty {
                            Text(state.message)
                                .font(.footnote)
                                .foregroundColor(state.message.contains("success") ? .green : .red)
                        }
                    }
                    .padding(.vertical, 4)
                    
                    if state.showSaveButton {
                        Button {
                            state.save()
                        } label: {
                            HStack {
                                Spacer()
                                Text("Save")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    
                    if state.hasAPIKey() {
                        HStack {
                            Button("Replace") {
                                state.apiKey = ""
                                state.keyIsMasked = false
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(.orange)
                            
                            Spacer()
                            
                            Button("Delete") {
                                showDeleteAlert = true
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(.red)
                        }
                    }
                }
                .listRowBackground(Color.chart)
                
                Section(
                    header: Text("How to Get an API Key"),
                    content: {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("1. Visit OpenAI's website")
                            Text("2. Sign up or log in to your account")
                            Text("3. Navigate to API settings")
                            Text("4. Generate a new API key")
                            Text("5. Copy and paste it above")
                            
                            Button {
                                if let url = URL(string: "https://platform.openai.com/api-keys") {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                HStack {
                                    Text("Open OpenAI API Keys")
                                        .foregroundColor(.blue)
                                    Spacer()
                                    Image(systemName: "arrow.up.right.square")
                                        .foregroundColor(.blue)
                                        .font(.footnote)
                                }
                            }
                        }
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    }
                )
                .listRowBackground(Color.chart)
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("OpenAI Configuration")
            .navigationBarTitleDisplayMode(.automatic)
            .onAppear(perform: configureView)
            .alert("Delete API Key", isPresented: $showDeleteAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    state.delete()
                }
            } message: {
                Text("Are you sure you want to delete your stored API key? You will need to enter it again to use meal photo analysis.")
            }
        }
    }
}
