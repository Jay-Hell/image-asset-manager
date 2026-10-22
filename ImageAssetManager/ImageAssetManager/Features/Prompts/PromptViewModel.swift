import Foundation
import ImageAssetManagerCore

@Observable
final class PromptViewModel {

    // MARK: - Browse state
    var prompts: [Prompt] = []
    var sectors: [String] = []
    var searchText: String = ""
    var selectedSector: String? = nil
    var selectedPromptID: String? = nil

    // MARK: - Editor
    var showEditor: Bool = false
    var editingPrompt: Prompt? = nil

    // MARK: - Detail
    var linkedAssets: [Asset] = []
    var isLoading: Bool = false

    private let database: AppDatabase
    let libraryURL: URL

    private var promptsDir: URL {
        libraryURL.appending(path: "prompts")
    }

    init(database: AppDatabase, libraryURL: URL) {
        self.database = database
        self.libraryURL = libraryURL
    }

    // MARK: - Loading

    func loadPrompts() async {
        isLoading = true
        defer { isLoading = false }

        async let promptsResult = (try? database.searchPrompts(
            text: searchText.isEmpty ? nil : searchText,
            sector: selectedSector
        )) ?? []
        async let sectorsResult = (try? database.fetchDistinctSectors()) ?? []

        let (ps, ss) = await (promptsResult, sectorsResult)
        prompts = ps
        sectors = ss
    }

    func selectPrompt(_ promptID: String) async {
        selectedPromptID = promptID
        linkedAssets = (try? await database.fetchAssetsForPrompt(promptID: promptID)) ?? []
    }

    // MARK: - CRUD

    func savePrompt(
        id: String?,
        title: String,
        body: String,
        negativePrompt: String,
        sector: String,
        tags: String
    ) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let sectorValue: String? = sector.trimmingCharacters(in: .whitespaces).isEmpty ? nil
            : sector.trimmingCharacters(in: .whitespaces)
        let tagsJSON = buildTagsJSON(from: tags)

        if let id {
            guard var existing = prompts.first(where: { $0.id == id }) else { return }
            existing.title = title
            existing.body = body
            existing.negativePrompt = negativePrompt.isEmpty ? nil : negativePrompt
            existing.sector = sectorValue
            existing.tags = tagsJSON
            existing.updatedAt = now
            try await database.updatePrompt(existing)
            try PromptVaultExporter.write(prompt: existing, to: promptsDir)
        } else {
            let prompt = Prompt(
                title: title,
                body: body,
                negativePrompt: negativePrompt.isEmpty ? nil : negativePrompt,
                sector: sectorValue,
                tags: tagsJSON,
                createdAt: now,
                updatedAt: now
            )
            try await database.insertPrompt(prompt)
            try PromptVaultExporter.write(prompt: prompt, to: promptsDir)
        }
        await loadPrompts()
    }

    func deletePrompt(_ promptID: String) async throws {
        try await database.deletePrompt(id: promptID)
        PromptVaultExporter.delete(promptID: promptID, from: promptsDir)
        if selectedPromptID == promptID {
            selectedPromptID = nil
            linkedAssets = []
        }
        await loadPrompts()
    }

    func startCreate() {
        editingPrompt = nil
        showEditor = true
    }

    func startEdit(_ prompt: Prompt) {
        editingPrompt = prompt
        showEditor = true
    }

    // MARK: - Helpers

    private func buildTagsJSON(from raw: String) -> String? {
        let list = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !list.isEmpty else { return nil }
        return "[\(list.map { "\"\($0)\"" }.joined(separator: ", "))]"
    }
}
