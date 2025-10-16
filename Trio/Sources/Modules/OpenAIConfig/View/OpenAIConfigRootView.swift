import SwiftUI
import Swinject

extension OpenAIConfig {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()
        @State private var isReplacing = false

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            Form {
                Section(header: Text("OpenAI")) {
                    HStack {
                        Text("API Key")
                        Spacer()
                        if state.hasExistingKey && !isReplacing {
                            SecureField("", text: $state.apiKey)
                                .disabled(true)
                                .textContentType(.password)
                                .privacySensitive()
                        } else {
                            SecureField("Enter API Key", text: $state.apiKey)
                                .textContentType(.password)
                                .privacySensitive()
                                .autocorrectionDisabled(true)
                                .textInputAutocapitalization(.never)
                        }
                    }
                    HStack {
                        if state.hasExistingKey && !isReplacing {
                            Button {
                                isReplacing = true
                                state.apiKey = ""
                            } label: {
                                Text("Replace")
                            }
                        }
                        if state.hasExistingKey {
                            Button(role: .destructive) {
                                state.deleteKey()
                                isReplacing = false
                            } label: {
                                Text(state.isDeleting ? "Deleting…" : "Delete")
                            }
                        }
                        Spacer()
                        if state.hasChanges {
                            Button {
                                state.save()
                                isReplacing = false
                            } label: {
                                Text(state.isSaving ? "Saving…" : "Save")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    if !state.message.isEmpty {
                        Text(state.message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("OpenAI")
            .navigationBarTitleDisplayMode(.automatic)
            .onAppear(perform: configureView)
        }
    }
}
