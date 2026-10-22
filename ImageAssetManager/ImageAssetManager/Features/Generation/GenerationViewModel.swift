import Foundation
import ImageAssetManagerCore

@Observable
final class GenerationViewModel {

    // MARK: - Data
    var projects: [Project] = []
    var availableProviders: [any ImageProvider] = []

    // MARK: - Selection
    /// Primary project: drives active references and provider defaults.
    /// The generated asset is additionally attached to every ID in `additionalProjectIDs`.
    var selectedProjectID: String?
    var additionalProjectIDs: Set<String> = []
    /// The full project set (primary + additional) the generated asset will belong to.
    var allSelectedProjectIDs: [String] {
        guard let primary = selectedProjectID else { return [] }
        var rest = additionalProjectIDs
        rest.remove(primary)
        return [primary] + rest.sorted()
    }
    var referenceEntries: [ReferenceEntry] = []
    var confirmedReferenceIDs: Set<String> = []
    var selectedProviderID: String?
    var selectedModelID: String?

    // MARK: - Prompt
    var promptText: String = ""
    var negativePromptText: String = ""
    var showNegativePrompt: Bool = false

    // MARK: - Generation Config
    var aspectRatio: AspectRatio = .landscape
    var customWidth: Int = 1792
    var customHeight: Int = 1024

    // MARK: - Generation State
    var isGenerating: Bool = false
    var generationError: String?
    var generatedImage: GeneratedImage?

    // MARK: - Post-Generation
    var pendingTags: [String] = []
    var tagInputText: String = ""
    var selectedVariantFamilyName: String = ""
    /// Names of existing variant families in the current project (or orphan families when
    /// no project is selected). Populated alongside the project's other dependencies.
    var existingVariantFamilyNames: [String] = []
    var saveToPromptLibrary: Bool = false
    var promptLibraryTitle: String = ""
    var pendingRefinement: PendingRefinement?

    struct PendingRefinement: Sendable {
        let mode: String
        let draftPrompt: String
        let conversationJSON: String
        let modelUsed: String
        let finalPrompt: String
    }

    // MARK: - Prompt picker
    var allPrompts: [Prompt] = []

    let database: AppDatabase
    private(set) var libraryURL: URL

    init(database: AppDatabase, libraryURL: URL) {
        self.database = database
        self.libraryURL = libraryURL
    }

    // MARK: - Computed

    var currentProvider: (any ImageProvider)? {
        availableProviders.first { $0.providerID == selectedProviderID }
    }

    var currentModel: ImageModel? {
        guard let provider = currentProvider else { return nil }
        return provider.availableModels.first { $0.id == selectedModelID }
            ?? provider.availableModels.first
    }

    /// The model that will actually be used for the next generation.
    /// Auto-routes to the reference-capable model when refs are attached and the
    /// user-selected model can't handle them.
    var effectiveModel: ImageModel? {
        guard let provider = currentProvider, let selected = currentModel else { return nil }
        if !confirmedReferenceIDs.isEmpty
            && provider is NanaBananaProvider
            && !NanaBananaProvider.supportsReferences(modelID: selected.id) {
            return provider.availableModels.first { $0.id == NanaBananaProvider.ModelID.geminiWithRefs } ?? selected
        }
        return selected
    }

    /// Non-nil when the generation will use a different model than the user selected
    /// (e.g. auto-routing to "With References" because refs are attached).
    var modelRouteNote: String? {
        guard let selected = currentModel, let effective = effectiveModel, selected.id != effective.id else {
            return nil
        }
        return "References attached — using \(effective.displayName)"
    }

    var estimatedCost: Decimal {
        guard let provider = currentProvider, let model = effectiveModel else { return 0 }
        let params = GenerationParams(
            prompt: promptText,
            model: model,
            aspectRatio: aspectRatio,
            width: resolvedWidth,
            height: resolvedHeight
        )
        return provider.estimateCost(params)
    }

