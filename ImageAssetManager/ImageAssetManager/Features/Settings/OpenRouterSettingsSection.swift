import SwiftUI
import ImageAssetManagerCore

/// The OpenRouter key and its "Test key" button (spec v0.3 §5.1). The test calls
/// `GET /api/v1/key` and shows the key's label and remaining limit, never the key.
struct OpenRouterSettingsSection: View {
    @State private var isTesting = false
    @State private var result: String?
    @State private var failure: String?

    var body: some View {
        KeychainKeyEditor(
            title: "OpenRouter API Key",
            service: OpenRouterProvider.keychainService,
            account: OpenRouterProvider.keychainAccount,
            helperText: "Get your key at openrouter.ai. Serves every image tier and any OpenRouter image model by name. Prompts and reference images go to openrouter.ai under your own key. Stored in macOS Keychain only — never uploaded to iCloud.",
            footerText: "Optional. With both keys set, Google is used first.",
            removalMessage: "The OpenRouter API key will be removed from Keychain.",
            onKeyChanged: { Task { await ProviderKeyChange.refresh() } }
        )
        Section {
            HStack(spacing: 10) {
                Button("Test key") { Task { await testKey() } }
                    .buttonStyle(.bordered)
                    .disabled(isTesting)
                if isTesting { ProgressView().controlSize(.small) }
            }
            if let result {
                Label(result, systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(Color.appAccent)
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func testKey() async {
        isTesting = true
        result = nil
        failure = nil
        defer { isTesting = false }
        do {
            let key = try KeychainService.retrieve(service: OpenRouterProvider.keychainService, account: OpenRouterProvider.keychainAccount)
            result = try await OpenRouterKeyInfo.check(apiKey: key).summary
        } catch KeychainService.KeychainError.itemNotFound {
            failure = ProviderError.apiKeyNotFound.localizedDescription
        } catch {
            failure = error.localizedDescription
        }
    }
}
