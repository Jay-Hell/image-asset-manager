import Foundation

/// The decision before a provider call: resolve once, gate once, keep both.
///
/// The panel used to resolve for the provider call and again when the user confirmed, so
/// the stored model and estimate could differ from what was generated, and it never ran
/// the budget gate the MCP path runs (Fable E4). This is the one place the panel and the MCP
/// decide; callers hold the result and record from it, and never resolve a second time.
public struct PreparedGeneration: Sendable, Equatable {
    /// Every route that can serve the request, first route first. The first is what is tried;
    /// the rest are the fallbacks `RouteExecutor` may move to. An explicit model has one.
    public let routes: [Resolution]
    public let budget: GenerationPolicy.BudgetContext
    /// What the gate cleared: `budget.count` images at the first route's estimate.
    public let subtotalGBP: Decimal

    /// The resolution captured at estimate time. Confirm records from this.
    public var resolution: Resolution { routes[0] }

    /// Same default limits as the MCP path (20 images, £2.50), on the resolver's estimate.
    /// Throws `ResolveError` or `GenerationPolicy.BudgetViolation`; no provider call
    /// happens before this returns.
    public static func prepare(
        request: ResolveRequest,
        count: Int = 1,
        catalogue: Catalogue,
        providers: Set<String>,
        live: OpenRouterModels = .empty,
        limits: GenerationPolicy.BudgetLimits = .defaults
    ) throws -> PreparedGeneration {
        let routes = try ModelResolver.resolveAll(request, catalogue: catalogue, providers: providers, live: live)
        return try gated(routes: routes, count: count, limits: limits)
    }

    /// A model chosen by name in the panel (a retired ID reads as its replacement; references the
    /// model cannot take reroute with a note). One route: a named model has no fallback.
    public static func prepare(
        provider: String,
        modelID: String,
        referenceCount: Int,
        aspectRatio: String,
        resolution: String? = nil,
        catalogue: Catalogue,
        providers: Set<String>,
        live: OpenRouterModels = .empty,
        limits: GenerationPolicy.BudgetLimits = .defaults
    ) throws -> PreparedGeneration {
        let resolved = try ModelResolver.resolveSelection(
            provider: provider, modelID: modelID, referenceCount: referenceCount,
            aspectRatio: aspectRatio, resolution: resolution, catalogue: catalogue, providers: providers, live: live
        )
        return try gated(routes: [resolved], count: 1, limits: limits)
    }

    /// What the panel's pickers chose: a tier (with its fallbacks) or one named model.
    public static func prepare(
        selection: PanelSelection,
        referenceCount: Int,
        aspectRatio: String,
        resolution: String? = nil,
        catalogue: Catalogue,
        providers: Set<String>,
        live: OpenRouterModels = .empty,
        limits: GenerationPolicy.BudgetLimits = .defaults
    ) throws -> PreparedGeneration {
        switch selection {
        case .tier(let tier):
            return try prepare(
                request: ResolveRequest(quality: tier, referenceCount: referenceCount, aspectRatio: aspectRatio, resolution: resolution),
                catalogue: catalogue, providers: providers, live: live, limits: limits)
        case .model(let provider, let id):
            return try prepare(
                provider: provider, modelID: id, referenceCount: referenceCount, aspectRatio: aspectRatio,
                resolution: resolution, catalogue: catalogue, providers: providers, live: live, limits: limits)
        }
    }

    /// The service request for this decision. The MCP and the panel both build theirs here, so what
    /// is sent (model, routes, gate) cannot differ between them.
    public func request(
        prompt: String,
        negativePrompt: String? = nil,
        aspectRatio: AspectRatio,
        width: Int,
        height: Int,
        ratio: String? = nil,
        references: [GenerationReference] = [],
        projectIDs: [String] = [],
        tags: [String] = [],
        variantFamilyName: String? = nil
    ) -> GenerationService.Request {
        GenerationService.Request(
            prompt: prompt, negativePrompt: negativePrompt, model: resolution.imageModel,
            aspectRatio: aspectRatio, width: width, height: height, references: references,
            projectIDs: projectIDs, tags: tags, variantFamilyName: variantFamilyName,
            budget: budget, routes: routes, ratio: ratio)
    }

