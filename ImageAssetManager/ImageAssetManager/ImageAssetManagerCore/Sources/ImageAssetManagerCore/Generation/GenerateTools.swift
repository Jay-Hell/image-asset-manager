import Foundation

/// The MCP's generation tools, request to result (spec v0.3 §5.5): `generate`, its alias
/// `generate_image`, and `list_generation_options`. The app's HTTP server only carries bytes to
/// and from `call`; everything that decides lives here so tests drive the real call site.
///
/// Arguments and results cross as JSON `Data`: the caller is a model, and a value that is not
/// plain JSON has no business crossing.
public struct GenerateTools: Sendable {

    public static let toolNames: Set<String> = ["generate", "generate_image", "list_generation_options"]

    private let database: AppDatabase
    private let libraryURL: URL
    private let catalogue: @Sendable () -> Catalogue
    private let live: OpenRouterModelStore
    private let configuredProviders: @Sendable () -> [any ImageProvider]
    private let ceiling: @Sendable () -> GenerationPolicy.BudgetLimits
    private let fallbackProvider: any ImageProvider

    /// - Parameters:
    ///   - providers: the providers that have a key right now.
    ///   - fallbackProvider: used only when none has one, so the caller is told which key is missing.
    public init(
        database: AppDatabase,
        libraryURL: URL,
        catalogue: @escaping @Sendable () -> Catalogue,
        live: OpenRouterModelStore,
        providers: @escaping @Sendable () -> [any ImageProvider],
        ceiling: @escaping @Sendable () -> GenerationPolicy.BudgetLimits,
        fallbackProvider: any ImageProvider = NanaBananaProvider()
    ) {
        self.database = database
        self.libraryURL = libraryURL
        self.catalogue = catalogue
        self.live = live
        self.configuredProviders = providers
        self.ceiling = ceiling
        self.fallbackProvider = fallbackProvider
    }

    /// The providers with a key in the Keychain: `ProviderAvailability`, as the panel uses.
    public static func keychainProviders() -> [any ImageProvider] {
        ProviderAvailability.usable()
    }

    public func call(_ name: String, arguments: Data) async throws -> Data {
        let args = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        let result: [String: Any]
        switch name {
        case "generate":                result = try await generate(args, forcedMedia: nil)
        case "generate_image":          result = try await generate(args, forcedMedia: "image")
        case "list_generation_options": result = try await listOptions(args)
        default:                        throw MCPGenerateError.invalidParam("unknown tool '\(name)'")
        }
        return try JSONSerialization.data(withJSONObject: result)
    }

    // MARK: - generate

