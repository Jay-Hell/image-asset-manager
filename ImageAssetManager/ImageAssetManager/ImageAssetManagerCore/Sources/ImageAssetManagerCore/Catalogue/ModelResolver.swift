import Foundation

/// What a caller wants. It names no model unless `explicitModel` is set.
public struct ResolveRequest: Sendable, Equatable {
    public var media: String
    /// `fast`, `standard`, `pro`, `with_references` or `auto` (case-insensitive).
    public var quality: String
    public var require: Set<Catalogue.Capability>
    /// `provider:model`, or a bare model ID looked up in the configured providers.
    public var explicitModel: String?
    /// References attached to the request. Implies the `references` capability, and
    /// lets a tier that cannot take them reroute (with a note) rather than fail.
    public var referenceCount: Int
    public var aspectRatio: String
    public var resolution: String?
    /// Only for a model whose live record lists `output_format`. Vector requests default to `svg`.
    public var outputFormat: String?

    public init(
        media: String = "image",
        quality: String = "auto",
        require: Set<Catalogue.Capability> = [],
        explicitModel: String? = nil,
        referenceCount: Int = 0,
        aspectRatio: String = "1:1",
        resolution: String? = nil,
        outputFormat: String? = nil
    ) {
        self.outputFormat = outputFormat
        self.media = media
        self.quality = quality
        self.require = require
        self.explicitModel = explicitModel
        self.referenceCount = referenceCount
        self.aspectRatio = aspectRatio
        self.resolution = resolution
    }
}

/// The route the resolver chose, with the parameters that route accepts.
public struct Resolution: Sendable, Equatable {
    public let provider: String
    public let model: Catalogue.Model
    /// The tier used, nil for an explicit model.
    public let tier: String?
    /// The `imageSize` to send, if the model takes one.
    public let imageSize: String?
    public let aspectRatio: String
    public let maxReferenceImages: Int
    public let estimateUSD: Decimal
    public let estimateGBP: Decimal
    /// Which source the estimate came from (catalogue, OpenRouter endpoint pricing, an observed cost, or the compiled default).
    public let estimateSource: EstimateSource
    /// True when nothing priced the model and the compiled default was used.
    public var estimateIsDefault: Bool { estimateSource == .unknownDefault }
    /// The `output_format` to send, when the model lists one and the request or media asks for it.
    public let outputFormat: String?
    /// Set when the first route was not used, or the tier was rerouted.
    public let note: String?

    /// The model as the provider layer and the panel see it.
    public var imageModel: ImageModel {
        ImageModel(
            id: model.id,
            displayName: model.displayName,
            supportedAspectRatios: AspectRatio.allCases.filter {
                $0 != .custom && model.aspectRatios.contains($0.rawValue)
            },
            costPerImage: estimateGBP,
            maxReferenceImages: maxReferenceImages,
            imageSize: imageSize
        )
    }
}

public enum ResolveError: Error, Equatable, Sendable {
    case unknownQuality(String)
    case unknownMedia(String)
    case unknownModel(String)
    case providerNotConfigured(String)
    /// No route in the tier belongs to a configured provider.
    case noRoute(media: String, tier: String, needs: [String])
    /// Routes exist but none has the capabilities. `alternatives` names what would.
    case capabilityUnavailable(missing: [String], alternatives: [String])
    case unsupportedAspectRatio(requested: String, supported: [String])
    case unsupportedResolution(requested: String, supported: [String])
    case unsupportedOutputFormat(requested: String, supported: [String])
    /// OpenRouter has a key but its model list has not loaded (first launch offline).
    case liveListNotLoaded
}

extension ResolveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownQuality(let q):
            return "unknown quality '\(q)' (expected fast|standard|pro|with_references|auto)"
        case .unknownMedia(let m):
            return "unknown media '\(m)'"
        case .unknownModel(let m):
            return "model '\(m)' is not in the catalogue"
        case .providerNotConfigured(let p):
            return "provider '\(p)' is not configured"
        case .noRoute(let media, let tier, let needs):
            return "no configured provider can serve \(media)/\(tier) (needs one of: \(needs.joined(separator: ", ")))"
        case .capabilityUnavailable(let missing, let alternatives):
            // The error carries the full list; the message shows the first few.
            let shown = alternatives.prefix(12).joined(separator: ", ")
            let more = alternatives.count > 12 ? " and \(alternatives.count - 12) more" : ""
            let tail = alternatives.isEmpty ? "nothing configured offers it" : "would work: \(shown)\(more)"
            return "no route has \(missing.joined(separator: ", ")); \(tail)"
        case .unsupportedAspectRatio(let r, let s):
            return "aspect ratio '\(r)' is not supported by this model (supported: \(s.joined(separator: ", ")))"
        case .unsupportedResolution(let r, let s):
            let list = s.isEmpty ? "none; this model takes no size" : s.joined(separator: ", ")
            return "resolution '\(r)' is not supported by this model (supported: \(list))"
        case .unsupportedOutputFormat(let r, let s):
            let list = s.isEmpty ? "none; this model lists no output format" : s.joined(separator: ", ")
            return "output format '\(r)' is not supported by this model (supported: \(list))"
        case .liveListNotLoaded:
            return "OpenRouter's model list not yet loaded; retrying in the background (after 1, 5 and 30 minutes, then daily)"
        }
    }
}

