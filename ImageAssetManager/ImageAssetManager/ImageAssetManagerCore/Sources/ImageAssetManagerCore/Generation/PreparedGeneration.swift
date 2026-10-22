import Foundation

/// The in-app panel's decision before a provider call: resolve once, gate once, keep both.
///
/// The panel used to resolve for the provider call and again when the user confirmed, so
/// the stored model and estimate could differ from what was generated, and it never ran
/// the budget gate the MCP path runs (Fable E4). This is the one place the panel decides;
/// the view model holds the result and records from it, and never resolves a second time.
public struct PreparedGeneration: Sendable, Equatable {
    /// The resolution captured at estimate time. Confirm records from this.
    public let resolution: Resolution
    public let budget: GenerationPolicy.BudgetContext
    /// What the gate cleared: one image at the resolver's estimate.
    public let subtotalGBP: Decimal

    /// Same default limits as the MCP path (20 images, £2.50), on the resolver's estimate.
    /// Throws `ResolveError` or `GenerationPolicy.BudgetViolation`; no provider call
    /// happens before this returns.
    public static func prepare(
        provider: String,
        modelID: String,
        referenceCount: Int,
        aspectRatio: String,
        catalogue: Catalogue,
        providers: Set<String>,
        limits: GenerationPolicy.BudgetLimits = .defaults
    ) throws -> PreparedGeneration {
        let resolution = try ModelResolver.resolveSelection(
            provider: provider, modelID: modelID, referenceCount: referenceCount,
            aspectRatio: aspectRatio, catalogue: catalogue, providers: providers
        )
        let budget = GenerationPolicy.BudgetContext(count: 1, limits: limits)
        let subtotal = try GenerationPolicy.checkBudget(count: budget.count, unitCost: resolution.estimateGBP, limits: limits)
        return PreparedGeneration(resolution: resolution, budget: budget, subtotalGBP: subtotal)
    }

    /// What to store for a finished generation: the model that served it (the provider
    /// reports a change made by a 404 retry) and its estimate; otherwise the captured resolution's.
    public func recording(_ image: GeneratedImage) -> (modelID: String, estimatedCostGBP: Decimal) {
        (image.modelUsed ?? resolution.model.id, image.estimatedCostGBP ?? resolution.estimateGBP)
    }
}
