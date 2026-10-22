import Testing
import Foundation
@testable import ImageAssetManagerCore

/// Pass B leftovers (review P3 8): learnt prices are keyed by model and size, and have a floor.
@Suite("Learnt OpenRouter prices")
struct LearntPriceTests {
    // In the recorded listing (resolution 1K/2K/4K) and not priced by the catalogue.
    static let model = "google/gemini-3-pro-image-preview"

    private func resolve(_ rig: ORRig, size: String) throws -> Resolution {
        try rig.resolve(ResolveRequest(explicitModel: "openrouter:\(Self.model)", resolution: size))
    }

    @Test func anObservedCostIsKeptForItsOwnSizeOnly() async throws {
        let rig = try await ORRig.make()
        #expect(try resolve(rig, size: "1K").estimateSource == .unknownDefault)

        // A real 1K generation through the provider: the cost seen is recorded against 1K.
        let route = try resolve(rig, size: "1K")
        let paid = StubSession(status: 200, body: okBody(cost: 0.05))
        _ = try await rig.provider.generate(rig.params(route), references: nil, session: paid.session)

        let oneK = try resolve(rig, size: "1K")
        #expect(oneK.estimateSource == .observedCost)
        #expect(oneK.estimateUSD == Decimal(string: "0.05"))
        // The pair: 4K has no price of its own, so it is still gated at the compiled $0.20.
        let fourK = try resolve(rig, size: "4K")
        #expect(fourK.estimateSource == .unknownDefault)
        #expect(fourK.estimateUSD == Decimal(string: "0.20"))
    }

    @Test func aLearntPriceNeverFallsBelowTheFloor() async throws {
        let rig = try await ORRig.make()
        rig.live.recordObservedCost(usd: Decimal(string: "0.0000001")!, for: Self.model, size: "1K")
        let floored = try resolve(rig, size: "1K")
        #expect(floored.estimateSource == .observedCost)
        #expect(floored.estimateUSD == Decimal(string: "0.005"))
        // 0.004 is below the $0.005 floor too (it was above the old $0.001 one).
        rig.live.recordObservedCost(usd: Decimal(string: "0.004")!, for: Self.model, size: "4K")
        #expect(try resolve(rig, size: "4K").estimateUSD == Decimal(string: "0.005"))
        // The pair: a price above the floor is kept as it is.
        rig.live.recordObservedCost(usd: Decimal(string: "0.006")!, for: Self.model, size: "2K")
        #expect(try resolve(rig, size: "2K").estimateUSD == Decimal(string: "0.006"))
    }

    @Test func aCachedPriceBelowTheFloorIsRaisedWhenRead() throws {
        // A price file written by an earlier build, unfloored and keyed by model alone.
        let dir = makeTempDirectory()
        let file = #"{"\#(Self.model)":{"usdPerImage":0.00001,"source":"observed_cost"}}"#
        try Data(file.utf8).write(to: dir.appending(path: "openrouter-prices.json"))
        let store = OpenRouterModelStore(directory: dir)
        let learnt = try #require(store.snapshot().learntPrice(model: Self.model, size: nil))
        #expect(learnt.usdPerImage == Decimal(string: "0.005"))
    }

    @Test func theEndpointListingServesEverySizeButAnObservedCostDoesNot() {
        let listed = OpenRouterModels(models: [], prices: [
            OpenRouterPrice.key(model: "a-model-aa", size: nil): OpenRouterPrice(usdPerImage: Decimal(string: "0.04")!, source: "endpoint_pricing"),
            OpenRouterPrice.key(model: "b-model-bb", size: nil): OpenRouterPrice(usdPerImage: Decimal(string: "0.04")!, source: "observed_cost"),
        ])
        #expect(listed.learntPrice(model: "a-model-aa", size: "4K")?.usdPerImage == Decimal(string: "0.04"))
        #expect(listed.learntPrice(model: "b-model-bb", size: "4K") == nil)
    }
}
