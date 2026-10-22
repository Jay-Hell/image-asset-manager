import SwiftUI
import ImageAssetManagerCore

/// Identifiable wrapper so we can use .sheet(item:) and guarantee non-nil URL in the sheet body.
private struct MigrationDestination: Identifiable {
    let id = UUID()
    let url: URL
}

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var migrationDestination: MigrationDestination?
    @State private var migrationError: String?
    @State private var isMigrating: Bool = false
    @State private var showClearLibraryConfirmation: Bool = false
    @State private var isClearing: Bool = false
    @State private var clearError: String?

    var body: some View {
        Form {
            // MARK: Image Generation API Key (Nano Banana / Google AI Studio)
            KeychainKeyEditor(
                title: "Nano Banana API Key",
                service: NanaBananaProvider.keychainService,
                account: NanaBananaProvider.keychainAccount,
                helperText: "Get your key at aistudio.google.com. Works for all four image models (Fast, Standard, Pro, With References). Stored in macOS Keychain only — never uploaded to iCloud.",
                footerText: "Required for image generation.",
                removalMessage: "The Nano Banana API key will be removed from Keychain."
            )

            // MARK: Anthropic API Key (prompt refinement)
            KeychainKeyEditor(
                title: "Anthropic API Key",
                service: "com.yourapp.imageassetmanager",
                account: "anthropic_api_key",
                helperText: "Get your key at console.anthropic.com. Stored in macOS Keychain only — never uploaded to iCloud.",
                footerText: "Required for AI prompt refinement.",
                removalMessage: "The Anthropic API key will be removed from Keychain."
            )

            // MARK: Clients
            ClientsSettingsSection()

            // MARK: Projects
            ProjectsSettingsSection()

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

            // MARK: Clear Library
            Section {
                Text("Removes all assets, projects, collections, prompts, variants, and tags. Provider configuration and export presets are preserved.")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)

                if isClearing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Clearing library…")
                            .foregroundStyle(Color.appTextSecondary)
                    }
                } else {
                    Button("Clear Library…", role: .destructive) {
                        showClearLibraryConfirmation = true
                    }
                    .buttonStyle(.bordered)
                }
            } header: {
                Text("Danger Zone")
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .frame(minWidth: 380, idealWidth: 440, minHeight: 300)
        #endif
        .navigationTitle("Settings")
        .sheet(item: $migrationDestination) { destination in
            LibraryMigrationSheetView(
                destinationURL: destination.url,
                isMigrating: isMigrating,
                onConfirm: { mode in
                    let url = destination.url
                    Task {
                        isMigrating = true
                        do {
                            try await env.changeLibraryLocation(to: url, mode: mode)
                            migrationDestination = nil   // dismiss sheet
                        } catch {
                            migrationError = error.localizedDescription
                        }
                        isMigrating = false
                    }
                }
            )
        }
        .alert("Migration Failed", isPresented: .init(
            get: { migrationError != nil },
            set: { if !$0 { migrationError = nil } }
        )) {
            Button("OK") { migrationError = nil }
        } message: {
            Text(migrationError ?? "")
        }
        .confirmationDialog(
            "Clear Library?",
            isPresented: $showClearLibraryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Records and Delete Files", role: .destructive) {
                performClearLibrary(deleteFiles: true)
            }
            Button("Clear Records Only", role: .destructive) {
                performClearLibrary(deleteFiles: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove all assets, projects, collections, prompts, variants, and tags from the library. This cannot be undone.")
        }
        .alert("Clear Failed", isPresented: .init(
            get: { clearError != nil },
            set: { if !$0 { clearError = nil } }
        )) {
            Button("OK") { clearError = nil }
        } message: {
            Text(clearError ?? "")
        }
    }

    // MARK: - Clear library

    private func performClearLibrary(deleteFiles: Bool) {
        Task {
            isClearing = true
            do {
                try await env.clearLibrary(deleteFiles: deleteFiles)
            } catch {
                clearError = error.localizedDescription
            }
            isClearing = false
        }
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