/// Spec v0.3 §5.4. One pure function turns a request into a route; the panel and
/// the MCP both call it and neither picks a model itself.
public enum ModelResolver {

    /// Gate price for a model the catalogue has no price for (spec §5.6).
    public static let unknownPriceUSD: Decimal = Decimal(string: "0.20")!

    static let tierNames = ["fast", "standard", "pro"]

    public static func resolve(
        _ request: ResolveRequest,
        catalogue: Catalogue,
        providers: Set<String>,
        live: OpenRouterModels = .empty
    ) throws -> Resolution {
        // `resolveAll` never returns an empty list: it throws instead.
        try resolveAll(request, catalogue: catalogue, providers: providers, live: live)[0]
    }

    /// A model as a route sees it: the catalogue entry for a path-bound provider; for OpenRouter
    /// the live record (capabilities, ratios, sizes, formats), overlaid with the catalogue's
    /// entry for the same model if there is one (price, name, body defaults).
    static func lookup(_ provider: String, _ id: String, catalogue: Catalogue, live: OpenRouterModels) -> Catalogue.Model? {
        guard provider == "openrouter" else { return catalogue.model(provider: provider, id: id) }
        return live.model(id)?.asCatalogueModel(overlay: catalogue.model(provider: provider, id: id))
    }

    /// Every route that can serve the request, in order; the first is what `resolve` returns.
    /// The rest are the fallbacks a provider failure may move to (spec §5.4): same request,
    /// same capabilities, parameters checked against each model's own list.
    public static func resolveAll(
        _ request: ResolveRequest,
        catalogue: Catalogue,
        providers: Set<String>,
        live: OpenRouterModels = .empty
    ) throws -> [Resolution] {
        guard let quality = GenerationPolicy.Quality(rawValue: request.quality.lowercased()) else {
            throw ResolveError.unknownQuality(request.quality)
        }
        guard catalogue.media[request.media] != nil else {
            throw ResolveError.unknownMedia(request.media)
        }

        // Old names: with_references is standard plus the references capability;
        // auto keeps its meaning (standard, or the reference-capable route when
        // references are attached).
        var needs = request.require
        if quality == .withReferences { needs.insert(.references) }
        if request.referenceCount > 0 { needs.insert(.references) }

        if let explicit = request.explicitModel {
            return [try resolveExplicit(explicit, needs: needs, request: request, catalogue: catalogue, providers: providers, live: live)]
        }

        let tier: String
        switch quality {
        case .fast: tier = "fast"
        case .pro:  tier = "pro"
        case .standard, .withReferences, .auto: tier = "standard"
        }

        let routes = catalogue.routes(media: request.media, tier: tier)
        let usable = routes.map { route -> Catalogue.Model? in
            guard providers.contains(route.provider) else { return nil }
            return lookup(route.provider, route.model, catalogue: catalogue, live: live)
        }
        guard usable.contains(where: { $0 != nil }) else {
            if providers.contains("openrouter"), live.isEmpty, routes.contains(where: { $0.provider == "openrouter" }) {
                throw ResolveError.liveListNotLoaded
            }
            throw ResolveError.noRoute(media: request.media, tier: tier, needs: Array(Set(routes.map(\.provider))).sorted())
        }

        let capable = usable.indices.filter { i in usable[i].map { supportsAll($0, needs) } ?? false }
        if let first = capable.first, let firstModel = usable[first] {
            var note: String?
            if first > 0 {
                note = "Used \(routes[first].provider) for \(tier): the first route was unavailable"
            }
            // The first route's parameters are checked and any failure is the caller's to see;
            // a later route that cannot take them (its list lacks the ratio) is simply not a fallback.
            var result = [try build(model: firstModel, route: routes[first], tier: tier, request: request, catalogue: catalogue, note: note, live: live)]
            for i in capable.dropFirst() {
                guard let model = usable[i],
                      let alt = try? build(model: model, route: routes[i], tier: tier, request: request, catalogue: catalogue, note: nil, live: live)
                else { continue }
                result.append(alt)
            }
            return result
        }

        // References were attached but nothing in this tier takes them: reroute, as
        // the app always has. An explicit `require` never reroutes; it errors.
        if request.referenceCount > 0 && request.require.isEmpty && quality != .withReferences {
            for other in ["standard", "pro", "fast"] where other != tier {
                let otherRoutes = catalogue.routes(media: request.media, tier: other)
                for route in otherRoutes where providers.contains(route.provider) {
                    if let model = lookup(route.provider, route.model, catalogue: catalogue, live: live), supportsAll(model, needs) {
                        let note = "Auto-routed to \(other) because references are attached; \(tier) can't use them on this API"
                        return [try build(model: model, route: route, tier: other, request: request, catalogue: catalogue, note: note, live: live)]
                    }
                }
            }
        }

        throw ResolveError.capabilityUnavailable(
            missing: needs.map(\.rawValue).sorted(),
            alternatives: alternatives(for: needs, catalogue: catalogue, providers: providers, live: live)
        )
    }

