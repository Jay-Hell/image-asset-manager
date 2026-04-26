import Foundation

public protocol AnthropicClientProtocol: Sendable {
    func complete(
        system: String,
        messages: [[String: String]],
        model: String,
        maxTokens: Int,
        temperature: Double
    ) async throws -> String
}

public actor AnthropicClient: AnthropicClientProtocol {
    public static let defaultModel = "claude-sonnet-4-5"

    private static let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let keychainService = "com.yourapp.imageassetmanager"
    private static let keychainAccount = "anthropic_api_key"

    public init() {}

    public func complete(
        system: String,
        messages: [[String: String]],
        model: String = AnthropicClient.defaultModel,
        maxTokens: Int = 1024,
        temperature: Double = 0.7
    ) async throws -> String {
        let apiKey: String
        do {
            apiKey = try KeychainService.retrieve(
                service: AnthropicClient.keychainService,
                account: AnthropicClient.keychainAccount
            )
        } catch {
            throw AnthropicError.missingAPIKey
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "system": system,
            "messages": messages.map { ["role": $0["role"] ?? "user", "content": $0["content"] ?? ""] }
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: AnthropicClient.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AnthropicError.apiError(statusCode: httpResponse.statusCode, message: message)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = (json?["content"] as? [[String: Any]])?.first,
              let text = content["text"] as? String else {
            throw AnthropicError.malformedResponse
        }
        return text
    }
}

public enum AnthropicError: Error, LocalizedError, Sendable {
    case missingAPIKey
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case malformedResponse

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
        }
    }
}
