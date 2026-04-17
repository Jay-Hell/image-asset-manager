import Testing
import Foundation
@testable import ImageAssetManagerCore

private struct MockProvider: ImageProvider {
    let providerID: String
    let displayName: String
    let availableModels: [ImageModel] = []
    let supportedAspectRatios: [AspectRatio] = AspectRatio.allCases
    let supportsReferenceImages = false
    let maxReferenceImages = 0
    let supportedReferenceRoles: [ReferenceRole] = []

    func estimateCost(_ params: GenerationParams) -> Decimal { 0 }
    func generate(_ params: GenerationParams, references: [ReferenceInput]?) async throws -> GeneratedImage {
        GeneratedImage(data: Data(), format: "png")
    }
}

@Suite("ProviderRegistry")
struct ProviderRegistryTests {
    @Test func registerAndRetrieve() async {
        let registry = ProviderRegistry()
        let provider = MockProvider(providerID: "mock", displayName: "Mock")
        await registry.register(provider)
        let retrieved = await registry.provider(for: "mock")
        #expect(retrieved?.providerID == "mock")
    }

    @Test func missingProviderReturnsNil() async {
        let registry = ProviderRegistry()
        let result = await registry.provider(for: "nonexistent")
        #expect(result == nil)
    }

    @Test func allProvidersListsRegistered() async {
        let registry = ProviderRegistry()
        await registry.register(MockProvider(providerID: "a", displayName: "A"))
        await registry.register(MockProvider(providerID: "b", displayName: "B"))
        let all = await registry.allProviders()
        #expect(all.count == 2)
    }
}
