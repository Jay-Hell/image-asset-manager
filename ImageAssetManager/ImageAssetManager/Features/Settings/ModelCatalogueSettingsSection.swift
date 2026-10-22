import SwiftUI
import ImageAssetManagerCore
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// Settings → Model catalogue: which revision is in force, where it came from, when it
/// was last fetched, and the controls to check for an update (or, on macOS, load a
/// catalogue from a file to test it before publishing).
struct ModelCatalogueSettingsSection: View {
    @State private var status = CatalogueStore.shared.status()
    @State private var isChecking = false
    @State private var resultMessage: String?
    @State private var overrideError: String?

    var body: some View {
        Section {
            LabeledContent("Revision") { Text("\(status.revision)") }

            LabeledContent("Source") {
                HStack(spacing: 6) {
                    Text(sourceName)
                    if status.source == .override {
                        Text("OVERRIDE")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.appAccent, in: Capsule())
                    }
                }
            }

            LabeledContent("Last checked") {
                Text(status.lastFetch.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
            }

            if let error = status.lastError {
                Text("Last error: \(error)")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .textSelection(.enabled)
            }

            HStack {
                Button(isChecking ? "Checking…" : "Check for model updates") { check() }
                    .buttonStyle(.bordered)
                    .disabled(isChecking)
                #if os(macOS)
                Button("Load catalogue from file…") { loadOverride() }
                    .buttonStyle(.bordered)
                if status.source == .override {
                    Button("Remove override") {
                        CatalogueStore.shared.clearOverride()
                        status = CatalogueStore.shared.status()
                    }
                    .buttonStyle(.bordered)
                }
                #endif
            }

            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }
            if let overrideError {
                Text(overrideError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Which models the app uses is set by a catalogue file the app checks at launch and every 24 hours. Changes can take a few minutes to reach the app after they are published.")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
        } header: {
            Text("Model Catalogue")
        }
        .task { status = CatalogueStore.shared.status() }
    }

    private var sourceName: String {
        switch status.source {
        case .bundled:  return "Bundled with the app"
        case .remote:   return "Downloaded"
        case .override: return "Local file"
        }
    }

    private func check() {
        isChecking = true
        resultMessage = nil
        Task {
            let result = await CatalogueStore.shared.refresh()
            switch result {
            case .updated(let revision): resultMessage = "Updated to revision \(revision)."
            case .notModified:           resultMessage = "Already up to date."
            case .notNewer(let revision): resultMessage = "Already up to date (the published revision is \(revision))."
            case .failed(let message):   resultMessage = "Could not check: \(message)"
            }
            status = CatalogueStore.shared.status()
            isChecking = false
        }
    }

    #if os(macOS)
    private func loadOverride() {
        overrideError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a catalogue file to use instead of the downloaded one."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CatalogueStore.shared.loadOverride(try Data(contentsOf: url))
            status = CatalogueStore.shared.status()
        } catch {
            overrideError = "That file was not used: \(error.localizedDescription)"
        }
    }
    #endif
}
