import Foundation

/// The panel's Generate step, in Core so the tests drive the code the view model runs: the planner
/// resolves and gates over the providers this install can use, the service walks the routes with
/// fallback, and the paid answer is held (its charge already recorded as "not kept") until Keep.
public struct PanelGeneration: Sendable {
    public let prepared: PreparedGeneration
    public let generated: GenerationService.Generated

    public static func run(
        selection: PanelSelection,
        referenceCount: Int,
        aspectRatio: String,
        prompt: String,
        negativePrompt: String?,
        shape: AspectRatio,
        width: Int,
        height: Int,
        references: [GenerationReference],
        providers: [any ImageProvider],
        database: AppDatabase,
        libraryURL: URL,
        catalogue: @escaping @Sendable () -> Catalogue,
        live: OpenRouterModelStore
    ) async throws -> PanelGeneration {
        let prepared = try await GenerationPlanner(catalogue: catalogue, live: live).prepare(
            selection, referenceCount: referenceCount, aspectRatio: aspectRatio,
            providers: Set(providers.map(\.providerID)))
        let request = prepared.request(
            prompt: prompt, negativePrompt: negativePrompt, aspectRatio: shape,
            width: width, height: height, references: references)
        let generated = try await service(
            for: prepared, providers: providers, database: database, libraryURL: libraryURL, live: live
        ).call(request)
        return PanelGeneration(prepared: prepared, generated: generated)
    }

    /// The service the MCP builds, over the providers this install has: every route's provider is
    /// reachable, so a fallback to another provider works.
    public static func service(
        for prepared: PreparedGeneration,
        providers: [any ImageProvider],
        database: AppDatabase,
        libraryURL: URL,
        live: OpenRouterModelStore
    ) throws -> GenerationService {
        guard let first = providers.first else { throw ProviderError.apiKeyNotFound }
        return GenerationService(
            database: database, libraryURL: libraryURL,
            provider: providers.first { $0.providerID == prepared.resolution.provider } ?? first,
            router: RouteExecutor(providers: providers, liveModels: live))
    }
}