    // MARK: - Panel entry point

    /// The panel selects a model, not a tier. This resolves that selection through the
    /// same function the MCP uses. A retired ID resolves to its replacement; if
    /// references are attached and the selection cannot take them, it reroutes to the
    /// `standard` tier with a note, exactly as the MCP's `auto` would.
    public static func resolveSelection(
        provider: String,
        modelID: String,
        referenceCount: Int,
        aspectRatio: String,
        resolution: String? = nil,
        media: String = "image",
        catalogue: Catalogue,
        providers: Set<String>,
        live: OpenRouterModels = .empty
    ) throws -> Resolution {
        let liveID = catalogue.replacement(for: modelID) ?? modelID
        let request = ResolveRequest(
            media: media,
            quality: "standard",
            explicitModel: "\(provider):\(liveID)",
            referenceCount: referenceCount,
            aspectRatio: aspectRatio,
            resolution: resolution
        )
        do {
            return try resolve(request, catalogue: catalogue, providers: providers, live: live)
        } catch ResolveError.capabilityUnavailable where referenceCount > 0 {
            var rerouted = request
            rerouted.explicitModel = nil
            let result = try resolve(rerouted, catalogue: catalogue, providers: providers, live: live)
            return Resolution(
                provider: result.provider, model: result.model, tier: result.tier,
                imageSize: result.imageSize, aspectRatio: result.aspectRatio,
                maxReferenceImages: result.maxReferenceImages,
                estimateUSD: result.estimateUSD, estimateGBP: result.estimateGBP,
                estimateSource: result.estimateSource,
                outputFormat: result.outputFormat,
                note: "References attached — using \(result.model.displayName)"
            )
        }
    }

    // MARK: - Explicit model

    private static func resolveExplicit(
        _ explicit: String,
        needs: Set<Catalogue.Capability>,
        request: ResolveRequest,
        catalogue: Catalogue,
        providers: Set<String>,
        live: OpenRouterModels
    ) throws -> Resolution {
        let providerPart: String?
        let id: String
        if let colon = explicit.firstIndex(of: ":") {
            providerPart = String(explicit[..<colon])
            id = String(explicit[explicit.index(after: colon)...])
        } else {
            providerPart = nil
            id = explicit
        }

        let found: (String, Catalogue.Model)?
        if let providerPart {
            guard providers.contains(providerPart) else { throw ResolveError.providerNotConfigured(providerPart) }
            found = lookup(providerPart, id, catalogue: catalogue, live: live).map { (providerPart, $0) }
        } else {
            found = providers.sorted().lazy.compactMap { p in
                lookup(p, id, catalogue: catalogue, live: live).map { (p, $0) }
            }.first
        }
        guard let (provider, model) = found else { throw ResolveError.unknownModel(explicit) }

        guard supportsAll(model, needs) else {
            throw ResolveError.capabilityUnavailable(
                missing: needs.filter { !model.supports($0) }.map(\.rawValue).sorted(),
                alternatives: alternatives(for: needs, catalogue: catalogue, providers: providers, live: live)
            )
        }

        // Borrow the tier route's size and price for this model, if one lists it.
        // Tiers are walked in catalogue order (fast, standard, pro, then any other by name) so
        // a model on two tiers gets the same route on every launch, not dictionary order.
        let tiers = catalogue.media[request.media] ?? [:]
        let ordered = tierNames.filter { tiers[$0] != nil } + tiers.keys.filter { !tierNames.contains($0) }.sorted()
        let route = ordered.lazy.compactMap { tiers[$0] }.flatMap { $0 }
            .first { $0.provider == provider && $0.model == id }
        return try build(model: model, route: route, tier: nil, request: request, catalogue: catalogue, note: nil, provider: provider, live: live)
    }