    var canGenerate: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && currentProvider != nil
            && effectiveModel != nil
            && !isGenerating
    }

    var resolvedWidth: Int {
        switch aspectRatio {
        case .square:    return 1024
        case .landscape: return 1792
        case .portrait:  return 1024
        case .custom:    return customWidth
        }
    }

    var resolvedHeight: Int {
        switch aspectRatio {
        case .square:    return 1024
        case .landscape: return 1024
        case .portrait:  return 1792
        case .custom:    return customHeight
        }
    }

    var dimensionLabel: String { "\(resolvedWidth) × \(resolvedHeight)" }

    // MARK: - Loading

    func loadInitialData() async {
        async let providersResult = ProviderRegistry.shared.allProviders()
        async let projectsResult = (try? database.fetchProjects()) ?? []
        async let promptsResult = (try? database.fetchPrompts()) ?? []

        let (providers, projs, prompts) = await (providersResult, projectsResult, promptsResult)

        availableProviders = providers
        projects = projs
        allPrompts = prompts

        if selectedProviderID == nil {
            selectedProviderID = providers.first?.providerID
        }
        if selectedModelID == nil {
            selectedModelID = currentProvider?.availableModels.first?.id
        }
        if selectedProjectID == nil, let first = projs.first {
            selectedProjectID = first.id
            await loadProjectDependencies(projectID: first.id)
        }
    }

    func projectSelectionChanged() async {
        guard let projectID = selectedProjectID else {
            referenceEntries = []
            confirmedReferenceIDs = []
            return
        }
        await loadProjectDependencies(projectID: projectID)
    }

    func providerSelectionChanged() {
        guard let provider = currentProvider else { return }
        if provider.availableModels.first(where: { $0.id == selectedModelID }) == nil {
            selectedModelID = provider.availableModels.first?.id
        }
    }

    private func loadProjectDependencies(projectID: String) async {
        if let project = projects.first(where: { $0.id == projectID }) {
            if let pid = project.defaultProviderID { selectedProviderID = pid }
            if let mid = project.defaultModelID { selectedModelID = mid }
        }

        async let refsResult = (try? database.fetchActiveReferenceEntries(projectID: projectID)) ?? []
        async let famsResult = (try? database.fetchVariantFamilyNames(projectID: projectID)) ?? []

        let (refs, fams) = await (refsResult, famsResult)
        referenceEntries = refs
        existingVariantFamilyNames = fams
        confirmedReferenceIDs = []
    }

    // MARK: - Generation

    func generate() async {
        guard canGenerate, let provider = currentProvider, let model = effectiveModel else { return }

        isGenerating = true
        generationError = nil
        generatedImage = nil

        do {
            let refs: [ReferenceInput]?
            if !confirmedReferenceIDs.isEmpty && provider.supportsReferenceImages {
                refs = await buildReferenceInputs()
            } else {
                refs = nil
            }

            let params = GenerationParams(
                prompt: promptText.trimmingCharacters(in: .whitespacesAndNewlines),
                negativePrompt: negativePromptText.isEmpty ? nil : negativePromptText,
                model: model,
                aspectRatio: aspectRatio,
                width: resolvedWidth,
                height: resolvedHeight
            )

            generatedImage = try await provider.generate(params, references: refs)
        } catch {
            generationError = error.localizedDescription
        }

        isGenerating = false
    }

    private func buildReferenceInputs() async -> [ReferenceInput] {
        let entries = referenceEntries.filter { confirmedReferenceIDs.contains($0.id) }
        var inputs: [ReferenceInput] = []
        for entry in entries {
            guard let asset = try? await database.fetchAsset(id: entry.assetID) else { continue }
            let fileURL = libraryURL.appending(path: "assets").appending(path: asset.filename)
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            let role: ReferenceRole = entry.role == "style_anchor" ? .styleAnchor : .subjectAnchor
            inputs.append(ReferenceInput(
                assetID: entry.assetID,
                imageData: data,
                role: role,
                weight: Float(entry.weight)
            ))
        }
        return inputs
    }

    // MARK: - Confirm / Discard

    func confirmGeneration() async throws {
        guard let result = generatedImage else { return }

        let assetID = UUID().uuidString
        let filename = "\(assetID).\(result.format)"
        let assetsDir = libraryURL.appending(path: "assets")
        let fileURL = assetsDir.appending(path: filename)

        let imageData = result.data
        try imageData.write(to: fileURL)

        let now = ISO8601DateFormatter().string(from: Date())
        let asset = Asset(
            id: assetID,
            filename: filename,
            fileHash: imageData.sha256,
            projectID: selectedProjectID,
            providerID: currentProvider?.providerID ?? "",
            modelID: effectiveModel?.id ?? "",
            prompt: promptText,
            negativePrompt: negativePromptText.isEmpty ? nil : negativePromptText,
            width: resolvedWidth,
            height: resolvedHeight,
            aspectRatio: aspectRatio.rawValue,
            estimatedCost: Double(truncating: estimatedCost as NSDecimalNumber),
            actualCost: result.actualCost.map { Double(truncating: $0 as NSDecimalNumber) },
            createdAt: now
        )
        try await database.insertAsset(asset)

        let projectIDs = allSelectedProjectIDs
        if !projectIDs.isEmpty {
            try await database.setProjectsForAsset(assetID: assetID, projectIDs: projectIDs)
        }

        try await database.insertSpendLog(SpendLog(
            assetID: assetID,
            providerID: currentProvider?.providerID ?? "",
            estimatedCost: asset.estimatedCost,
            actualCost: asset.actualCost,
            timestamp: now
        ))

        for name in pendingTags.map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            let tag = try await database.findOrCreateTag(name: name)
            try await database.attachTag(tagID: tag.id, assetID: assetID)
        }

        for entry in referenceEntries.filter({ confirmedReferenceIDs.contains($0.id) }) {
            try await database.insertAssetReference(AssetReference(
                assetID: assetID,
                referenceSetID: entry.referenceSetID,
                referenceEntryID: entry.id,
                roleUsed: entry.role,
                weightUsed: entry.weight,
                passedToAPI: true
            ))
        }

        try await database.attachToVariantFamily(
            assetID: assetID,
            projectID: selectedProjectID,
            familyName: selectedVariantFamilyName,
            prompt: promptText,
            filename: asset.filename
        )

        if saveToPromptLibrary {
            let title = promptLibraryTitle.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty {
                let prompt = Prompt(title: title, body: promptText,
                                    negativePrompt: negativePromptText.isEmpty ? nil : negativePromptText,
                                    createdAt: now, updatedAt: now)
                try await database.insertPrompt(prompt)
                try await database.insertPromptAsset(PromptAsset(promptID: prompt.id, assetID: assetID))
            }
        }

        if let pending = pendingRefinement {
            let refinement = PromptRefinement(
                assetID: assetID,
                mode: pending.mode,
                draftPrompt: pending.draftPrompt,
                finalPrompt: pending.finalPrompt,
                conversation: pending.conversationJSON,
                modelUsed: pending.modelUsed,
                createdAt: now
            )
            try await database.saveRefinement(refinement)
        }

        let indexURL = libraryURL.appending(path: "index.json")
        try await IndexExporter.export(from: database, to: indexURL, assetsBaseURL: assetsDir)

        resetPostGeneration()
    }

    func discardGeneration() {
        generatedImage = nil
        generationError = nil
        resetPostGeneration()
    }

    // MARK: - Tag helpers

    func addTagFromInput() {
        let cleaned = tagInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !pendingTags.contains(cleaned) else {
            tagInputText = ""
            return
        }
        pendingTags.append(cleaned)
        tagInputText = ""
    }

    func removeTag(_ name: String) {
        pendingTags.removeAll { $0 == name }
    }

    private func resetPostGeneration() {
        generatedImage = nil
        pendingTags = []
        tagInputText = ""
        selectedVariantFamilyName = ""
        saveToPromptLibrary = false
        promptLibraryTitle = ""
        pendingRefinement = nil
    }
}
