import SwiftUI

struct CloudLoggingSettingsView: View {
    @State private var enabled: Bool = false
    @State private var token: String = ""
    @State private var ingestionURL: String = ""

    @State private var showResult = false
    @State private var resultTitle = ""
    @State private var resultMessage = ""

    private var effectiveToken: String? {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private var effectiveURL: URL? {
        let raw = ingestionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return URL(string: "https://in.logs.betterstack.com/")
        }
        return URL(string: raw)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Cloud Logging", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: CloudLogUploadService.userDefaultsEnabledKey)
                    }
            }

            Section("Better Stack") {
                SecureField("Source token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .disabled(!enabled)
                    .onChange(of: token) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            UserDefaults.standard.removeObject(forKey: CloudLogUploadService.userDefaultsTokenKey)
                        } else {
                            UserDefaults.standard.set(trimmed, forKey: CloudLogUploadService.userDefaultsTokenKey)
                        }
                    }

                TextField("Ingestion URL", text: $ingestionURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .disabled(!enabled)
                    .onChange(of: ingestionURL) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            UserDefaults.standard.removeObject(forKey: CloudLogUploadService.userDefaultsIngestionURLKey)
                        } else {
                            UserDefaults.standard.set(trimmed, forKey: CloudLogUploadService.userDefaultsIngestionURLKey)
                        }
                    }

                Button("Test Connection") {
                    Task { await testConnection() }
                }
                .disabled(!enabled || effectiveToken == nil || effectiveURL == nil)

                Button(role: .destructive) {
                    token = ""
                    ingestionURL = ""
                    UserDefaults.standard.removeObject(forKey: CloudLogUploadService.userDefaultsTokenKey)
                    UserDefaults.standard.removeObject(forKey: CloudLogUploadService.userDefaultsIngestionURLKey)
                } label: {
                    Text("Remove Token & URL")
                }
                .disabled(!enabled)
            }

            Section {
                Text("These settings override on-device settings files (e.g. settings/BetterStack.json) when enabled.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Cloud Logging")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadFromDefaults)
        .alert(resultTitle, isPresented: $showResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resultMessage)
        }
    }

    private func loadFromDefaults() {
        let ud = UserDefaults.standard

        // Respect explicit enabled flag if present; otherwise default to false.
        if let enabledObj = ud.object(forKey: CloudLogUploadService.userDefaultsEnabledKey) as? Bool {
            enabled = enabledObj
        } else {
            enabled = false
        }

        token = ud.string(forKey: CloudLogUploadService.userDefaultsTokenKey) ?? ""
        ingestionURL = ud.string(forKey: CloudLogUploadService.userDefaultsIngestionURLKey) ?? ""
    }

    private func testConnection() async {
        guard let token = effectiveToken else {
            presentResult(title: "Missing token", message: "Enter a Better Stack source token first.")
            return
        }
        guard let url = effectiveURL else {
            presentResult(title: "Invalid URL", message: "Enter a valid ingestion URL.")
            return
        }

        let provider = BetterStackLogtailProvider(
            tokenProvider: { token },
            ingestionURLProvider: { url }
        )

        let events = [
            CloudLogEvent(
                message: "Trio cloud logging test event",
                dt: nil,
                attributes: [
                    "platform": "ios",
                    "category": "CloudLogging",
                    "level": "info"
                ],
                raw: "Trio cloud logging test event"
            )
        ]

        switch await provider.upload(events: events) {
        case .success:
            presentResult(title: "Success", message: "Test event ingested successfully.")
        case let .failure(error):
            presentResult(title: "Failed", message: error.description)
        }
    }

    @MainActor
    private func presentResult(title: String, message: String) {
        resultTitle = title
        resultMessage = message
        showResult = true
    }
}
