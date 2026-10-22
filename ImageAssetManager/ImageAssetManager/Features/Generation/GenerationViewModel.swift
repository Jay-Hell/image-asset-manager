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

    /// What the user asks for: a quality tier (the app picks the model and has a fallback) or
    /// "Specific model…" (one named model, no fallback).
    enum TierChoice: String, CaseIterable, Identifiable {
        case fast, standard, pro, specific
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fast: return "Fast"
            case .standard: return "Standard"
            case .pro: return "Pro"
            case .specific: return "Specific model…"
            }
        }
    }
    var tierChoice: TierChoice = .standard
    /// `provider:model`, when `tierChoice` is `.specific`.
    var specificModelRef: String?
    /// Catalogue models and the OpenRouter live list, image only; filled when the panel loads.
    var modelOptions: [ModelOption] = []

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
    /// The resolution and gate captured when `generate()` ran. Confirm records from it.
    private(set) var preparedGeneration: PreparedGeneration?
    /// The provider's answer, held until the user keeps or discards it. Nothing is stored yet.
    private var pendingGenerated: GenerationService.Generated?
    private var pendingPrompt = ""
    private var pendingReferences: [GenerationReference] = []

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

    private var providerIDs: Set<String> { Set(availableProviders.map(\.providerID)) }

    private var apiRatio: String { aspectRatio.apiRatio(width: resolvedWidth, height: resolvedHeight) }

    /// The picker state as the Core selection the MCP's resolver path also understands.
    var selection: PanelSelection? {
        switch tierChoice {
        case .specific:
            guard let ref = specificModelRef, let colon = ref.firstIndex(of: ":") else { return nil }
            return .model(provider: String(ref[..<colon]), id: String(ref[ref.index(after: colon)...]))
        case .fast, .standard, .pro:
            return .tier(tierChoice.rawValue)
        }
    }

    /// The decision for the next generation, from Core (the planner the MCP also uses): resolved
    /// and budget-gated, with the fallback routes. The panel never picks a model itself. This is
    /// the instant form for the screen; `generate()` repeats it through the planner, which may
    /// first fetch a price, and then holds the result.
    private func preview() throws -> PreparedGeneration {
        guard let selection else { throw ResolveError.unknownModel(specificModelRef ?? "") }
        return try PreparedGeneration.prepare(
            selection: selection, referenceCount: confirmedReferenceIDs.count, aspectRatio: apiRatio,
            catalogue: CatalogueStore.shared.snapshot(), providers: providerIDs,
            live: OpenRouterModelStore.shared.snapshot()
        )
    }

    /// The model that will be tried first for the next generation. Reroutes to a
    /// reference-capable model (with a note) when refs are attached and the selection
    /// can't take them.
    var effectiveModel: ImageModel? { try? preview().resolution.imageModel }

    /// "Gemini 3 Pro Image · Google Gemini": what the next generation will use.
    var resolvedSummary: String? {
        guard let resolution = try? preview().resolution else { return nil }
        return "\(displayName(of: resolution.model.id, fallback: resolution.model.displayName)) · \(providerName(resolution.provider))"
    }

    /// Non-nil when the generation will use a different model than the user selected
    /// (e.g. rerouting because refs are attached), or when no route is available.
    var modelRouteNote: String? {
        do { return try preview().resolution.note } catch { return error.localizedDescription }
    }

    var estimatedCost: Decimal { (try? preview().resolution.estimateGBP) ?? 0 }

    var canGenerate: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !availableProviders.isEmpty
            && selection != nil
            && effectiveModel != nil
            && !isGenerating
    }

    /// References can be attached whenever any provider is configured; the resolver picks a
    /// model that takes them (or says why none does).
    var canAttachReferences: Bool { !availableProviders.isEmpty }

    /// After generating: what served it, and why, including any fallback. Nil before.
    var servedSummary: String? {
        guard let prepared = preparedGeneration, let image = generatedImage else { return nil }
        let model = recordedModel(prepared, image)
        let provider = image.providerUsed ?? prepared.resolution.provider
        return "\(displayName(of: model, fallback: model)) · \(providerName(provider))"
    }

    var servedNotes: [String] {
        guard let prepared = preparedGeneration else { return [] }
        return [prepared.resolution.note].compactMap { $0 } + (pendingGenerated?.fallbackNotes ?? [])
    }

    private func recordedModel(_ prepared: PreparedGeneration, _ image: GeneratedImage) -> String {
        prepared.recording(image).modelID
    }

    private func displayName(of modelID: String, fallback: String) -> String {
        CatalogueStore.shared.snapshot().displayName(forModelID: modelID) ?? fallback
    }

    private func providerName(_ id: String) -> String {
        availableProviders.first { $0.providerID == id }?.displayName ?? id
    }

    /// The "Specific model…" list, grouped by provider, each with its estimate.
    var modelGroups: [(provider: String, name: String, options: [ModelOption])] {
        var order: [String] = []
        for option in modelOptions where !order.contains(option.provider) { order.append(option.provider) }
        return order.map { id in (id, providerName(id), modelOptions.filter { $0.provider == id }) }
    }

    func refreshModelOptions() {
        modelOptions = ModelOptions.all(
            catalogue: CatalogueStore.shared.snapshot(), providers: providerIDs, live: OpenRouterModelStore.shared.snapshot()
        ).filter { $0.media == "image" }
    }

    func selectSpecific(provider: String, modelID: String) {
        tierChoice = .specific
        // A stored ID for a retired model (old project default, old asset) reads as its replacement.
        specificModelRef = "\(provider):\(CatalogueStore.shared.liveModelID(for: modelID))"
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
        // The same decision the MCP makes: compiled in and a key present (spec v0.3 §5.1).
        let providersResult = ProviderAvailability.usable()
        async let projectsResult = (try? database.fetchProjects()) ?? []
        async let promptsResult = (try? database.fetchPrompts()) ?? []

        let (projs, prompts) = await (projectsResult, promptsResult)

        availableProviders = providersResult
        projects = projs
        allPrompts = prompts

        refreshModelOptions()
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

    /// "Specific model…" picked: offer the list as it stands now (the OpenRouter list may have loaded since launch).
    func tierChoiceChanged() {
        guard tierChoice == .specific else { return }
        refreshModelOptions()
        if specificModelRef == nil { specificModelRef = modelOptions.first?.reference }
    }

    private func loadProjectDependencies(projectID: String) async {
        if let project = projects.first(where: { $0.id == projectID }),
           let pid = project.defaultProviderID, let mid = project.defaultModelID {
            // A project default names a model; a default that points at a retired one moves to its replacement.
            selectSpecific(provider: pid, modelID: mid)
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
        guard canGenerate, let selection else { return }

        isGenerating = true
        generationError = nil
        generatedImage = nil
        preparedGeneration = nil
        pendingGenerated = nil

        do {
            // The same Core path as the MCP: the planner resolves once and gates before any provider
            // call (asking OpenRouter a price first where an explicit model needs one), and the
            // service walks the routes with fallback. Confirm records from this and never resolves again.
            let prompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
            let references = await buildReferences()
            let run = try await PanelGeneration.run(
                selection: selection, referenceCount: confirmedReferenceIDs.count, aspectRatio: apiRatio,
                prompt: prompt, negativePrompt: negativePromptText.isEmpty ? nil : negativePromptText,
                shape: aspectRatio, width: resolvedWidth, height: resolvedHeight, references: references,
                providers: availableProviders, database: database, libraryURL: libraryURL,
                catalogue: { CatalogueStore.shared.snapshot() }, live: .shared)
            pendingPrompt = prompt
            pendingReferences = references
            pendingGenerated = run.generated
            generatedImage = run.generated.image
            preparedGeneration = run.prepared
        } catch {
            generationError = error.localizedDescription
        }

        isGenerating = false
    }

    /// The service the MCP builds, over the providers this panel has: every route's provider is
    /// reachable, so a fallback to another provider works.
    private func service(for prepared: PreparedGeneration) throws -> GenerationService {
        try PanelGeneration.service(
            for: prepared, providers: availableProviders, database: database, libraryURL: libraryURL, live: .shared)
    }

    private func buildReferences() async -> [GenerationReference] {
        let entries = referenceEntries.filter { confirmedReferenceIDs.contains($0.id) }
        var references: [GenerationReference] = []
        for entry in entries {
            guard let asset = try? await database.fetchAsset(id: entry.assetID) else { continue }
            let fileURL = libraryURL.appending(path: "assets").appending(path: asset.filename)
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            let role: ReferenceRole = entry.role == "style_anchor" ? .styleAnchor : .subjectAnchor
            references.append(GenerationReference(
                input: ReferenceInput(assetID: entry.assetID, imageData: data, role: role, weight: Float(entry.weight)),
                referenceSetID: entry.referenceSetID,
                referenceEntryID: entry.id
            ))
        }
        return references
    }

    // MARK: - Confirm / Discard

    func confirmGeneration() async throws {
        guard let generated = pendingGenerated, let prepared = preparedGeneration else { return }

        // The one place bytes become a library asset, as for the MCP: Core's service sniffs the
        // content (a label the bytes contradict is refused, and the charge is still recorded),
        // stores what the serving model and provider were, and writes the asset, spend, tags,
        // references and variant rows. Nothing here resolves again.
        let request = prepared.request(
            prompt: pendingPrompt, negativePrompt: negativePromptText.isEmpty ? nil : negativePromptText,
            aspectRatio: aspectRatio, width: resolvedWidth, height: resolvedHeight,
            references: pendingReferences, projectIDs: allSelectedProjectIDs,
            tags: pendingTags, variantFamilyName: selectedVariantFamilyName)
        let outcome = try await service(for: prepared).record(generated, for: request)
        let assetID = outcome.assetID
        let assetsDir = libraryURL.appending(path: "assets")
        let now = ISO8601DateFormatter().string(from: Date())

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
        pendingGenerated = nil
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
        pendingGenerated = nil
        pendingReferences = []
        preparedGeneration = nil
        pendingTags = []
        tagInputText = ""
        selectedVariantFamilyName = ""
        saveToPromptLibrary = false
        promptLibraryTitle = ""
        pendingRefinement = nil
    }
}