    private static func gated(routes: [Resolution], count: Int, limits: GenerationPolicy.BudgetLimits) throws -> PreparedGeneration {
        let budget = GenerationPolicy.BudgetContext(count: count, limits: limits)
        let subtotal = try GenerationPolicy.checkBudget(count: budget.count, unitCost: routes[0].estimateGBP, limits: limits)
        return PreparedGeneration(routes: routes, budget: budget, subtotalGBP: subtotal)
    }

    /// What to store for a finished generation: the model that served it (the provider
    /// reports a change made by a 404 retry) and its estimate; otherwise the captured resolution's.
    public func recording(_ image: GeneratedImage) -> (modelID: String, estimatedCostGBP: Decimal) {
        (image.modelUsed ?? resolution.model.id, image.estimatedCostGBP ?? resolution.estimateGBP)
    }
}

/// What the panel's pickers can say: a tier, or one named model.
public enum PanelSelection: Sendable, Equatable, Hashable {
    case tier(String)
    case model(provider: String, id: String)
}

/// Turns a request into a `PreparedGeneration` for the panel and the MCP alike, and does the
/// two things a resolve needs that need the network: a model list on demand, and the price of an
/// explicit OpenRouter model nothing else prices (pass B leftover). Neither surface resolves itself.
public struct GenerationPlanner: Sendable {
    private let catalogue: @Sendable () -> Catalogue
    private let live: OpenRouterModelStore

    public init(catalogue: @escaping @Sendable () -> Catalogue, live: OpenRouterModelStore) {
        self.catalogue = catalogue
        self.live = live
    }

    public func prepare(
        _ request: ResolveRequest, count: Int = 1, providers: Set<String>, limits: GenerationPolicy.BudgetLimits = .defaults
    ) async throws -> PreparedGeneration {
        await warm(explicitModel: request.explicitModel, providers: providers)
        return try PreparedGeneration.prepare(
            request: request, count: count, catalogue: catalogue(), providers: providers,
            live: live.snapshot(), limits: limits)
    }

    public func prepare(
        _ selection: PanelSelection, referenceCount: Int, aspectRatio: String, resolution: String? = nil,
        providers: Set<String>, limits: GenerationPolicy.BudgetLimits = .defaults
    ) async throws -> PreparedGeneration {
        if case .model(let provider, let id) = selection {
            await warm(explicitModel: "\(provider):\(id)", providers: providers)
        } else {
            await warm(explicitModel: nil, providers: providers)
        }
        return try PreparedGeneration.prepare(
            selection: selection, referenceCount: referenceCount, aspectRatio: aspectRatio, resolution: resolution,
            catalogue: catalogue(), providers: providers, live: live.snapshot(), limits: limits)
    }

    /// With an OpenRouter key: fetch the model list if none is held, and, for an explicit OpenRouter
    /// model that nothing prices, ask OpenRouter its per-image price before the resolver falls
    /// back to the compiled $0.20 gate.
    private func warm(explicitModel: String?, providers: Set<String>) async {
        guard providers.contains(OpenRouterProvider.id) else { return }
        await live.refreshIfNotLoaded()
        guard let explicit = explicitModel, explicit.hasPrefix("\(OpenRouterProvider.id):") else { return }
        let id = String(explicit.dropFirst(OpenRouterProvider.id.count + 1))
        guard !pricedWithoutAsking(id) else { return }
        await live.loadPrice(for: id)
    }

    private func pricedWithoutAsking(_ id: String) -> Bool {
        let catalogue = catalogue()
        let provider = OpenRouterProvider.id
        if let model = catalogue.model(provider: provider, id: id), model.usdEstimate != nil || !model.usdByImageSize.isEmpty { return true }
        for tiers in catalogue.media.values {
            for routes in tiers.values where routes.contains(where: { $0.provider == provider && $0.model == id && $0.usdEstimate != nil }) {
                return true
            }
        }
        return live.snapshot().learntPrice(model: id, size: nil) != nil
    }
}
