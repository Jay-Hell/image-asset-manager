import Foundation

/// Google Gemini direct. The provider ID `nano_banana` is stored on existing assets
/// and projects, so it stays; the user sees "Google Gemini".
///
/// Every model is a catalogue entry (`CatalogueStore`): its ID goes in the URL path,
/// its `body` is merged under the app-owned fields, and its reference cap, sizes and
/// aspect ratios come from the entry. There are no model IDs in this file.
public struct NanaBananaProvider: ImageProvider {
    public static let keychainService = "com.Ionic.ImageAssetManager"
    public static let keychainAccount = "nano_banana_api_key"
    public static let id = "nano_banana"

    private static let apiBase = "https://generativelanguage.googleapis.com/v1beta/models"

    public let providerID = NanaBananaProvider.id
    public let displayName = "Google Gemini"
    public let supportsReferenceImages = true
    public let supportedReferenceRoles: [ReferenceRole] = [.styleAnchor, .subjectAnchor]
    public let supportedAspectRatios: [AspectRatio] = [.square, .landscape, .portrait, .custom]

    private let catalogue: CatalogueStore
    private let apiKeyLookup: @Sendable () throws -> String

    /// `apiKey` defaults to the Keychain; tests inject their own so they never touch the real key.
    public init(
        catalogue: CatalogueStore = .shared,
        apiKey: @escaping @Sendable () throws -> String = {
            try KeychainService.retrieve(service: NanaBananaProvider.keychainService, account: NanaBananaProvider.keychainAccount)
        }
    ) {
        self.catalogue = catalogue
        self.apiKeyLookup = apiKey
    }

    // MARK: - Models (from the catalogue)

    /// Tier models first (fast, standard, pro), then the rest, each priced as the resolver prices it.
    public var availableModels: [ImageModel] {
        let snapshot = catalogue.snapshot()
        var ordered: [String] = []
        for tier in ["fast", "standard", "pro"] {
            for route in snapshot.routes(media: "image", tier: tier)
            where route.provider == providerID && !ordered.contains(route.model) {
                ordered.append(route.model)
            }
        }
        for model in snapshot.models[providerID] ?? [] where !ordered.contains(model.id) {
            ordered.append(model.id)
        }
        return ordered.compactMap { id in
            try? ModelResolver.resolveSelection(
                provider: providerID, modelID: id, referenceCount: 0, aspectRatio: "1:1",
                catalogue: snapshot, providers: [providerID]
            ).imageModel
        }
    }

    /// The largest reference cap of any model; the per-model cap is what a request obeys.
    public var maxReferenceImages: Int {
        (catalogue.snapshot().models[providerID] ?? []).map(\.maxReferenceImages).max() ?? 0
    }

    public func estimateCost(_ params: GenerationParams) -> Decimal {
        params.model.costPerImage
    }

    // MARK: - Generate

    public func generate(_ params: GenerationParams, references: [ReferenceInput]?) async throws -> GeneratedImage {
        try await generate(params, references: references, session: .shared)
    }

    func generate(_ params: GenerationParams, references: [ReferenceInput]?, session: URLSession) async throws -> GeneratedImage {
        let apiKey: String
        do {
            apiKey = try apiKeyLookup()
        } catch KeychainService.KeychainError.itemNotFound {
            throw ProviderError.apiKeyNotFound
        }

        let first = try reresolve(params, references: references, force: false)
        do {
            return try await attempt(first, references: references, apiKey: apiKey, session: session)
        } catch ProviderError.modelUnavailable {
            // Spec v0.1 §4.4: a 404 forces one catalogue refresh and one retry. The retry
            // is built from the request again, not from the old resolution: the new model's
            // size and price, and the budget re-checked, before anything is sent.
            await catalogue.refreshAfterModelUnavailable()
            let second = try reresolve(params, references: references, force: true)
            return try await attempt(second, references: references, apiKey: apiKey, session: session)
        }
    }

    /// The params to send, and whether they differ from the caller's (a different model,
    /// size or price). Unless `force`, a model the catalogue still lists is left alone; a model
    /// retired since the request was built, or one that just 404ed, is resolved again from the
    /// request's own inputs, and the new price is checked against the budget the call was gated on.
    private func reresolve(_ params: GenerationParams, references: [ReferenceInput]?, force: Bool) throws -> (params: GenerationParams, changed: Bool) {
        let snapshot = catalogue.snapshot()
        if !force && snapshot.model(provider: providerID, id: params.model.id) != nil {
            return (params, false)
        }
        let resolution: Resolution
        do {
            resolution = try ModelResolver.resolveSelection(
                provider: providerID, modelID: params.model.id, referenceCount: references?.count ?? 0,
                aspectRatio: params.apiRatio,
                catalogue: snapshot, providers: [providerID]
            )
        } catch {
            throw ProviderError.modelUnavailable(params.model.id)
        }
        let model = resolution.imageModel
        let changed = model.id != params.model.id || model.imageSize != params.model.imageSize
            || model.costPerImage != params.model.costPerImage
        if changed, let budget = params.budget {
            _ = try GenerationPolicy.checkBudget(count: budget.count, unitCost: model.costPerImage, limits: budget.remainingLimits)
        }
        let next = GenerationParams(
            prompt: params.prompt, negativePrompt: params.negativePrompt, model: model,
            aspectRatio: params.aspectRatio, width: params.width, height: params.height,
            seed: params.seed, additionalParams: params.additionalParams, budget: params.budget,
            ratio: params.ratio
        )
        return (next, changed)
    }

