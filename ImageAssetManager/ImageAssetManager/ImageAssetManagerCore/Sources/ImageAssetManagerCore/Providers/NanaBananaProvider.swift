import Foundation

public struct NanaBananaProvider: ImageProvider {
    public static let keychainService = "com.Ionic.ImageAssetManager"
    public static let keychainAccount = "nano_banana_api_key"

    private static let apiBase = "https://generativelanguage.googleapis.com/v1beta/models"

    // Model IDs exposed to the rest of the app. Bump these in one place when
    // Google deprecates (gemini-2.5-flash-image retires on 2026-10-02 in favour
    // of gemini-3.1-flash-image-preview).
    public enum ModelID {
        public static let imagenFast      = "imagen-4.0-fast-generate-001"
        public static let imagenStandard  = "imagen-4.0-generate-001"
        public static let imagenUltra     = "imagen-4.0-ultra-generate-001"
        public static let geminiWithRefs  = "gemini-2.5-flash-image"
    }

    public let providerID = "nano_banana"
    public let displayName = "Nano Banana"
    public let supportsReferenceImages = true
    public let maxReferenceImages = 3
    public let supportedReferenceRoles: [ReferenceRole] = [.styleAnchor, .subjectAnchor]

    // Source of truth for costs: Google's published USD prices per image, converted to GBP
    // via Currency.gbp(fromUSD:). The rest of the app stores and displays GBP throughout.
    public let availableModels: [ImageModel] = [
        ImageModel(id: ModelID.imagenFast,
                   displayName: "Fast — Draft",
                   supportedAspectRatios: [.square, .landscape, .portrait],
                   costPerImage: Currency.gbp(fromUSD: 0.02)),
        ImageModel(id: ModelID.imagenStandard,
                   displayName: "Standard",
                   supportedAspectRatios: [.square, .landscape, .portrait],
                   costPerImage: Currency.gbp(fromUSD: 0.04)),
        ImageModel(id: ModelID.imagenUltra,
                   displayName: "Pro — Final",
                   supportedAspectRatios: [.square, .landscape, .portrait],
                   costPerImage: Currency.gbp(fromUSD: 0.06)),
        ImageModel(id: ModelID.geminiWithRefs,
                   displayName: "With References",
                   supportedAspectRatios: [.square, .landscape, .portrait],
                   costPerImage: Currency.gbp(fromUSD: 0.039)),
    ]

    public let supportedAspectRatios: [AspectRatio] = [.square, .landscape, .portrait, .custom]

    public init() {}

    /// Only the Gemini model accepts reference images on this API; Imagen 4 tiers are text-only.
    public static func supportsReferences(modelID: String) -> Bool {
        modelID == ModelID.geminiWithRefs
    }

    public func estimateCost(_ params: GenerationParams) -> Decimal {
        params.model.costPerImage
    }

    public func generate(_ params: GenerationParams, references: [ReferenceInput]?) async throws -> GeneratedImage {
        try await generate(params, references: references, session: .shared)
    }

    func generate(_ params: GenerationParams, references: [ReferenceInput]?, session: URLSession) async throws -> GeneratedImage {
        let apiKey: String
        do {
            apiKey = try KeychainService.retrieve(service: Self.keychainService, account: Self.keychainAccount)
        } catch KeychainService.KeychainError.itemNotFound {
            throw ProviderError.apiKeyNotFound
        }

        if params.model.id == ModelID.geminiWithRefs {
            return try await generateGemini(params: params, references: references, apiKey: apiKey, session: session)
        } else {
            return try await generateImagen(params: params, apiKey: apiKey, session: session)
        }
    }

    // MARK: - Imagen 4 path (:predict)

    private func generateImagen(params: GenerationParams, apiKey: String, session: URLSession) async throws -> GeneratedImage {
        let endpoint = "\(Self.apiBase)/\(params.model.id):predict"
        let body = buildImagenRequest(params: params)
        let request = try buildURLRequest(endpoint: endpoint, apiKey: apiKey, body: body)
        let data = try await send(request, using: session)
        return try parseImagenResponse(data)
    }

