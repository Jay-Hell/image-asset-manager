import Foundation

/// Which providers this install can use: compiled in, and a key present. The one decision the
/// panel and the MCP both call, so neither lists a model the other cannot reach.
public enum ProviderAvailability {

    /// Whether the Keychain holds an item. Never reads the value out of this function.
    public static func keychainHasKey(service: String, account: String) -> Bool {
        (try? KeychainService.retrieve(service: service, account: account)) != nil
    }

    /// The usable providers, Google first. `hasKey` and the provider builders are injectable so tests
    /// never touch the Keychain.
    public static func usable(
        hasKey: (_ service: String, _ account: String) -> Bool = ProviderAvailability.keychainHasKey,
        google: @autoclosure () -> any ImageProvider = NanaBananaProvider(),
        openRouter: @autoclosure () -> any ImageProvider = OpenRouterProvider()
    ) -> [any ImageProvider] {
        var usable: [any ImageProvider] = []
        if hasKey(NanaBananaProvider.keychainService, NanaBananaProvider.keychainAccount) { usable.append(google()) }
        if hasKey(OpenRouterProvider.keychainService, OpenRouterProvider.keychainAccount) { usable.append(openRouter()) }
        return usable
    }
}