    private func attempt(_ resolved: (params: GenerationParams, changed: Bool), references: [ReferenceInput]?, apiKey: String, session: URLSession) async throws -> GeneratedImage {
        let params = resolved.params
        let snapshot = catalogue.snapshot()
        guard let entry = snapshot.model(provider: providerID, id: params.model.id) else {
            throw ProviderError.modelUnavailable(params.model.id)
        }

        let request = try Self.urlRequest(entry: entry, params: params, references: references, apiKey: apiKey)
        let data = try await send(request, modelID: entry.id, apiKey: apiKey, using: session)
        let image = try Self.parseResponse(data, usdToGBP: snapshot.fx)
        guard resolved.changed else { return image }
        return GeneratedImage(
            data: image.data, format: image.format, actualCost: image.actualCost, seed: image.seed,
            rawResponse: image.rawResponse, modelUsed: entry.id, estimatedCostGBP: params.model.costPerImage
        )
    }

    // MARK: - Request

    /// The request that leaves the process. Internal so tests assert on it directly.
    static func urlRequest(entry: Catalogue.Model, params: GenerationParams, references: [ReferenceInput]?, apiKey: String) throws -> URLRequest {
        // The ID goes into a URL path: whatever built the entry, only a valid ID reaches it.
        guard Catalogue.isValidModelID(entry.id, allowSlash: false),
              let url = URL(string: "\(apiBase)/\(entry.id):generateContent") else {
            throw ProviderError.generationFailed("Invalid endpoint URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body(entry: entry, params: params, references: references))
        return req
    }

    /// Catalogue `body` first, then the fields the app owns on top: they cannot be overridden.
    static func body(entry: Catalogue.Model, params: GenerationParams, references: [ReferenceInput]?) -> [String: Any] {
        var prompt = params.prompt
        if let neg = params.negativePrompt, !neg.isEmpty {
            prompt += "\n\nAvoid: \(neg)"
        }

        var parts: [[String: Any]] = [["text": prompt]]
        for ref in (references ?? []).prefix(entry.maxReferenceImages) {
            parts.append([
                "inlineData": [
                    // Labelled by what the bytes are; PNG only for bytes no sniff recognises.
                    "mimeType": MediaType(sniffing: ref.imageData)?.rawValue ?? "image/png",
                    "data": ref.imageData.base64EncodedString(),
                ],
            ])
        }

        var imageConfig: [String: Any] = [
            "aspectRatio": params.apiRatio,
        ]
        if let size = params.model.imageSize { imageConfig["imageSize"] = size }

        let appOwned: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "responseModalities": ["IMAGE"],
                "imageConfig": imageConfig,
            ] as [String: Any],
        ]
        let defaults = entry.body.mapValues(\.anyValue)
        return JSONValue.merged(defaults, with: appOwned)
    }

    // MARK: - Response

    static func parseResponse(_ data: Data, usdToGBP: Decimal) throws -> GeneratedImage {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else {
            throw ProviderError.invalidResponse
        }

        for part in parts where (part["thought"] as? Bool) != true {
            if let inline = part["inlineData"] as? [String: Any] ?? part["inline_data"] as? [String: Any],
               let b64 = inline["data"] as? String,
               let imageData = Data(base64Encoded: b64) {
                let mimeType = (inline["mimeType"] as? String)
                    ?? (inline["mime_type"] as? String)
                    ?? "image/png"
                let format = mimeType.components(separatedBy: "/").last ?? "png"
                return GeneratedImage(
                    data: imageData,
                    format: format,
                    actualCost: cost(in: json, usdToGBP: usdToGBP),
                    seed: seed(in: json, candidate: first),
                    rawResponse: [:]
                )
            }
        }

        throw ProviderError.invalidResponse
    }

    /// A seed, if the response carries one (top level or on the candidate).
    private static func seed(in json: [String: Any], candidate: [String: Any]) -> String? {
        for source in [json, candidate] {
            if let n = source["seed"] as? NSNumber { return n.stringValue }
            if let s = source["seed"] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    /// A cost, if the response carries one (`usage.cost` or `cost`, in USD), converted to GBP.
    /// Google's direct API sends none today; this is here so a change is picked up, not guessed at.
    private static func cost(in json: [String: Any], usdToGBP: Decimal) -> Decimal? {
        let raw = ((json["usage"] as? [String: Any])?["cost"] as? NSNumber) ?? (json["cost"] as? NSNumber)
        guard let raw, raw.doubleValue > 0 else { return nil }
        return Catalogue.decimal(raw.doubleValue) * usdToGBP
    }

    // MARK: - HTTP

    private func send(_ request: URLRequest, modelID: String, apiKey: String, using session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            return data
        case 401, 403:
            throw ProviderError.invalidAPIKey
        case 404:
            throw ProviderError.modelUnavailable(modelID)
        case 429:
            throw ProviderError.rateLimited
        case 400:
            // Google also answers 400 for a malformed key; its own message says which.
            throw ProviderError.badRequest(Self.providerMessage(data, apiKey: apiKey) ?? "HTTP 400")
        default:
            throw ProviderError.generationFailed(Self.providerMessage(data, apiKey: apiKey) ?? "HTTP \(http.statusCode)")
        }
    }

    private static func providerMessage(_ data: Data, apiKey: String) -> String? {
        ProviderMessage.text(from: data, redacting: [apiKey])
    }
}