    // MARK: - Helpers

    private static func supportsAll(_ model: Catalogue.Model, _ needs: Set<Catalogue.Capability>) -> Bool {
        needs.allSatisfy { model.supports($0) }
    }

    /// Tiers and explicit models that would satisfy `needs`, for the error message.
    static func alternatives(for needs: Set<Catalogue.Capability>, catalogue: Catalogue, providers: Set<String>, live: OpenRouterModels = .empty) -> [String] {
        var found: [String] = []
        for mediaName in catalogue.media.keys.sorted() {
            for tier in tierNames {
                for route in catalogue.routes(media: mediaName, tier: tier) where providers.contains(route.provider) {
                    if let m = lookup(route.provider, route.model, catalogue: catalogue, live: live), supportsAll(m, needs) {
                        found.append("\(mediaName)/\(tier)")
                        break
                    }
                }
            }
        }
        for provider in providers.sorted() {
            for m in catalogue.models[provider] ?? [] where supportsAll(m, needs) {
                found.append("\(provider):\(m.id)")
            }
            if provider == "openrouter" {
                for m in live.models.sorted(by: { $0.id < $1.id }) where supportsAll(m.asCatalogueModel(), needs) {
                    let entry = "openrouter:\(m.id)"
                    if !found.contains(entry) { found.append(entry) }
                }
            }
        }
        return found
    }

    private static func build(
        model: Catalogue.Model,
        route: Catalogue.Route?,
        tier: String?,
        request: ResolveRequest,
        catalogue: Catalogue,
        note: String?,
        provider: String? = nil,
        live: OpenRouterModels = .empty
    ) throws -> Resolution {
        if !model.aspectRatios.isEmpty && !model.aspectRatios.contains(request.aspectRatio) {
            throw ResolveError.unsupportedAspectRatio(requested: request.aspectRatio, supported: model.aspectRatios)
        }

        let isOpenRouter = model.api == "openrouter.images"
        var imageSize: String?
        if let requested = request.resolution {
            guard model.imageSizes.contains(requested) else {
                throw ResolveError.unsupportedResolution(requested: requested, supported: model.imageSizes)
            }
            imageSize = requested
        } else {
            imageSize = route?.imageSize ?? model.defaultImageSize
            // A size the catalogue asks for that the live record does not list is not sent.
            if isOpenRouter, let size = imageSize, !model.imageSizes.contains(size) { imageSize = nil }
        }

        // Only a model whose live record lists `output_format` is sent one. A vector request
        // asks for svg unless the caller named a format.
        let outputFormat: String?
        if let requested = request.outputFormat {
            guard model.outputFormats.contains(requested) else {
                throw ResolveError.unsupportedOutputFormat(requested: requested, supported: model.outputFormats)
            }
            outputFormat = requested
        } else if request.media == "vector", model.outputFormats.contains("svg") {
            outputFormat = "svg"
        } else {
            outputFormat = nil
        }

        let usd: Decimal
        let source: EstimateSource
        if let size = imageSize, let bySize = model.usdByImageSize[size] {
            usd = bySize
            source = .catalogue
        } else if let priced = route?.usdEstimate ?? model.usdEstimate {
            usd = priced
            source = .catalogue
        } else if isOpenRouter, let learnt = live.prices[model.id] {
            usd = learnt.usdPerImage
            source = EstimateSource(rawValue: learnt.source) ?? .endpointPricing
        } else {
            usd = unknownPriceUSD
            source = .unknownDefault
        }

        return Resolution(
            provider: provider ?? route?.provider ?? "",
            model: model,
            tier: tier,
            imageSize: imageSize,
            aspectRatio: request.aspectRatio,
            maxReferenceImages: model.maxReferenceImages,
            estimateUSD: usd,
            estimateGBP: usd * catalogue.fx,
            estimateSource: source,
            outputFormat: outputFormat,
            note: note
        )
    }
}