    private func buildImagenRequest(params: GenerationParams) -> [String: Any] {
        var prompt = params.prompt
        if let neg = params.negativePrompt, !neg.isEmpty {
            prompt += "\n\nAvoid: \(neg)"
        }

        let instance: [String: Any] = ["prompt": prompt]

        var apiAspectRatio = params.aspectRatio.rawValue
        if params.aspectRatio == .custom {
            let ratio = Double(params.width) / Double(params.height)
            apiAspectRatio = ratio > 1.2 ? "16:9" : ratio < 0.8 ? "9:16" : "1:1"
        }

        // Ultra forces sampleCount = 1; we only ever request 1 anyway.
        return [
            "instances": [instance],
            "parameters": [
                "sampleCount": 1,
                "aspectRatio": apiAspectRatio,
            ] as [String: Any],
        ]
    }

    func parseImagenResponseForTesting(_ data: Data) throws -> GeneratedImage {
        try parseImagenResponse(data)
    }

    private func parseImagenResponse(_ data: Data) throws -> GeneratedImage {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let predictions = json["predictions"] as? [[String: Any]],
            let first = predictions.first,
            let b64 = first["bytesBase64Encoded"] as? String,
            let imageData = Data(base64Encoded: b64)
        else {
            throw ProviderError.invalidResponse
        }

        let mimeType = (first["mimeType"] as? String) ?? "image/jpeg"
        let format = mimeType.components(separatedBy: "/").last ?? "jpeg"
        return GeneratedImage(data: imageData, format: format)
    }

    // MARK: - Gemini path (:generateContent)

    private func generateGemini(params: GenerationParams, references: [ReferenceInput]?, apiKey: String, session: URLSession) async throws -> GeneratedImage {
        let endpoint = "\(Self.apiBase)/\(params.model.id):generateContent"
        let body = buildGeminiRequest(params: params, references: references)
        let request = try buildURLRequest(endpoint: endpoint, apiKey: apiKey, body: body)
        let data = try await send(request, using: session)
        return try parseGeminiResponse(data)
    }

    private func buildGeminiRequest(params: GenerationParams, references: [ReferenceInput]?) -> [String: Any] {
        var prompt = params.prompt
        if let neg = params.negativePrompt, !neg.isEmpty {
            prompt += "\n\nAvoid: \(neg)"
        }

        var parts: [[String: Any]] = [["text": prompt]]
        if let refs = references, !refs.isEmpty {
            for ref in refs.prefix(maxReferenceImages) {
                parts.append([
                    "inlineData": [
                        "mimeType": "image/png",
                        "data": ref.imageData.base64EncodedString(),
                    ],
                ])
            }
        }

        var apiAspectRatio = params.aspectRatio.rawValue
        if params.aspectRatio == .custom {
            let ratio = Double(params.width) / Double(params.height)
            apiAspectRatio = ratio > 1.2 ? "16:9" : ratio < 0.8 ? "9:16" : "1:1"
        }

        return [
            "contents": [[
                "role": "user",
                "parts": parts,
            ]],
            "generationConfig": [
                "responseModalities": ["IMAGE"],
                "imageConfig": ["aspectRatio": apiAspectRatio],
            ] as [String: Any],
        ]
    }

    func parseGeminiResponseForTesting(_ data: Data) throws -> GeneratedImage {
        try parseGeminiResponse(data)
    }

    private func parseGeminiResponse(_ data: Data) throws -> GeneratedImage {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else {
            throw ProviderError.invalidResponse
        }

        for part in parts {
            if let inline = part["inlineData"] as? [String: Any] ?? part["inline_data"] as? [String: Any],
               let b64 = inline["data"] as? String,
               let imageData = Data(base64Encoded: b64) {
                let mimeType = (inline["mimeType"] as? String)
                    ?? (inline["mime_type"] as? String)
                    ?? "image/png"
                let format = mimeType.components(separatedBy: "/").last ?? "png"
                return GeneratedImage(data: imageData, format: format)
            }
        }

        throw ProviderError.invalidResponse
    }

    // MARK: - Shared HTTP

    private func buildURLRequest(endpoint: String, apiKey: String, body: [String: Any]) throws -> URLRequest {
        guard let url = URL(string: endpoint) else {
            throw ProviderError.generationFailed("Invalid endpoint URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func send(_ request: URLRequest, using session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            return data
        case 400, 401, 403:
            throw ProviderError.invalidAPIKey
        case 429:
            throw ProviderError.rateLimited
        default:
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw ProviderError.generationFailed(message)
        }
    }
}
