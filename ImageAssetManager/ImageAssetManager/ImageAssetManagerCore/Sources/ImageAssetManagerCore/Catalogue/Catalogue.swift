import Foundation

/// The model catalogue: which models exist, how tiers map to routes, what was
/// retired, and how prompt refinement is called. Loaded from JSON (bundled,
/// remote or a local override) and validated here; see `CatalogueStore` for
/// sources and refresh.
///
/// What the catalogue cannot do (spec v0.1 §4.2, amended by v0.3 §5.2): it names
/// no hosts or URLs, model IDs are pattern-checked before they reach a URL path,
/// prices are bounded, and request headers are allow-listed.
public struct Catalogue: Sendable, Equatable {

    // MARK: - Types

    public struct Route: Sendable, Equatable {
        public let provider: String
        public let model: String
        public let usdEstimate: Decimal?
        /// Overrides the model's default `imageSize` for this tier (Pro takes 2K).
        public let imageSize: String?
    }

    public struct Model: Sendable, Equatable {
        public let id: String
        public let api: String
        public let displayName: String
        public let aspectRatios: [String]
        public let maxReferenceImages: Int
        /// Sizes the model accepts for `imageSize`. Empty means the model takes no size parameter.
        public let imageSizes: [String]
        /// Capabilities beyond references (`seed`, `transparent_background`).
        public let extraCapabilities: Set<String>
        public let usdEstimate: Decimal?
        public let usdByImageSize: [String: Decimal]
        /// Defaults merged into the request body. App-owned fields are written last.
        public let body: [String: JSONValue]
        public let minBuild: Int?

        public func supports(_ capability: Capability) -> Bool {
            switch capability {
            case .references: return maxReferenceImages > 0
            default:          return extraCapabilities.contains(capability.rawValue)
            }
        }

        /// The `imageSize` the catalogue's body asks for by default, if any.
        public var defaultImageSize: String? {
            body["generationConfig"]?.objectValue?["imageConfig"]?.objectValue?["imageSize"]?.stringValue
        }
    }

    public struct Retired: Sendable, Equatable {
        public let id: String
        public let displayName: String
        public let replacedBy: String?
    }

    public struct Refinement: Sendable, Equatable {
        public let api: String
        public let model: String
        /// Already filtered to the allow-list.
        public let headers: [String: String]
        public let body: [String: JSONValue]
    }

    public enum Capability: String, Sendable, CaseIterable {
        case references
        case transparentBackground = "transparent_background"
        case seed
    }

    // MARK: - Stored

    public let schemaVersion: Int
    public let revision: Int
    public let updated: String?
    public let usdToGBP: Decimal?
    /// media -> tier -> ordered routes.
    public let media: [String: [String: [Route]]]
    /// provider -> models.
    public let models: [String: [Model]]
    public let retired: [Retired]
    public let refinement: Refinement?
    /// Entries dropped during validation, for diagnostics. Not part of the content.
    public let skipped: [String]

    // MARK: - Compiled limits

    public static let supportedSchemaVersion = 1
    public static let maxFileBytes = 256 * 1024
    /// Per-image price bound from v0.1 §4.2: above 0 and at most $1.00.
    public static let maxUSDPerImage: Decimal = 1
    public static let allowedHeaders: Set<String> = ["anthropic-version", "anthropic-beta"]
    /// Request shapes compiled into this build, by catalogue `api` string.
    public static let knownModelAPIs: Set<String> = ["gemini.generateContent"]
    public static let knownRefinementAPI = "anthropic.messages"
    /// Tiers the app cannot work without.
    public static let requiredImageTiers = ["fast", "standard", "pro"]

    // MARK: - Lookups

    public var fx: Decimal { usdToGBP ?? Currency.usdToGBP }

    public func model(provider: String, id: String) -> Model? {
        models[provider]?.first { $0.id == id }
    }

    public func routes(media: String, tier: String) -> [Route] {
        self.media[media]?[tier] ?? []
    }

    /// Follows `replacedBy` links from a retired model ID to a live one. Returns
    /// nil if the ID is not retired. A cycle or a dead end returns nil too.
    public func replacement(for id: String) -> String? {
        var current = id
        var hops = 0
        while let entry = retired.first(where: { $0.id == current }), hops < 8 {
            guard let next = entry.replacedBy else { return nil }
            if retired.contains(where: { $0.id == next }) {
                current = next
                hops += 1
            } else {
                return next
            }
        }
        return nil
    }

    /// Name for a model ID stored on an old asset: live entry first, then retired.
    public func displayName(forModelID id: String) -> String? {
        for list in models.values {
            if let m = list.first(where: { $0.id == id }) { return m.displayName }
        }
        return retired.first { $0.id == id }?.displayName
    }

    /// Lowest USD price the catalogue knows for a model, across the entry and every tier route.
    public func listPriceUSD(provider: String, modelID: String) -> Decimal? {
        var prices: [Decimal] = []
        if let m = model(provider: provider, id: modelID) {
            if let p = m.usdEstimate { prices.append(p) }
            prices.append(contentsOf: m.usdByImageSize.values)
        }
        for tiers in media.values {
            for routes in tiers.values {
                for r in routes where r.provider == provider && r.model == modelID {
                    if let p = r.usdEstimate { prices.append(p) }
                }
            }
        }
        return prices.min()
    }

