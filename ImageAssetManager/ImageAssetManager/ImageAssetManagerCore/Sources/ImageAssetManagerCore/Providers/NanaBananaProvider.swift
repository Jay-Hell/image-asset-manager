import Foundation

public struct NanaBananaProvider: ImageProvider {
    static let keychainService = "com.Ionic.ImageAssetManager"
    static let keychainAccount = "nano_banana_api_key"

    private static let apiEndpoint = "https://generativelanguage.googleapis.com/v1beta/models/imagen-3.0-generate-002:predict"

    public let providerID = "nano_banana"
    public let displayName = "Nano Banana"
    public let supportsReferenceImages = true
    public let maxReferenceImages = 3
    public let supportedReferenceRoles: [ReferenceRole] = [.styleAnchor, .subjectAnchor]

    public let availableModels: [ImageModel] = [
        ImageModel(
            id: "nano-banana-v1",
            displayName: "Nano Banana v1",
            supportedAspectRatios: [.square, .landscape, .portrait],
            costPerImage: 0.04
        )
    ]

    public let supportedAspectRatios: [AspectRatio] = [.square, .landscape, .portrait, .custom]

    public init() {}

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

        let requestBody = buildRequest(params: params, references: references)
        let request = try buildURLRequest(apiKey: apiKey, body: requestBody)
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            return try parseResponse(data)
        case 400, 401, 403:
            throw ProviderError.invalidAPIKey
        case 429:
            throw ProviderError.rateLimited
        default:
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw ProviderError.generationFailed(message)
        }
    }

    // MARK: - Request building

    private func buildRequest(params: GenerationParams, references: [ReferenceInput]?) -> [String: Any] {
        var instance: [String: Any] = ["prompt": params.prompt]
        if let neg = params.negativePrompt { instance["negativePrompt"] = neg }
        if let seed = params.seed, let seedInt = Int(seed) { instance["seed"] = seedInt }

        if let refs = references, !refs.isEmpty {
            instance["referenceImages"] = refs.enumerated().map { idx, ref in
                [
                    "referenceType": ref.role == .styleAnchor ? 1 : 3,
                    "referenceId": idx + 1,
                    "referenceImage": ["bytesBase64Encoded": ref.imageData.base64EncodedString()],
                ] as [String: Any]
            }
        }

        var apiAspectRatio = params.aspectRatio.rawValue
        if params.aspectRatio == .custom {
            // Imagen 3 does not accept arbitrary dimensions; map to closest supported ratio.
            let ratio = Double(params.width) / Double(params.height)
            apiAspectRatio = ratio > 1.2 ? "16:9" : ratio < 0.8 ? "9:16" : "1:1"
        }

        return [
            "instances": [instance],
            "parameters": [
                "sampleCount": 1,
                "aspectRatio": apiAspectRatio,
            ] as [String: Any],
        ]
    }

    private func buildURLRequest(apiKey: String, body: [String: Any]) throws -> URLRequest {
        guard let url = URL(string: Self.apiEndpoint) else {
            throw ProviderError.generationFailed("Invalid endpoint URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - Response parsing

    func parseResponseForTesting(_ data: Data) throws -> GeneratedImage {
        try parseResponse(data)
    }

    private func parseResponse(_ data: Data) throws -> GeneratedImage {
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
}
