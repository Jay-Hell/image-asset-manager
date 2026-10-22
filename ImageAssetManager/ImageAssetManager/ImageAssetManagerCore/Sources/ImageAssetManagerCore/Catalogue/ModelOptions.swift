import Foundation

/// One model a caller can name: from the catalogue, or (OpenRouter) from the live list.
/// The panel's "Specific model…" picker and the MCP's `list_generation_options` both read this,
/// so a model the panel offers is one the MCP lists, at the same estimate.
public struct ModelOption: Sendable, Equatable {
    public let provider: String
    public let id: String
    public let displayName: String
    /// `image`, or `vector` for a model that lists SVG output.
    public let media: String
    public let estimateGBP: Decimal
    public let estimateSource: EstimateSource
    public let capabilities: [String]
    public let maxReferenceImages: Int
    public let aspectRatios: [String]
    public let imageSizes: [String]

    /// What a caller passes as `model`.
    public var reference: String { "\(provider):\(id)" }
}

public enum ModelOptions {

    /// Every model the configured providers offer, catalogue entries first, then the live
    /// OpenRouter list, ordered by provider and name. A model the resolver cannot price is left out.
    public static func all(catalogue: Catalogue, providers: Set<String>, live: OpenRouterModels) -> [ModelOption] {
        var options: [ModelOption] = []
        for provider in providers.sorted() {
            var ids = (catalogue.models[provider] ?? []).map(\.id)
            if provider == OpenRouterProvider.id {
                ids += live.models.map(\.id).filter { !ids.contains($0) }
            }
            var group: [ModelOption] = []
            for id in ids {
                guard let model = ModelResolver.lookup(provider, id, catalogue: catalogue, live: live) else { continue }
                let media = model.outputFormats.contains("svg") ? "vector" : "image"
                let request = ResolveRequest(
                    media: catalogue.media[media] != nil ? media : "image",
                    explicitModel: "\(provider):\(id)",
                    aspectRatio: model.aspectRatios.first ?? "1:1")
                guard let resolved = try? ModelResolver.resolve(request, catalogue: catalogue, providers: providers, live: live) else { continue }
                group.append(ModelOption(
                    provider: provider, id: id, displayName: model.displayName, media: media,
                    estimateGBP: resolved.estimateGBP, estimateSource: resolved.estimateSource,
                    capabilities: Catalogue.Capability.allCases.filter { model.supports($0) }.map(\.rawValue),
                    maxReferenceImages: model.maxReferenceImages,
                    aspectRatios: model.aspectRatios, imageSizes: model.imageSizes))
            }
            options += group.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
        return options
    }
}
