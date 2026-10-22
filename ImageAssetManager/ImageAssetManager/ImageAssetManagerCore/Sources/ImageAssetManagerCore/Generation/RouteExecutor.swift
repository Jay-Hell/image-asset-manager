import Foundation

/// Runs a request along the routes the resolver returned (spec v0.3 §5.4, T16).
///
/// It moves to the next route on exactly three conditions: the provider has no key, the model
/// is not found (404), or OpenRouter is out of credit (402). Each condition moves on at most
/// once per request. Anything else (a 400, a 401, a 429, a bad response) is reported as it is
/// and never retried on another route, so a request is not paid for twice.
///
/// Before each route after the first, the budget is checked again at that route's price: the
/// fallback is a different model, and the gate the caller cleared priced the first one.
public struct RouteExecutor: Sendable {
    public enum Condition: String, Sendable { case noKey, notFound, outOfCredit }

    private let providers: [String: any ImageProvider]
    private let liveModels: OpenRouterModelStore?

    public init(providers: [any ImageProvider], liveModels: OpenRouterModelStore? = nil) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.providerID, $0) })
        self.liveModels = liveModels
    }

    public struct Outcome: Sendable {
        public let image: GeneratedImage
        public let route: Resolution
        /// Why earlier routes were left, in order. Empty when the first route served.
        public let fallbackNotes: [String]
    }

    public func generate(routes: [Resolution], base: GenerationParams, references: [ReferenceInput]?) async throws -> Outcome {
        precondition(!routes.isEmpty, "RouteExecutor needs at least one route")
        var used = Set<Condition>()
        var notes: [String] = []
        var index = 0
        while true {
            let route = routes[index]
            let params = base.retargeted(to: route.imageModel, outputFormat: route.outputFormat)
            if index > 0, let budget = base.budget {
                _ = try GenerationPolicy.checkBudget(count: budget.count, unitCost: route.estimateGBP, limits: budget.remainingLimits)
            }
            guard let provider = providers[route.provider] else {
                // A route whose provider is not registered is "no key" in effect.
                if try advance(.noKey, used: &used, index: &index, count: routes.count, notes: &notes, from: route, error: ProviderError.apiKeyNotFound) { continue }
                throw ProviderError.apiKeyNotFound
            }
            do {
                let image = try await provider.generate(params, references: references)
                let moved = index > 0
                return Outcome(
                    image: GeneratedImage(
                        data: image.data, format: image.format, actualCost: image.actualCost, seed: image.seed,
                        rawResponse: image.rawResponse,
                        modelUsed: image.modelUsed ?? (moved ? route.model.id : nil),
                        estimatedCostGBP: image.estimatedCostGBP ?? (moved ? route.estimateGBP : nil),
                        providerUsed: route.provider, mimeType: image.mimeType
                    ),
                    route: route, fallbackNotes: notes
                )
            } catch let error as ProviderError {
                let condition: Condition?
                switch error {
                case .apiKeyNotFound:    condition = .noKey
                case .modelUnavailable:  condition = .notFound
                case .outOfCredit:       condition = .outOfCredit
                default:                 condition = nil
                }
                guard let condition else { throw error }
                if condition == .notFound, route.provider == OpenRouterProvider.id {
                    await liveModels?.refreshAfterModelUnavailable()
                }
                if try advance(condition, used: &used, index: &index, count: routes.count, notes: &notes, from: route, error: error) { continue }
                throw error
            }
        }
    }

    /// True if there is a next route to move to and this condition has not moved the request before.
    private func advance(_ condition: Condition, used: inout Set<Condition>, index: inout Int, count: Int,
                         notes: inout [String], from route: Resolution, error: Error) throws -> Bool {
        guard index + 1 < count, !used.contains(condition) else { return false }
        used.insert(condition)
        index += 1
        notes.append("\(route.provider) \(route.model.id) failed (\(condition.rawValue)); used the next route")
        return true
    }
}
