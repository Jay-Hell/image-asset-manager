import Foundation

/// What a refinement call returned. `model` is the response's own `model` field, which
/// names the fallback model when Anthropic's server-side fallback served the request.
public struct AnthropicCompletion: Sendable, Equatable {
    public let text: String
    public let model: String

    public init(text: String, model: String) {
        self.text = text
        self.model = model
    }
}

public protocol AnthropicClientProtocol: Sendable {
    func complete(
        system: String,
        messages: [[String: String]]
    ) async throws -> AnthropicCompletion
}

/// Prompt refinement over raw HTTP. Model, headers and body come from the catalogue's
/// `refinement` entry (spec v0.3 §5.10); the app owns `model`, `system` and `messages`.
public actor AnthropicClient: AnthropicClientProtocol {
    /// Compiled, not catalogue-driven (spec v0.3 §5.10).
    public static let apiVersion = "2026-10-21"
    /// Sampling parameters the API rejects on current models. Never sent, whatever the catalogue says.
    static let forbiddenBodyKeys: Set<String> = ["temperature", "top_p", "top_k"]
    static let fallbackMaxTokens = 4096

    private static let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let keychainService = "com.yourapp.imageassetmanager"
    public static let keychainAccount = "anthropic_api_key"

    private let catalogue: CatalogueStore
    private let session: URLSession
    private let apiKeyLookup: @Sendable () throws -> String

    public init(
        catalogue: CatalogueStore = .shared,
        session: URLSession = .shared,
        apiKey: @escaping @Sendable () throws -> String = {
            try KeychainService.retrieve(service: AnthropicClient.keychainService, account: AnthropicClient.keychainAccount)
        }
    ) {
        self.catalogue = catalogue
        self.session = session
        self.apiKeyLookup = apiKey
    }

    public func complete(system: String, messages: [[String: String]]) async throws -> AnthropicCompletion {
        let apiKey: String
        do {
            apiKey = try apiKeyLookup()
        } catch {
            throw AnthropicError.missingAPIKey
        }

        do {
            return try await attempt(system: system, messages: messages, apiKey: apiKey)
        } catch AnthropicError.modelUnavailable {
            // Spec v0.1 §4.4: one forced refresh and one retry.
            await catalogue.refreshAfterModelUnavailable()
            return try await attempt(system: system, messages: messages, apiKey: apiKey)
        }
    }

    private func attempt(system: String, messages: [[String: String]], apiKey: String) async throws -> AnthropicCompletion {
        guard let refinement = catalogue.refinement() else {
            throw AnthropicError.refinementUnavailable
        }
        let request = try Self.urlRequest(refinement: refinement, apiKey: apiKey, system: system, messages: messages)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 404 { throw AnthropicError.modelUnavailable(refinement.model) }
            let message = ProviderMessage.text(from: data, redacting: [apiKey]) ?? "Unknown error"
            throw AnthropicError.apiError(statusCode: http.statusCode, message: message)
        }
        return try Self.parse(data, requestedModel: refinement.model)
    }

    // MARK: - Request

    /// The request that leaves the process. Internal so tests assert on it directly.
    static func urlRequest(
        refinement: Catalogue.Refinement,
        apiKey: String,
        system: String,
        messages: [[String: String]]
    ) throws -> URLRequest {
        guard Catalogue.isValidModelID(refinement.model, allowSlash: false) else {
            throw AnthropicError.refinementUnavailable
        }
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        // Allow-listed catalogue headers first; the compiled version is written last and wins.
        for (name, value) in refinement.headers where Catalogue.allowedHeaders.contains(name.lowercased()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        var defaults = refinement.body.mapValues(\.anyValue)
        for key in forbiddenBodyKeys { defaults[key] = nil }
        if defaults["max_tokens"] == nil { defaults["max_tokens"] = fallbackMaxTokens }

        let appOwned: [String: Any] = [
            "model": refinement.model,
            "system": system,
            "messages": messages.map { ["role": $0["role"] ?? "user", "content": $0["content"] ?? ""] },
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: JSONValue.merged(defaults, with: appOwned))
        return request
    }

    // MARK: - Response

    /// `stop_reason` first (a refusal or a cut-off has its own message), then the first
    /// block of type `text`. Thinking blocks come first by default and are skipped.
    static func parse(_ data: Data, requestedModel: String) throws -> AnthropicCompletion {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AnthropicError.malformedResponse
        }
        switch json["stop_reason"] as? String {
        case "refusal":
            let category = (json["stop_details"] as? [String: Any])?["category"] as? String
            throw AnthropicError.refused(category: category)
        case "max_tokens":
            throw AnthropicError.truncated
        default:
            break
        }
        guard let blocks = json["content"] as? [[String: Any]],
              let text = blocks.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String else {
            throw AnthropicError.malformedResponse
        }
        return AnthropicCompletion(text: text, model: (json["model"] as? String) ?? requestedModel)
    }
}

public enum AnthropicError: Error, LocalizedError, Sendable, Equatable {
    case missingAPIKey
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case malformedResponse
    case modelUnavailable(String)
    case refused(category: String?)
    case truncated
    case refinementUnavailable

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Anthropic API key not configured. Add it in Settings."
        case .invalidResponse:
            return "Invalid response from Anthropic API."
        case .apiError(let code, let msg):
            return "Anthropic API error \(code): \(msg)"
        case .malformedResponse:
            return "Unexpected response format from Anthropic API."
        case .modelUnavailable(let model):
            return "The refinement model \(model) is no longer available. The app is checking for a model update; try again in a moment."
        case .refused(let category):
            let why = category.map { " (\($0))" } ?? ""
            return "Claude declined to refine this prompt\(why). Try rewording it."
        case .truncated:
            return "Claude's reply was cut off before it finished. Try a shorter prompt."
        case .refinementUnavailable:
            return "No prompt refinement settings are available in the model catalogue."
        }
    }
}