    private func generate(_ args: [String: Any], forcedMedia: String?) async throws -> [String: Any] {
        // --- 1. Media ----------------------------------------------------
        let media = forcedMedia ?? ((args["media"] as? String)?.lowercased() ?? "image")
        if media == "video" || media == "audio" {
            throw MCPGenerateError.invalidParam("media '\(media)' is not yet supported")
        }

        // --- 2. Prompt ---------------------------------------------------
        let promptInput: PromptInput
        if let text = args["prompt"] as? String {
            promptInput = .text(text)
        } else if let dict = args["prompt"] as? [String: Any] {
            promptInput = .structured(dict)
        } else {
            throw MCPGenerateError.invalidParam("prompt must be a string or JSON object")
        }
        let basePrompt = PromptFlattener.flatten(promptInput)
        guard !basePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPGenerateError.invalidParam("prompt is empty after flattening")
        }
        let negativePrompt = (args["negative_prompt"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // --- 3. Quality / capabilities / count / aspect ratio ------------
        let quality = (args["quality"] as? String)?.lowercased() ?? "auto"
        var require: Set<Catalogue.Capability> = []
        for raw in (args["require"] as? [String]) ?? [] {
            guard let capability = Catalogue.Capability(rawValue: raw) else {
                throw MCPGenerateError.invalidParam(
                    "unknown capability '\(raw)' (expected \(Catalogue.Capability.allCases.map(\.rawValue).joined(separator: ", ")))")
            }
            require.insert(capability)
        }
        let count = max(1, (args["count"] as? Int) ?? 1)
        let shape = try AspectShape(parsing: (args["aspect_ratio"] as? String) ?? "square")
        let resolution = (args["resolution"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let explicitModel = (args["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // --- 4. Budget defaults, clamped to the app-held ceiling ---------
        // The caller may LOWER the limits but never raise them past the ceiling:
        // an autonomous agent passing max_cost_gbp: 999 gets the ceiling, and a
        // note saying so. The ceiling is the server's, not the prompt's.
        let requested = GenerationPolicy.BudgetLimits(
            maxImages: (args["max_images"] as? Int) ?? GenerationPolicy.BudgetLimits.defaults.maxImages,
            maxCostGBP: Self.decimalArg(args["max_cost_gbp"]) ?? GenerationPolicy.BudgetLimits.defaults.maxCostGBP
        )
        let clamp = GenerationPolicy.clampLimits(requested: requested, ceiling: ceiling())
        let budget = clamp.limits
        var notes: [String] = []
        if clamp.clampedImages { notes.append("max_images clamped to \(budget.maxImages) (app setting)") }
        if clamp.clampedCost { notes.append("max_cost_gbp clamped to \(Self.format(budget.maxCostGBP)) (app setting)") }

        // --- 5. Projects and references ----------------------------------
        // Accept either a singular "project" string (primary) or a "projects" array
        // (first is primary). A mix is allowed — singular acts as the primary when
        // "projects" is absent.
        var resolvedProjects: [Project] = []
        if let raw = args["project"] as? String, !raw.isEmpty {
            guard let p = try await database.findProject(idOrName: raw) else {
                throw MCPGenerateError.notFound("project '\(raw)'")
            }
            resolvedProjects.append(p)
        }
        if let rawList = args["projects"] as? [String] {
            for raw in rawList where !raw.isEmpty {
                guard let p = try await database.findProject(idOrName: raw) else {
                    throw MCPGenerateError.notFound("project '\(raw)'")
                }
                if !resolvedProjects.contains(where: { $0.id == p.id }) { resolvedProjects.append(p) }
            }
        }
        let candidates = try await resolveReferences(args: args, project: resolvedProjects.first)

        // --- 6. Route (media + quality + capabilities → provider, model) --
        // The planner resolves and gates; this handler never picks a model. The reference cap is the
        // resolved model's, so references are merged afterwards.
        let keyed = configuredProviders()
        let configured = keyed.isEmpty ? [fallbackProvider] : keyed
        let planner = GenerationPlanner(catalogue: catalogue, live: live)
        let prepared: PreparedGeneration
        do {
            prepared = try await planner.prepare(
                ResolveRequest(
                    media: media, quality: quality, require: require, explicitModel: explicitModel,
                    referenceCount: candidates.project.count + candidates.explicit.count,
                    aspectRatio: shape.ratio, resolution: resolution),
                count: count, providers: Set(configured.map(\.providerID)), limits: budget)
        } catch let error as ResolveError {
            throw MCPGenerateError.invalidParam(error.localizedDescription)
        } catch GenerationPolicy.BudgetViolation.tooManyImages(let c, let m) {
            throw MCPGenerateError.limitExceeded("count \(c) exceeds max_images \(m)", details: ["count": c, "max_images": m])
        } catch GenerationPolicy.BudgetViolation.tooCostly(let sub, let m) {
            throw MCPGenerateError.limitExceeded(
                "projected spend \(Self.format(sub)) exceeds max_cost_gbp \(Self.format(m))",
                details: [
                    "count": count,
                    "unit_cost_gbp": Self.double(sub) / Double(count),
                    "subtotal_gbp": Self.double(sub),
                    "max_cost_gbp": Self.double(m),
                ])
        }
        let resolution0 = prepared.resolution
        if let note = resolution0.note { notes.append(note) }
        let merged = GenerationPolicy.mergeReferences(
            project: candidates.project, explicit: candidates.explicit, maxReferences: resolution0.maxReferenceImages)
        if merged.truncated {
            notes.append("Truncated to first \(resolution0.maxReferenceImages) references (model limit)")
        }

        // --- 7. Generate (one image per loop) -----------------------------
        let service = GenerationService(
            database: database, libraryURL: libraryURL,
            provider: configured.first { $0.providerID == resolution0.provider } ?? configured[0],
            router: RouteExecutor(providers: configured, liveModels: live))
        let request = prepared.request(
            prompt: basePrompt, negativePrompt: negativePrompt,
            aspectRatio: shape.aspect, width: shape.width, height: shape.height, ratio: shape.exactRatio,
            references: merged.references, projectIDs: resolvedProjects.map(\.id),
            tags: (args["tags"] as? [String]) ?? [], variantFamilyName: args["variant_family"] as? String)

        var outcomes: [GenerationService.Outcome] = []
        var spent = 0.0
        let limit = Self.double(budget.maxCostGBP)
        for index in 0..<count {
            // T17: stop when what has actually been spent, plus the next image, would pass the cap.
            // The up-front gate priced the batch at the estimate; real costs can run higher, so the
            // next image is priced at the larger of the estimate and what the last one really cost.
            let next = max(Self.double(resolution0.estimateGBP),
                           outcomes.last.map { $0.actualCost ?? $0.estimatedCost } ?? 0)
            if index > 0 && spent + next > limit + 1e-9 {
                notes.append("Stopped after \(index) of \(count) images: spent \(Self.format(spent)) so far, and the next (about \(Self.format(next))) would pass max_cost_gbp \(Self.format(budget.maxCostGBP))")
                break
            }
            do {
                // A fallback or 404 retry inside this image is re-checked for the images still to make,
                // against the cap less what the batch has spent.
                let gate = GenerationPolicy.BudgetContext(
                    count: count - index, limits: budget, spentGBP: Decimal(spent))
                let outcome = try await service.generate(request.with(budget: gate))
                outcomes.append(outcome)
                spent += outcome.actualCost ?? outcome.estimatedCost
                for note in outcome.fallbackNotes where !notes.contains(note) { notes.append(note) }
            } catch where !outcomes.isEmpty {
                // Images already made are paid for and saved: report them rather than lose them.
                notes.append("Stopped after \(index) of \(count) images: \(error.localizedDescription)")
                break
            }
        }
        return Self.response(outcomes: outcomes, requested: count, prepared: prepared, notes: notes)
    }

    private static func response(
        outcomes: [GenerationService.Outcome], requested: Int, prepared: PreparedGeneration, notes: [String]
    ) -> [String: Any] {
        // What was actually served, not what the first route would have cost.
        let estimated = outcomes.reduce(0.0) { $0 + $1.estimatedCost }
        let actuals = outcomes.compactMap(\.actualCost)
        var served: [String] = []
        for outcome in outcomes where !served.contains(outcome.modelID) { served.append(outcome.modelID) }
        let last = outcomes[outcomes.count - 1]
        let route = prepared.routes.first { $0.provider == last.providerID && $0.model.id == last.modelID }
        var reasons: [String] = []
        if let note = prepared.resolution.note { reasons.append(note) }
        for note in last.fallbackNotes where !reasons.contains(note) { reasons.append(note) }
        let made = outcomes.count
        let reason: Any = reasons.isEmpty ? NSNull() : reasons.joined(separator: "; ")
        let actualTotal: Any = actuals.isEmpty ? NSNull() : actuals.reduce(0, +)
        let tier: Any = route?.tier ?? NSNull()

        return [
            "generated": outcomes.map { outcome -> [String: Any] in
                [
                    "asset_id": outcome.assetID,
                    "file_path": outcome.fileURL.path(percentEncoded: false),
                    "model_used": outcome.modelID,
                    "provider_used": outcome.providerID,
                    "media_type": outcome.mediaType,
                    "estimated_cost_gbp": outcome.estimatedCost,
                    "actual_cost_gbp": outcome.actualCost as Any? ?? NSNull(),
                    "seed": outcome.seed as Any? ?? NSNull(),
                ]
            },
            "resolved": [
                "provider": last.providerID,
                "model": last.modelID,
                "tier": tier,
                "reason": reason,
            ] as [String: Any],
            "cost": [
                "estimated_gbp": estimated,
                "actual_gbp": actualTotal,
                "actual_from_provider": !actuals.isEmpty,
            ] as [String: Any],
            "batch": ["requested": requested, "made": made, "stopped_early": made < requested] as [String: Any],
            "total_cost_gbp": estimated,
            "cost_breakdown": [
                "model": served.joined(separator: ", "),
                "count": made,
                "unit_cost_gbp": estimated / Double(made),
                "subtotal_gbp": estimated,
            ] as [String: Any],
            "notes": notes,
        ]
    }

    // MARK: - list_generation_options

    private func listOptions(_ args: [String: Any]) async throws -> [String: Any] {
        let includeAll = (args["include_all"] as? Bool) ?? false
        let configured = configuredProviders()
        let ids = Set(configured.map(\.providerID))
        if ids.contains(OpenRouterProvider.id) { await live.refreshIfNotLoaded() }
        let catalogue = catalogue()
        let models = live.snapshot()

        var media: [String: Any] = [:]
        for name in catalogue.media.keys.sorted() {
            var tiers: [String: Any] = [:]
            for tier in ModelResolver.tierNames where !catalogue.routes(media: name, tier: tier).isEmpty {
                do {
                    let routes = try ModelResolver.resolveAll(
                        ResolveRequest(media: name, quality: tier), catalogue: catalogue, providers: ids, live: models)
                    let first = routes[0]
                    tiers[tier] = [
                        "available": true,
                        "provider": first.provider,
                        "model": first.model.id,
                        "estimate_gbp": Self.double(first.estimateGBP),
                        "estimate_source": first.estimateSource.rawValue,
                        "capabilities": Catalogue.Capability.allCases.filter { first.model.supports($0) }.map(\.rawValue),
                        "max_reference_images": first.maxReferenceImages,
                        "fallbacks": routes.dropFirst().map { route -> [String: Any] in
                            ["provider": route.provider, "model": route.model.id, "estimate_gbp": Self.double(route.estimateGBP)]
                        },
                    ] as [String: Any]
                } catch {
                    tiers[tier] = ["available": false, "reason": error.localizedDescription] as [String: Any]
                }
            }
            media[name] = ["tiers": tiers] as [String: Any]
        }
        for name in ["video", "audio"] {
            media[name] = ["available": false, "note": "not yet supported"] as [String: Any]
        }

        var result: [String: Any] = [
            "providers": Self.providerRows.map { row -> [String: Any] in
                ["id": row.id, "name": row.name, "configured": ids.contains(row.id)]
            },
            "media": media,
            "capabilities": Catalogue.Capability.allCases.map(\.rawValue),
            "include_all": includeAll,
        ]
        if includeAll {
            result["models"] = ModelOptions.all(catalogue: catalogue, providers: ids, live: models).map { option -> [String: Any] in
                [
                    "model": option.reference,
                    "provider": option.provider,
                    "name": option.displayName,
                    "media": option.media,
                    "estimate_gbp": Self.double(option.estimateGBP),
                    "estimate_source": option.estimateSource.rawValue,
                    "capabilities": option.capabilities,
                    "max_reference_images": option.maxReferenceImages,
                    "aspect_ratios": option.aspectRatios,
                    "resolutions": option.imageSizes,
                ]
            }
        }
        return result
    }

    private static let providerRows: [(id: String, name: String)] = [
        (NanaBananaProvider.id, "Google (Gemini)"),
        (OpenRouterProvider.id, "OpenRouter"),
    ]

    // MARK: - References

    /// Gathers the candidate references. Merging and capping wait for the resolved
    /// model, whose `maxReferenceImages` sets the cap.
    private func resolveReferences(
        args: [String: Any],
        project: Project?
    ) async throws -> (project: [GenerationReference], explicit: [GenerationReference]) {
        var projectRefs: [GenerationReference] = []
        if let projectID = project?.id {
            let entries = try await database.fetchActiveReferenceEntries(projectID: projectID)
            for entry in entries {
                guard let asset = try await database.fetchAsset(id: entry.assetID) else { continue }
                let fileURL = libraryURL.appending(path: "assets").appending(path: asset.filename)
                guard let data = try? Data(contentsOf: fileURL) else { continue }
                let role: ReferenceRole = entry.role == "style_anchor" ? .styleAnchor : .subjectAnchor
                projectRefs.append(GenerationReference(
                    input: ReferenceInput(assetID: entry.assetID, imageData: data, role: role, weight: Float(entry.weight)),
                    referenceSetID: entry.referenceSetID,
                    referenceEntryID: entry.id
                ))
            }
        }

        var explicitRefs: [GenerationReference] = []
        if let list = args["references"] as? [[String: Any]] {
            for item in list {
                guard let assetID = item["asset_id"] as? String else { continue }
                guard let asset = try await database.fetchAsset(id: assetID) else {
                    throw MCPGenerateError.notFound("asset '\(assetID)' (in references)")
                }
                let fileURL = libraryURL.appending(path: "assets").appending(path: asset.filename)
                guard let data = try? Data(contentsOf: fileURL) else {
                    throw MCPGenerateError.notFound("file on disk for asset '\(assetID)'")
                }
                let role: ReferenceRole
                switch (item["role"] as? String)?.lowercased() {
                case "style_anchor":   role = .styleAnchor
                case "subject_anchor": role = .subjectAnchor
                default:               role = .subjectAnchor
                }
                explicitRefs.append(GenerationReference(
                    input: ReferenceInput(assetID: assetID, imageData: data, role: role, weight: nil),
                    referenceSetID: nil,
                    referenceEntryID: nil
                ))
            }
        }
        return (project: projectRefs, explicit: explicitRefs)
    }

    // MARK: - Helpers

    private static func decimalArg(_ any: Any?) -> Decimal? {
        switch any {
        case let d as Double:   return Decimal(d)
        case let i as Int:      return Decimal(i)
        case let n as NSNumber: return Decimal(n.doubleValue)
        case let s as String:   return Decimal(string: s)
        default: return nil
        }
    }

    private static func double(_ d: Decimal) -> Double { Double(truncating: d as NSDecimalNumber) }
    private static func format(_ d: Decimal) -> String { format(double(d)) }
    private static func format(_ d: Double) -> String { String(format: "£%.4f", d) }
}

/// `aspect_ratio` as the tool takes it: a name, or a ratio such as `4:3`.
struct AspectShape {
    let aspect: AspectRatio
    let width: Int
    let height: Int
    /// The ratio string the resolver checks against the model's own list.
    let ratio: String
    /// Set when the ratio is not one of the three the app names.
    let exactRatio: String?

    init(parsing raw: String) throws {
        switch raw.lowercased() {
        case "square", "1:1":    self.init(.square, 1024, 1024)
        case "landscape", "16:9": self.init(.landscape, 1792, 1024)
        case "portrait", "9:16":  self.init(.portrait, 1024, 1792)
        case let other:
            let parts = other.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, other.split(separator: ":").count == 2,
                  parts.allSatisfy({ $0 > 0 && $0 <= 99 }) else {
                throw MCPGenerateError.invalidParam(
                    "aspect_ratio '\(raw)' is not square, landscape, portrait or a ratio such as 4:3")
            }
            let (w, h) = (parts[0], parts[1])
            let size = w >= h ? (1024, max(1, 1024 * h / w)) : (max(1, 1024 * w / h), 1024)
            self.init(.custom, size.0, size.1, exact: "\(w):\(h)")
        }
    }

    private init(_ aspect: AspectRatio, _ width: Int, _ height: Int, exact: String? = nil) {
        self.aspect = aspect
        self.width = width
        self.height = height
        self.ratio = exact ?? aspect.rawValue
        self.exactRatio = exact
    }
}

public enum MCPGenerateError: Error, LocalizedError, @unchecked Sendable {
    case invalidParam(String)
    case notFound(String)
    case limitExceeded(String, details: [String: Any])

    public var errorDescription: String? {
        switch self {
        case .invalidParam(let msg):   return "Invalid parameter: \(msg)"
        case .notFound(let what):      return "Not found: \(what)"
        case .limitExceeded(let msg, _): return "Limit exceeded: \(msg)"
        }
    }
}
