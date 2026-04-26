import Foundation

public enum ProviderError: Error, Sendable {
    case apiKeyNotFound
    case invalidAPIKey
    case rateLimited
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
        case .generationFailed(let msg): return "Generation failed: \(msg)"
        case .networkError(let msg): return "Network error: \(msg)"
        case .invalidResponse:      return "Unexpected response from the provider API."
        }
    }
}
