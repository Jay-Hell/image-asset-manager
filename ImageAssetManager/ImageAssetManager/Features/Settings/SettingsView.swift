import SwiftUI
import ImageAssetManagerCore

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var isKeyStored: Bool = false
    @State private var saveMessage: String?
    @State private var saveError: String?
    @State private var showClearConfirmation: Bool = false

    private let service = "com.yourapp.imageassetmanager"
    private let account = "anthropic_api_key"

    var body: some View {
        Form {
            Section {
                SecureField("Paste API key…", text: $apiKey)
                    .textContentType(.password)

                HStack(spacing: 10) {
                    Button("Save") { saveKey() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.appAccent)
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)

                    if isKeyStored {
                        Button("Clear", role: .destructive) { showClearConfirmation = true }
                            .buttonStyle(.bordered)
                    }
                }

                if let msg = saveMessage {
                    Label(msg, systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(Color.appAccent)
                }
                if let err = saveError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                if isKeyStored && apiKey.isEmpty {
                    Text("An API key is stored in Keychain.")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }

                Text("Get your key at console.anthropic.com. Stored in macOS Keychain only — never uploaded to iCloud.")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            } header: {
                Text("Anthropic API Key")
            } footer: {
                Text("Required for AI prompt refinement (Phase 10 feature).")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .frame(minWidth: 380, idealWidth: 420, minHeight: 220)
        #endif
        .navigationTitle("Settings")
        .onAppear { loadKeyStatus() }
        .confirmationDialog("Remove API Key", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { clearKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Anthropic API key will be removed from Keychain.")
        }
    }

    private func loadKeyStatus() {
        isKeyStored = (try? KeychainService.retrieve(service: service, account: account)) != nil
    }

    private func saveKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainService.store(trimmed, service: service, account: account)
            isKeyStored = true
            apiKey = ""
            saveError = nil
            saveMessage = "API key saved."
        } catch {
            saveMessage = nil
            saveError = error.localizedDescription
        }
    }

    private func clearKey() {
        try? KeychainService.delete(service: service, account: account)
        isKeyStored = false
        apiKey = ""
        saveMessage = nil
    }
}
