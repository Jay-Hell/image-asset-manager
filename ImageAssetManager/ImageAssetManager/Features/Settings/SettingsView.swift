import SwiftUI
import ImageAssetManagerCore

/// Identifiable wrapper so we can use .sheet(item:) and guarantee non-nil URL in the sheet body.
private struct MigrationDestination: Identifiable {
    let id = UUID()
    let url: URL
}

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var apiKey: String = ""
    @State private var isKeyStored: Bool = false
    @State private var saveMessage: String?
    @State private var saveError: String?
    @State private var showClearConfirmation: Bool = false
    @State private var migrationDestination: MigrationDestination?

    private let service = "com.yourapp.imageassetmanager"
    private let account = "anthropic_api_key"

    var body: some View {
        Form {
            // MARK: API Key
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
                Text("Required for AI prompt refinement.")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }

            // MARK: Library Location
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(env.libraryURL.path(percentEncoded: false))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.appTextSecondary)
                        .lineLimit(3)
                        .textSelection(.enabled)

                    #if os(macOS)
                    Button("Change Location…") { openFolderPicker() }
                        .buttonStyle(.bordered)
                    #endif
                }

                Text("Move or copy the library database and all assets to a new folder. Changes take effect immediately.")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            } header: {
                Text("Library Location")
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .frame(minWidth: 380, idealWidth: 440, minHeight: 300)
        #endif
        .navigationTitle("Settings")
        .onAppear { loadKeyStatus() }
        .confirmationDialog("Remove API Key", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { clearKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Anthropic API key will be removed from Keychain.")
        }
        .sheet(item: $migrationDestination) { destination in
            LibraryMigrationSheetView(
                destinationURL: destination.url,
                onConfirm: { mode in
                    let url = destination.url
                    Task { try? await env.changeLibraryLocation(to: url, mode: mode) }
                }
            )
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

    // MARK: - Folder picker

    private func openFolderPicker() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose Library Location"
        panel.message = "Select the folder where the library database and assets will be stored."
        if panel.runModal() == .OK, let url = panel.url {
            migrationDestination = MigrationDestination(url: url)
        }
        #endif
    }
}