    // MARK: - Errors

    public enum ParseError: Error, Equatable, LocalizedError {
        case tooLarge(Int)
        case notJSON
        case unsupportedSchema(Int?)
        case invalidRevision
        case noUsableModel(String)

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let n):          return "Catalogue is \(n) bytes, over the \(Catalogue.maxFileBytes)-byte limit."
            case .notJSON:                  return "Catalogue is not a JSON object."
            case .unsupportedSchema(let v): return "Catalogue schemaVersion \(v.map(String.init) ?? "missing") is not supported (expected \(Catalogue.supportedSchemaVersion))."
            case .invalidRevision:          return "Catalogue revision is missing or not a positive whole number."
            case .noUsableModel(let t):     return "Catalogue has no usable model for \(t)."
            }
        }
    }

    // MARK: - Parsing

    /// Parse and validate. A file that fails to parse, or leaves a tier with no
    /// usable route, throws and the caller keeps the catalogue it already holds.
    /// A single bad model entry (unknown `api`, `minBuild` above `build`, a bad ID
    /// or price) is skipped and the rest load.
    public static func parse(_ data: Data, build: Int = 0) throws -> Catalogue {
        guard data.count <= maxFileBytes else { throw ParseError.tooLarge(data.count) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ParseError.notJSON
        }
        guard let schema = (root["schemaVersion"] as? NSNumber)?.intValue, schema == supportedSchemaVersion else {
            throw ParseError.unsupportedSchema((root["schemaVersion"] as? NSNumber)?.intValue)
        }
        guard let revision = (root["revision"] as? NSNumber)?.intValue, revision >= 1 else {
            throw ParseError.invalidRevision
        }

        var skipped: [String] = []

        // fx
        var fx: Decimal?
        if let raw = (root["fx"] as? [String: Any])?["usdToGBP"] as? NSNumber {
            let d = decimal(raw.doubleValue)
            if d >= 0.1 && d <= 5 { fx = d } else { skipped.append("fx.usdToGBP out of bounds") }
        }

        // models
        var models: [String: [Model]] = [:]
        for (provider, list) in (root["models"] as? [String: Any]) ?? [:] {
            guard isProviderName(provider), let items = list as? [[String: Any]] else {
                skipped.append("models.\(provider)")
                continue
            }
            for item in items {
                switch parseModel(item, provider: provider, build: build) {
                case .success(let m): models[provider, default: []].append(m)
                case .failure(let reason): skipped.append("\(provider)/\((item["id"] as? String) ?? "?"): \(reason)")
                }
            }
        }

        // media / tiers
        var media: [String: [String: [Route]]] = [:]
        for (mediaName, sectionAny) in (root["media"] as? [String: Any]) ?? [:] {
            guard let tiers = (sectionAny as? [String: Any])?["tiers"] as? [String: Any] else {
                skipped.append("media.\(mediaName)")
                continue
            }
            var parsedTiers: [String: [Route]] = [:]
            for (tierName, routesAny) in tiers {
                guard let routeItems = routesAny as? [[String: Any]] else {
                    throw ParseError.noUsableModel("\(mediaName)/\(tierName)")
                }
                var routes: [Route] = []
                for item in routeItems {
                    switch parseRoute(item, models: models) {
                    case .success(let r): routes.append(r)
                    case .failure(let reason): skipped.append("\(mediaName)/\(tierName): \(reason)")
                    }
                }
                guard !routes.isEmpty else { throw ParseError.noUsableModel("\(mediaName)/\(tierName)") }
                parsedTiers[tierName] = routes
            }
            media[mediaName] = parsedTiers
        }
        for tier in requiredImageTiers where media["image"]?[tier] == nil {
            throw ParseError.noUsableModel("image/\(tier)")
        }

        // retired
        var retired: [Retired] = []
        for item in (root["retired"] as? [[String: Any]]) ?? [] {
            guard let id = item["id"] as? String, isValidModelID(id, allowSlash: true),
                  let name = item["displayName"] as? String else {
                skipped.append("retired entry")
                continue
            }
            let replacedBy = (item["replacedBy"] as? String).flatMap { isValidModelID($0, allowSlash: true) ? $0 : nil }
            retired.append(Retired(id: id, displayName: name, replacedBy: replacedBy))
        }

        // refinement
        var refinement: Refinement?
        if let item = root["refinement"] as? [String: Any] {
            if (item["api"] as? String) == knownRefinementAPI,
               let model = item["model"] as? String, isValidModelID(model, allowSlash: false) {
                var headers: [String: String] = [:]
                for (k, v) in (item["headers"] as? [String: Any]) ?? [:] {
                    if let s = v as? String, allowedHeaders.contains(k.lowercased()) {
                        headers[k.lowercased()] = s
                    } else {
                        skipped.append("refinement header \(k)")
                    }
                }
                let body = (item["body"] as? [String: Any]).flatMap { JSONValue(any: $0)?.objectValue } ?? [:]
                refinement = Refinement(api: knownRefinementAPI, model: model, headers: headers, body: body)
            } else {
                skipped.append("refinement")
            }
        }

        return Catalogue(
            schemaVersion: schema,
            revision: revision,
            updated: root["updated"] as? String,
            usdToGBP: fx,
            media: media,
            models: models,
            retired: retired,
            refinement: refinement,
            skipped: skipped
        )
    }

    // MARK: - Validation helpers

    /// `^[a-z0-9][a-z0-9.-]{1,63}$`, plus (v0.3 §5.2) one `/` for providers that
    /// take the ID in a request body. Google IDs go into a URL path, so no slash there.
    public static func isValidModelID(_ id: String, allowSlash: Bool) -> Bool {
        let part = "[a-z0-9][a-z0-9.-]{1,63}"
        let pattern = allowSlash ? "^\(part)(/\(part))?$" : "^\(part)$"
        return id.range(of: pattern, options: .regularExpression) != nil
    }

    static func isProviderName(_ s: String) -> Bool {
        s.range(of: "^[a-z][a-z0-9_]{1,31}$", options: .regularExpression) != nil
    }

    static func decimal(_ d: Double) -> Decimal {
        Decimal(string: "\(d)") ?? Decimal(d)
    }

    private static func price(_ any: Any?) -> Result<Decimal?, ModelFailure> {
        guard let any else { return .success(nil) }
        guard let n = any as? NSNumber else { return .failure(.init("price is not a number")) }
        let d = decimal(n.doubleValue)
        guard d > 0, d <= maxUSDPerImage else { return .failure(.init("price \(d) out of bounds")) }
        return .success(d)
    }

    private struct ModelFailure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    private static func parseModel(_ item: [String: Any], provider: String, build: Int) -> Result<Model, ModelFailure> {
        guard let id = item["id"] as? String else { return .failure(.init("no id")) }
        // Only a path-bound provider is held to the no-slash rule.
        guard isValidModelID(id, allowSlash: provider != "nano_banana") else {
            return .failure(.init("invalid model id"))
        }
        guard let api = item["api"] as? String else { return .failure(.init("no api")) }
        guard knownModelAPIs.contains(api) else { return .failure(.init("unknown api \(api)")) }
        let minBuild = (item["minBuild"] as? NSNumber)?.intValue
        if let minBuild, minBuild > build { return .failure(.init("needs build \(minBuild)")) }

        let usd: Decimal?
        switch price(item["usdEstimate"]) {
        case .success(let p): usd = p
        case .failure(let f): return .failure(f)
        }
        var bySize: [String: Decimal] = [:]
        for (size, value) in (item["usdByImageSize"] as? [String: Any]) ?? [:] {
            switch price(value) {
            case .success(let p?): bySize[size] = p
            case .success(nil): break
            case .failure(let f): return .failure(f)
            }
        }
        let body = (item["body"] as? [String: Any]).flatMap { JSONValue(any: $0)?.objectValue } ?? [:]
        let refs = (item["maxReferenceImages"] as? NSNumber)?.intValue ?? 0
        guard refs >= 0, refs <= 32 else { return .failure(.init("maxReferenceImages out of bounds")) }

        return .success(Model(
            id: id,
            api: api,
            displayName: (item["displayName"] as? String) ?? id,
            aspectRatios: (item["aspectRatios"] as? [String]) ?? [],
            maxReferenceImages: refs,
            imageSizes: (item["imageSizes"] as? [String]) ?? [],
            extraCapabilities: Set((item["capabilities"] as? [String]) ?? []),
            usdEstimate: usd,
            usdByImageSize: bySize,
            body: body,
            minBuild: minBuild
        ))
    }

    private static func parseRoute(_ item: [String: Any], models: [String: [Model]]) -> Result<Route, ModelFailure> {
        guard let provider = item["provider"] as? String, isProviderName(provider),
              let id = item["model"] as? String else { return .failure(.init("route needs provider and model")) }
        guard isValidModelID(id, allowSlash: provider != "nano_banana") else {
            return .failure(.init("invalid route model id"))
        }
        let usd: Decimal?
        switch price(item["usdEstimate"]) {
        case .success(let p): usd = p
        case .failure(let f): return .failure(f)
        }
        let size = item["imageSize"] as? String
        // A provider whose models are listed here must list this one. Providers with
        // a live model list (openrouter) are checked at resolve time instead.
        if provider == "nano_banana" {
            guard let entry = models[provider]?.first(where: { $0.id == id }) else {
                return .failure(.init("route to \(id) which is not a usable model"))
            }
            if let size, !entry.imageSizes.isEmpty, !entry.imageSizes.contains(size) {
                return .failure(.init("route size \(size) not accepted by \(id)"))
            }
        }
        return .success(Route(provider: provider, model: id, usdEstimate: usd, imageSize: size))
    }
}
