import SwiftUI
import ImageAssetManagerCore

/// A reusable `Section` that stores a single API key in the macOS/iOS Keychain.
/// The key itself is never persisted outside the Keychain — not in UserDefaults,
/// not in files, not in state beyond the transient paste field.
struct KeychainKeyEditor: View {
    let title: String
    let service: String
    let account: String
    let helperText: String
    let footerText: String
    let removalMessage: String

    @State private var apiKey: String = ""
    @State private var isKeyStored: Bool = false
    @State private var saveMessage: String?
    @State private var saveError: String?
    @State private var showClearConfirmation: Bool = false

    var body: some View {
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

            Text(helperText)
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
        } header: {
            Text(title)
        } footer: {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
        }
        .onAppear { loadKeyStatus() }
        .confirmationDialog("Remove API Key", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { clearKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalMessage)
        }
    }

    // MARK: - Keychain

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
