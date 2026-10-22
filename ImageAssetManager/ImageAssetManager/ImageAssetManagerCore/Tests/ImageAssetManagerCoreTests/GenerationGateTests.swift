import Testing
import Foundation
@testable import ImageAssetManagerCore

/// A provider that answers with whatever it was told to, and records whether it was called.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var budget: GenerationPolicy.BudgetContext?
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    var lastBudget: GenerationPolicy.BudgetContext? { lock.lock(); defer { lock.unlock() }; return budget }
    func bump(_ b: GenerationPolicy.BudgetContext?) { lock.lock(); n += 1; budget = b; lock.unlock() }
}

private struct FakeProvider: ImageProvider {
    let providerID = "nano_banana"
    let displayName = "Fake"
    let availableModels: [ImageModel] = []
    let supportedAspectRatios: [AspectRatio] = AspectRatio.allCases
    let supportsReferenceImages = false
    let maxReferenceImages = 0
    let supportedReferenceRoles: [ReferenceRole] = []
    let image: GeneratedImage
    let calls = CallCounter()

    func estimateCost(_ params: GenerationParams) -> Decimal { params.model.costPerImage }
    func generate(_ params: GenerationParams, references: [ReferenceInput]?) async throws -> GeneratedImage {
        calls.bump(params.budget)
        return image
    }
}

private let png = Data(base64Encoded: tinyPNGBase64)!

@Suite("GenerationGate")
struct GenerationGateTests {

    // MARK: - P1-2: the panel's budget gate

    @Test func aPanelImageEstimatedAtFivePoundsIsRefusedUnderTheDefaultLimits() throws {
        // The catalogue's own bounds allow $1 x fx 5: one panel image at £5.
        let dear = try RepoCatalogue.parsed { root in
            root["fx"] = ["usdToGBP": 5.0]
            var list = modelList(root)
            let i = list.firstIndex { ($0["id"] as? String) == "gemini-nano-banana-2.1" }!
            list[i]["usdByImageSize"] = ["1K": 1.0, "2K": 1.0, "4K": 1.0]
            setModelList(&root, list)
        }
        #expect(throws: GenerationPolicy.BudgetViolation.tooCostly(subtotal: 5, max: Decimal(string: "2.50")!)) {
            try PreparedGeneration.prepare(
                provider: "nano_banana", modelID: "gemini-nano-banana-2.1", referenceCount: 0, aspectRatio: "1:1",
                catalogue: dear, providers: ["nano_banana"])
        }
    }

    @Test func aPanelImageAtTheShippedPriceClearsTheGateWithTheResolutionCaptured() throws {
        let catalogue = try RepoCatalogue.parsed()
        let prepared = try PreparedGeneration.prepare(
            provider: "nano_banana", modelID: "gemini-nano-banana-2.1", referenceCount: 0, aspectRatio: "1:1",
            catalogue: catalogue, providers: ["nano_banana"])
        // Hand-worked: $0.0336 x 0.79.
        #expect(prepared.resolution.estimateGBP == Decimal(string: "0.026544"))
        #expect(prepared.subtotalGBP == Decimal(string: "0.026544"))
        #expect(prepared.resolution.model.id == "gemini-nano-banana-2.1")
        #expect(prepared.budget == .init(count: 1, limits: .defaults))
    }

    @Test func theGateUsesTheSameDefaultsAsTheMCP() {
        #expect(GenerationPolicy.BudgetLimits.defaults.maxImages == 20)
        #expect(GenerationPolicy.BudgetLimits.defaults.maxCostGBP == Decimal(string: "2.50")!)
    }

    @Test func confirmRecordsTheCapturedResolutionNotAFreshOne() throws {
        let catalogue = try RepoCatalogue.parsed()
        let prepared = try PreparedGeneration.prepare(
            provider: "nano_banana", modelID: "gemini-nano-banana-2.1", referenceCount: 0, aspectRatio: "1:1",
            catalogue: catalogue, providers: ["nano_banana"])
        let plain = GeneratedImage(data: png, format: "png")
        let recorded = prepared.recording(plain)
        #expect(recorded.modelID == "gemini-nano-banana-2.1")
        #expect(recorded.estimatedCostGBP == Decimal(string: "0.026544"))

        // The pair: a provider that moved to another model mid-call is recorded as what it used.
        let moved = GeneratedImage(data: png, format: "png", modelUsed: "gemini-3-pro-image", estimatedCostGBP: Decimal(string: "0.10586"))
        let movedRecord = prepared.recording(moved)
        #expect(movedRecord.modelID == "gemini-3-pro-image")
        #expect(movedRecord.estimatedCostGBP == Decimal(string: "0.10586"))
    }

    // MARK: - P2-1: the service records the model the provider actually used

    private func service(_ provider: FakeProvider) throws -> (GenerationService, AppDatabase, URL) {
        let db = try AppDatabase(path: ":memory:")
        let dir = makeTempDirectory()
        return (GenerationService(database: db, libraryURL: dir, provider: provider), db, dir)
    }

    private func request(budget: GenerationPolicy.BudgetContext? = nil) -> GenerationService.Request {
        GenerationService.Request(
            prompt: "p",
            model: ImageModel(id: "old-model-aa", displayName: "Old", supportedAspectRatios: [], costPerImage: Decimal(string: "0.03")!),
            aspectRatio: .square, width: 1, height: 1, budget: budget)
    }

    @Test func aMovedModelIsWhatTheAssetRowAndTheOutcomeRecord() async throws {
        let moved = GeneratedImage(data: png, format: "png", modelUsed: "new-model-bb", estimatedCostGBP: Decimal(string: "0.10586"))
        let (service, db, _) = try service(FakeProvider(image: moved))
        let outcome = try await service.generate(request())
        #expect(outcome.modelID == "new-model-bb")
        #expect(outcome.estimatedCost == 0.10586)
        let row = try #require(try await db.fetchAsset(id: outcome.assetID))
        #expect(row.modelID == "new-model-bb")
        #expect(row.estimatedCost == 0.10586)
    }

    @Test func anUnmovedModelStaysTheRequestsAndItsPrice() async throws {
        let (service, db, _) = try service(FakeProvider(image: GeneratedImage(data: png, format: "png")))
        let outcome = try await service.generate(request())
        #expect(outcome.modelID == "old-model-aa")
        let row = try #require(try await db.fetchAsset(id: outcome.assetID))
        #expect(row.modelID == "old-model-aa")
        #expect(row.estimatedCost == 0.03)
    }

    @Test func theRequestsBudgetReachesTheProviderParams() async throws {
        let provider = FakeProvider(image: GeneratedImage(data: png, format: "png"))
        let (service, _, _) = try service(provider)
        let budget = GenerationPolicy.BudgetContext(count: 3, limits: .defaults)
        _ = try await service.generate(request(budget: budget))
        #expect(provider.calls.lastBudget == budget)
    }
}
