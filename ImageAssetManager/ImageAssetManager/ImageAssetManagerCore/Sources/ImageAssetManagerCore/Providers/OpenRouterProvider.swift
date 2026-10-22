import Foundation

/// OpenRouter, request shape `openrouter.images` (spec v0.3 §5.1).
///
/// The model ID goes in the body, never the URL. What a request may carry is decided by the
/// model's live record (`OpenRouterModelStore`): `aspect_ratio`, `resolution`, `n`,
/// `output_format` and input references, each only if the record lists it, and a value the
/// record does not list is rejected with the list, never changed. References go as base64.
/// The host is compiled in.
public struct OpenRouterProvider: ImageProvider {
    public static let keychainService = NanaBananaProvider.keychainService
    public static let keychainAccount = "openrouter_api_key"
    public static let id = "openrouter"

    static let imagesURL = URL(string: "\(OpenRouterModelStore.apiBase)/images")!

    public let providerID = OpenRouterProvider.id
    public let displayName = "OpenRouter"
    public let supportsReferenceImages = true
    public let supportedReferenceRoles: [ReferenceRole] = [.styleAnchor, .subjectAnchor]
    public let supportedAspectRatios: [AspectRatio] = [.square, .landscape, .portrait, .custom]

    private let catalogue: CatalogueStore
    private let live: OpenRouterModelStore
    private let apiKeyLookup: @Sendable () throws -> String

    /// `apiKey` defaults to the Keychain; tests inject their own so they never touch the real key.
    public init(
        catalogue: CatalogueStore = .shared,
        live: OpenRouterModelStore = .shared,
        apiKey: @escaping @Sendable () throws -> String = {
            try KeychainService.retrieve(service: OpenRouterProvider.keychainService, account: OpenRouterProvider.keychainAccount)
        }
    ) {
        self.catalogue = catalogue
        self.live = live
        self.apiKeyLookup = apiKey
    }

    /// Whether a key is stored. Providers without one are not offered.
    public static func hasKey() -> Bool {
        (try? KeychainService.retrieve(service: keychainService, account: keychainAccount)) != nil
    }

    // MARK: - Models

    /// The image tiers' OpenRouter models that are in the live list, tier order, then catalogue-listed ones.
    public var availableModels: [ImageModel] {
        let snapshot = catalogue.snapshot()
        let models = live.snapshot()
        var ordered: [String] = []
        for tier in ["fast", "standard", "pro"] {
            for route in snapshot.routes(media: "image", tier: tier)
            where route.provider == providerID && !ordered.contains(route.model) {
                ordered.append(route.model)
            }
        }
        for model in snapshot.models[providerID] ?? [] where !ordered.contains(model.id) { ordered.append(model.id) }
        return ordered.compactMap { id in
            try? ModelResolver.resolveSelection(
                provider: providerID, modelID: id, referenceCount: 0, aspectRatio: "1:1",
                catalogue: snapshot, providers: [providerID], live: models
            ).imageModel
        }
    }

    public var maxReferenceImages: Int {
        live.snapshot().models.compactMap { $0.maxOf("input_references") }.max() ?? 0
    }

