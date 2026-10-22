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

    public init(
        media: String = "image",
        quality: String = "auto",
        require: Set<Catalogue.Capability> = [],
        explicitModel: String? = nil,
        referenceCount: Int = 0,
        aspectRatio: String = "1:1",
        resolution: String? = nil
    ) {
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
    /// True when the catalogue held no price and the compiled default was used.
    public let estimateIsDefault: Bool
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
            let tail = alternatives.isEmpty ? "nothing configured offers it" : "would work: \(alternatives.joined(separator: ", "))"
            return "no route has \(missing.joined(separator: ", ")); \(tail)"
        case .unsupportedAspectRatio(let r, let s):
            return "aspect ratio '\(r)' is not supported by this model (supported: \(s.joined(separator: ", ")))"
        case .unsupportedResolution(let r, let s):
            let list = s.isEmpty ? "none; this model takes no size" : s.joined(separator: ", ")
            return "resolution '\(r)' is not supported by this model (supported: \(list))"
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
        providers: Set<String>
    ) throws -> Resolution {
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
            return try resolveExplicit(explicit, needs: needs, request: request, catalogue: catalogue, providers: providers)
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
            return catalogue.model(provider: route.provider, id: route.model)
        }
        guard usable.contains(where: { $0 != nil }) else {
            throw ResolveError.noRoute(media: request.media, tier: tier, needs: Array(Set(routes.map(\.provider))).sorted())
        }

        if let index = usable.indices.first(where: { i in usable[i].map { supportsAll($0, needs) } ?? false }),
           let model = usable[index] {
            var note: String?
            if index > 0 {
                note = "Used \(routes[index].provider) for \(tier): the first route was unavailable"
            }
            return try build(model: model, route: routes[index], tier: tier, request: request, catalogue: catalogue, note: note)
        }

        // References were attached but nothing in this tier takes them: reroute, as
        // the app always has. An explicit `require` never reroutes; it errors.
        if request.referenceCount > 0 && request.require.isEmpty && quality != .withReferences {
            for other in ["standard", "pro", "fast"] where other != tier {
                let otherRoutes = catalogue.routes(media: request.media, tier: other)
                for route in otherRoutes where providers.contains(route.provider) {
                    if let model = catalogue.model(provider: route.provider, id: route.model), supportsAll(model, needs) {
                        let note = "Auto-routed to \(other) because references are attached; \(tier) can't use them on this API"
                        return try build(model: model, route: route, tier: other, request: request, catalogue: catalogue, note: note)
                    }
                }
            }
        }

        throw ResolveError.capabilityUnavailable(
            missing: needs.map(\.rawValue).sorted(),
            alternatives: alternatives(for: needs, catalogue: catalogue, providers: providers)
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
        providers: Set<String>
    ) throws -> Resolution {
        let live = catalogue.replacement(for: modelID) ?? modelID
        let request = ResolveRequest(
            media: media,
            quality: "standard",
            explicitModel: "\(provider):\(live)",
            referenceCount: referenceCount,
            aspectRatio: aspectRatio,
            resolution: resolution
        )
        do {
            return try resolve(request, catalogue: catalogue, providers: providers)
        } catch ResolveError.capabilityUnavailable where referenceCount > 0 {
            var rerouted = request
            rerouted.explicitModel = nil
            let result = try resolve(rerouted, catalogue: catalogue, providers: providers)
            return Resolution(
                provider: result.provider, model: result.model, tier: result.tier,
                imageSize: result.imageSize, aspectRatio: result.aspectRatio,
                maxReferenceImages: result.maxReferenceImages,
                estimateUSD: result.estimateUSD, estimateGBP: result.estimateGBP,
                estimateIsDefault: result.estimateIsDefault,
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
        providers: Set<String>
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
            found = catalogue.model(provider: providerPart, id: id).map { (providerPart, $0) }
        } else {
            found = providers.sorted().lazy.compactMap { p in
                catalogue.model(provider: p, id: id).map { (p, $0) }
            }.first
        }
        guard let (provider, model) = found else { throw ResolveError.unknownModel(explicit) }

        guard supportsAll(model, needs) else {
            throw ResolveError.capabilityUnavailable(
                missing: needs.filter { !model.supports($0) }.map(\.rawValue).sorted(),
                alternatives: alternatives(for: needs, catalogue: catalogue, providers: providers)
            )
        }

        // Borrow the tier route's size and price for this model, if one lists it.
        let route = catalogue.media[request.media]?.values.lazy.flatMap { $0 }
            .first { $0.provider == provider && $0.model == id }
        return try build(model: model, route: route, tier: nil, request: request, catalogue: catalogue, note: nil, provider: provider)
    }

    // MARK: - Helpers

    private static func supportsAll(_ model: Catalogue.Model, _ needs: Set<Catalogue.Capability>) -> Bool {
        needs.allSatisfy { model.supports($0) }
    }

    /// Tiers and explicit models that would satisfy `needs`, for the error message.
    static func alternatives(for needs: Set<Catalogue.Capability>, catalogue: Catalogue, providers: Set<String>) -> [String] {
        var found: [String] = []
        for mediaName in catalogue.media.keys.sorted() {
            for tier in tierNames {
                for route in catalogue.routes(media: mediaName, tier: tier) where providers.contains(route.provider) {
                    if let m = catalogue.model(provider: route.provider, id: route.model), supportsAll(m, needs) {
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
        provider: String? = nil
    ) throws -> Resolution {
        if !model.aspectRatios.isEmpty && !model.aspectRatios.contains(request.aspectRatio) {
            throw ResolveError.unsupportedAspectRatio(requested: request.aspectRatio, supported: model.aspectRatios)
        }

        let imageSize: String?
        if let requested = request.resolution {
            guard model.imageSizes.contains(requested) else {
                throw ResolveError.unsupportedResolution(requested: requested, supported: model.imageSizes)
            }
            imageSize = requested
        } else {
            imageSize = route?.imageSize ?? model.defaultImageSize
        }

        let usd: Decimal
        var isDefault = false
        if let size = imageSize, let bySize = model.usdByImageSize[size] {
            usd = bySize
        } else if let priced = route?.usdEstimate ?? model.usdEstimate {
            usd = priced
        } else {
            usd = unknownPriceUSD
            isDefault = true
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
            estimateIsDefault: isDefault,
            note: note
        )
    }
}
