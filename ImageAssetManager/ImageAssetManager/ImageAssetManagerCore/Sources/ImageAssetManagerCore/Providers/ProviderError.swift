import Foundation

public enum ProviderError: Error, Sendable {
    case apiKeyNotFound
    case invalidAPIKey
    case rateLimited
    /// The provider answered 404 for the model: retired or renamed.
    case modelUnavailable(String)
    /// The provider answered 400. The message is the provider's own.
    case badRequest(String)
    /// OpenRouter answered 402: the account is out of credit.
    case outOfCredit
    case generationFailed(String)
    case networkError(String)
    case invalidResponse
}

extension ProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .apiKeyNotFound:       return "API key not found in Keychain. Please add your key in Settings."
        case .invalidAPIKey:        return "API key was rejected. Please check your key in Settings."
        case .rateLimited:          return "Rate limit reached. Please wait before generating again."
        case .modelUnavailable(let id): return "The model \(id) is no longer available. The app is checking for a model update; try again in a moment."
        case .outOfCredit:          return "The provider account is out of credit. Add credit and try again."
        case .badRequest(let msg): return "The provider rejected the request: \(msg)"
        case .generationFailed(let msg): return "Generation failed: \(msg)"
        case .networkError(let msg): return "Network error: \(msg)"
        case .invalidResponse:      return "Unexpected response from the provider API."
        }
    }
}
