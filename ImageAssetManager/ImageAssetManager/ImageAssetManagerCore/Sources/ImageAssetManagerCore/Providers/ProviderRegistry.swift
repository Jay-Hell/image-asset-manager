import Foundation

public actor ProviderRegistry {
    public static let shared = ProviderRegistry()

    private var providers: [String: any ImageProvider] = [:]

    init() {}

    public func register(_ provider: some ImageProvider) {
        providers[provider.providerID] = provider
    }

    public func provider(for id: String) -> (any ImageProvider)? {
        providers[id]
    }

    public func allProviders() -> [any ImageProvider] {
        Array(providers.values)
    }
}