    public func estimateCost(_ params: GenerationParams) -> Decimal { params.model.costPerImage }

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
        guard let record = live.snapshot().model(params.model.id) else {
            throw ProviderError.modelUnavailable(params.model.id)
        }
        let request = try Self.urlRequest(record: record, params: params, references: references, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw ProviderError.invalidAPIKey
        case 402:
            throw ProviderError.outOfCredit
        case 404:
            throw ProviderError.modelUnavailable(params.model.id)
        case 429:
            throw ProviderError.rateLimited
        case 400:
            throw ProviderError.badRequest(Self.providerMessage(data, apiKey: apiKey) ?? "HTTP 400")
        default:
            throw ProviderError.generationFailed(Self.providerMessage(data, apiKey: apiKey) ?? "HTTP \(http.statusCode)")
        }
        let fx = catalogue.snapshot().fx
        let image: GeneratedImage
        do {
            image = try Self.parseResponse(data, usdToGBP: fx)
        } catch ProviderError.invalidResponse {
            // A 200 that carries a cost but no image is still a charge: say so, so it is recorded.
            if let usd = Self.costUSD(in: data) {
                throw ProviderError.chargedNoImage(provider: providerID, model: params.model.id, costGBP: usd * fx)
            }
            throw ProviderError.invalidResponse
        }
        if let usd = Self.costUSD(in: data) { live.recordObservedCost(usd: usd, for: params.model.id, size: params.model.imageSize) }
        return image
    }

    // MARK: - Request

    /// The request that leaves the process. Internal so tests assert on it directly.
    static func urlRequest(record: OpenRouterModel, params: GenerationParams, references: [ReferenceInput]?, apiKey: String) throws -> URLRequest {
        // The ID goes into the body; it is also checked here so nothing odd is ever sent.
        guard Catalogue.isValidModelID(record.id, allowSlash: true) else {
            throw ProviderError.generationFailed("Invalid model ID")
        }
        var req = URLRequest(url: imagesURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: try body(record: record, params: params, references: references))
        return req
    }

    /// App-owned fields only. Each optional parameter is sent only if the model's record lists it;
    /// a value outside the listed values is an error carrying the list. The catalogue's body
    /// defaults are not merged: the resolver has already applied them to `params`.
    static func body(record: OpenRouterModel, params: GenerationParams, references: [ReferenceInput]?) throws -> [String: Any] {
        var prompt = params.prompt
        if let neg = params.negativePrompt, !neg.isEmpty { prompt += "\n\nAvoid: \(neg)" }

        var body: [String: Any] = ["model": record.id, "prompt": prompt]

        let ratios = record.values(of: "aspect_ratio")
        if !ratios.isEmpty {
            let ratio = params.apiRatio
            guard ratios.contains(ratio) else {
                throw ResolveError.unsupportedAspectRatio(requested: ratio, supported: ratios)
            }
            body["aspect_ratio"] = ratio
        }
        if let size = params.model.imageSize {
            let sizes = record.values(of: "resolution")
            if !sizes.isEmpty {
                guard sizes.contains(size) else { throw ResolveError.unsupportedResolution(requested: size, supported: sizes) }
                body["resolution"] = size
            }
        }
        if record.parameters["n"] != nil { body["n"] = 1 }
        if let format = params.outputFormat {
            let formats = record.values(of: "output_format")
            guard formats.contains(format) else { throw ResolveError.unsupportedOutputFormat(requested: format, supported: formats) }
            body["output_format"] = format
        }
        if let refs = references, !refs.isEmpty {
            let cap = record.maxOf("input_references") ?? 0
            guard cap > 0 else { throw ProviderError.badRequest("\(record.id) takes no reference images") }
            // Base64 data URLs, never https URLs (spec §5.9). Item shape is OpenRouter's published
            // one: {"type":"image_url","image_url":{"url":"data:<mime>;base64,<data>"}}.
            body["input_references"] = refs.prefix(cap).map { ref -> [String: Any] in
                let mime = MediaType(sniffing: ref.imageData)?.rawValue ?? "image/png"
                return ["type": "image_url",
                        "image_url": ["url": "data:\(mime);base64,\(ref.imageData.base64EncodedString())"]]
            }
        }
        return body
    }

    // MARK: - Response

    /// `data[0].b64_json` (or `base64`), its `media_type` if given (else sniffed), and `usage.cost` in USD.
    static func parseResponse(_ data: Data, usdToGBP: Decimal) throws -> GeneratedImage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { throw ProviderError.invalidResponse }
        for item in items {
            guard let b64 = (item["b64_json"] as? String) ?? (item["base64"] as? String),
                  let bytes = Data(base64Encoded: b64) else { continue }
            let declared = (item["media_type"] as? String) ?? (item["mime_type"] as? String) ?? (json["media_type"] as? String)
            let mime = declared ?? MediaType(sniffing: bytes)?.rawValue ?? "image/png"
            let ext = MediaType(mimeType: mime)?.fileExtension ?? "png"
            let actual = costUSD(in: data).map { $0 * usdToGBP }
            return GeneratedImage(
                data: bytes, format: ext, actualCost: actual,
                seed: (item["seed"] as? NSNumber)?.stringValue, rawResponse: [:], mimeType: mime
            )
        }
        throw ProviderError.invalidResponse
    }

    static func costUSD(in data: Data) -> Decimal? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = (json["usage"] as? [String: Any])?["cost"] as? NSNumber, raw.doubleValue > 0 else { return nil }
        return Catalogue.decimal(raw.doubleValue)
    }

    private static func providerMessage(_ data: Data, apiKey: String) -> String? {
        ProviderMessage.text(from: data, redacting: [apiKey])
    }
}

/// `GET /api/v1/key`: what the Settings "Test key" button shows. Never the key.
public struct OpenRouterKeyInfo: Sendable, Equatable {
    public let label: String
    /// Remaining spend limit in USD; nil when the key has no limit.
    public let limitRemaining: Double?

    public var summary: String {
        let remaining = limitRemaining.map { String(format: "$%.2f remaining", $0) } ?? "no spend limit"
        return "\(label.isEmpty ? "Key accepted" : label): \(remaining)"
    }

    public static func check(apiKey: String, session: URLSession = .shared) async throws -> OpenRouterKeyInfo {
        var request = URLRequest(url: URL(string: "\(OpenRouterModelStore.apiBase)/key")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw ProviderError.invalidAPIKey
        case 429: throw ProviderError.rateLimited
        default: throw ProviderError.generationFailed("HTTP \(http.statusCode)")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ProviderError.invalidResponse }
        let body = (json["data"] as? [String: Any]) ?? json
        return OpenRouterKeyInfo(
            label: (body["label"] as? String) ?? "",
            limitRemaining: (body["limit_remaining"] as? NSNumber)?.doubleValue
        )
    }
}
