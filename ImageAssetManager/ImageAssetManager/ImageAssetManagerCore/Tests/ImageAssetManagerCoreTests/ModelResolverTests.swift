import Testing
import Foundation
@testable import ImageAssetManagerCore

private let google: Set<String> = ["nano_banana"]

@Suite("ModelResolver")
struct ModelResolverTests {

    private func resolve(_ request: ResolveRequest, _ catalogue: Catalogue? = nil, providers: Set<String> = google) throws -> Resolution {
        try ModelResolver.resolve(request, catalogue: try catalogue ?? RepoCatalogue.parsed(), providers: providers)
    }

    // MARK: - Tiers

    @Test func eachTierResolvesToItsModelWithHandWorkedPrices() throws {
        // GBP = USD estimate x 0.79 (fx in the file). 0.0336 x 0.79 = 0.026544; 0.134 x 0.79 = 0.10586.
        let fast = try resolve(ResolveRequest(quality: "fast"))
        #expect(fast.model.id == "gemini-3.1-flash-lite-image")
        #expect(fast.imageSize == "1K")
        #expect(fast.estimateUSD == Decimal(string: "0.0336"))
        #expect(fast.estimateGBP == Decimal(string: "0.026544"))
        #expect(fast.tier == "fast")
        #expect(fast.note == nil)

        let standard = try resolve(ResolveRequest(quality: "standard"))
        #expect(standard.model.id == "gemini-nano-banana-2.1")
        #expect(standard.imageSize == "1K")
        #expect(standard.estimateGBP == Decimal(string: "0.026544"))

        let pro = try resolve(ResolveRequest(quality: "pro"))
        #expect(pro.model.id == "gemini-3-pro-image")
        #expect(pro.imageSize == "2K")   // the tier's route takes 2K
        #expect(pro.estimateGBP == Decimal(string: "0.10586"))
        #expect(pro.maxReferenceImages == 14)
    }

    @Test func qualityIsCaseInsensitiveAndUnknownNamesAreRefused() throws {
        #expect(try resolve(ResolveRequest(quality: "FAST")).model.id == "gemini-3.1-flash-lite-image")
        #expect(throws: ResolveError.unknownQuality("ultra-ultra")) {
            try resolve(ResolveRequest(quality: "ultra-ultra"))
        }
        #expect(throws: ResolveError.unknownMedia("video")) {
            try resolve(ResolveRequest(media: "video"))
        }
    }

    @Test func autoKeepsItsMeaning() throws {
        // No references: standard. With references: still standard, because it takes them.
        #expect(try resolve(ResolveRequest(quality: "auto")).model.id == "gemini-nano-banana-2.1")
        let withRefs = try resolve(ResolveRequest(quality: "auto", referenceCount: 2))
        #expect(withRefs.model.id == "gemini-nano-banana-2.1")
        #expect(withRefs.note == nil)
    }

    @Test func withReferencesIsStandardPlusTheReferencesCapability() throws {
        let old = try resolve(ResolveRequest(quality: "with_references"))
        let new = try resolve(ResolveRequest(quality: "standard", require: [.references]))
        #expect(old.model.id == new.model.id)
        #expect(old.model.id == "gemini-nano-banana-2.1")

        // The pair: the same alias on a catalogue whose standard tier takes no references
        // is refused, exactly as the explicit requirement is.
        let noRefs = try noReferenceStandard()
        #expect(throws: ResolveError.self) {
            try resolve(ResolveRequest(quality: "with_references"), noRefs)
        }
        #expect(throws: ResolveError.self) {
            try resolve(ResolveRequest(quality: "standard", require: [.references]), noRefs)
        }
    }

    // MARK: - Capabilities (T13 shape, for the one provider there is)

    /// The repo catalogue with the Standard model's reference cap set to zero.
    private func noReferenceStandard() throws -> Catalogue {
        try RepoCatalogue.parsed { root in
            var list = modelList(root)
            list[1]["maxReferenceImages"] = 0       // gemini-nano-banana-2.1
            setModelList(&root, list)
        }
    }

    @Test func explicitRequireNamesWhatWouldWork() throws {
        let catalogue = try noReferenceStandard()
        do {
            _ = try resolve(ResolveRequest(quality: "standard", require: [.references]), catalogue)
            Issue.record("expected capabilityUnavailable")
        } catch let ResolveError.capabilityUnavailable(missing, alternatives) {
            #expect(missing == ["references"])
            // Fast and pro tiers still take references; standard does not.
            #expect(alternatives.contains("image/fast"))
            #expect(alternatives.contains("image/pro"))
            #expect(!alternatives.contains("image/standard"))
            #expect(alternatives.contains("nano_banana:gemini-3-pro-image"))
            #expect(!alternatives.contains("nano_banana:gemini-nano-banana-2.1"))
        }
    }

    @Test func attachedReferencesRerouteWithANoteButAnExplicitRequireDoesNot() throws {
        let catalogue = try noReferenceStandard()

        // References merely attached: reroute, as the app always has, and say so.
        let rerouted = try resolve(ResolveRequest(quality: "standard", referenceCount: 2), catalogue)
        #expect(rerouted.model.id == "gemini-3-pro-image")
        #expect(rerouted.tier == "pro")
        #expect(rerouted.note == "Auto-routed to pro because references are attached; standard can't use them on this API")

        // The pair: the caller demanded the capability, so no silent reroute.
        #expect(throws: ResolveError.self) {
            try resolve(ResolveRequest(quality: "standard", require: [.references], referenceCount: 2), catalogue)
        }
    }

    @Test func anImpossibleRequirementReturnsAnEmptyAlternativesList() throws {
        do {
            _ = try resolve(ResolveRequest(quality: "fast", require: [.transparentBackground]))
            Issue.record("expected capabilityUnavailable")
        } catch let ResolveError.capabilityUnavailable(missing, alternatives) {
            #expect(missing == ["transparent_background"])
            #expect(alternatives.isEmpty)
        }
    }

    @Test func aCatalogueCapabilityListMakesSeedASatisfiableRequirement() throws {
        let catalogue = try RepoCatalogue.parsed { root in
            var list = modelList(root)
            list[2]["capabilities"] = ["seed"]       // gemini-3-pro-image
            setModelList(&root, list)
        }
        #expect(throws: ResolveError.self) { try resolve(ResolveRequest(quality: "fast", require: [.seed]), catalogue) }
        let pro = try resolve(ResolveRequest(quality: "pro", require: [.seed]), catalogue)
        #expect(pro.model.id == "gemini-3-pro-image")
    }

    // MARK: - Routes and providers

    @Test func theFirstConfiguredRouteWins() throws {
        // Both providers have keys, but only Google has catalogue models in this pass: first route.
        let r = try resolve(ResolveRequest(quality: "fast"), providers: ["nano_banana", "openrouter"])
        #expect(r.provider == "nano_banana")
        #expect(r.note == nil)
    }

    @Test func aLaterRouteIsUsedWhenTheFirstProviderIsNotConfigured() throws {
        // Put a second Google-served model behind a route to an unconfigured provider.
        let catalogue = try RepoCatalogue.parsed { root in
            setTierRoutes(&root, tier: "fast", [
                ["provider": "openrouter", "model": "google/gemini-3.1-flash-lite-image", "usdEstimate": 0.0336],
                ["provider": "nano_banana", "model": "gemini-3.1-flash-lite-image", "usdEstimate": 0.0336],
            ])
        }
        let r = try resolve(ResolveRequest(quality: "fast"), catalogue)
        #expect(r.provider == "nano_banana")
        #expect(r.note == "Used nano_banana for fast: the first route was unavailable")
        // The pair: with the same ordering and no skipped route, there is no note.
        #expect(try resolve(ResolveRequest(quality: "fast")).note == nil)
    }

    @Test func aTierNoConfiguredProviderServesIsAnError() throws {
        #expect(throws: ResolveError.noRoute(media: "vector", tier: "standard", needs: ["openrouter"])) {
            try resolve(ResolveRequest(media: "vector", quality: "standard"))
        }
    }

    // MARK: - Parameters

    @Test func anUnsupportedAspectRatioIsRejectedWithTheSupportedList() throws {
        do {
            _ = try resolve(ResolveRequest(quality: "fast", aspectRatio: "4:3"))
            Issue.record("expected unsupportedAspectRatio")
        } catch let ResolveError.unsupportedAspectRatio(requested, supported) {
            #expect(requested == "4:3")
            #expect(supported == ["1:1", "16:9", "9:16"])
        }
        // The pair: a listed ratio passes and is carried through.
        #expect(try resolve(ResolveRequest(quality: "fast", aspectRatio: "16:9")).aspectRatio == "16:9")
    }

    @Test func aRequestedResolutionOverridesTheDefaultAndRepricesTheEstimate() throws {
        // 4K on Nano Banana 2.1 is $0.113; x 0.79 = 0.08927.
        let r = try resolve(ResolveRequest(quality: "standard", resolution: "4K"))
        #expect(r.imageSize == "4K")
        #expect(r.estimateUSD == Decimal(string: "0.113"))
        #expect(r.estimateGBP == Decimal(string: "0.08927"))

        // Flash-lite lists 1K only.
        do {
            _ = try resolve(ResolveRequest(quality: "fast", resolution: "4K"))
            Issue.record("expected unsupportedResolution")
        } catch let ResolveError.unsupportedResolution(requested, supported) {
            #expect(requested == "4K")
            #expect(supported == ["1K"])
        }
    }

    // MARK: - Explicit model

    @Test func anExplicitModelSkipsTheTiers() throws {
        // 0.067 x 0.79 = 0.05293.
        let r = try resolve(ResolveRequest(quality: "fast", explicitModel: "nano_banana:gemini-3.1-flash-image"))
        #expect(r.model.id == "gemini-3.1-flash-image")
        #expect(r.tier == nil)
        #expect(r.imageSize == "1K")
        #expect(r.estimateGBP == Decimal(string: "0.05293"))
        // A bare ID finds it among the configured providers.
        #expect(try resolve(ResolveRequest(explicitModel: "gemini-3.1-flash-image")).model.id == "gemini-3.1-flash-image")
    }

    @Test func anExplicitModelListedOnTwoTiersTakesTheFirstInTierOrderEveryTime() throws {
        // gemini-nano-banana-2.1 is on standard (no size: default 1K) and, added here, on pro at 4K.
        // Tier order is fast, standard, pro, so standard's route wins: 1K, $0.0336 x 0.79 = 0.026544.
        // Fresh parses vary dictionary order from instance to instance, so repeat.
        for _ in 0..<60 {
            let catalogue = try RepoCatalogue.parsed { root in
                var pro = tierRoutes(root, tier: "pro")
                pro.append(["provider": "nano_banana", "model": "gemini-nano-banana-2.1", "imageSize": "4K", "usdEstimate": 0.113])
                setTierRoutes(&root, tier: "pro", pro)
            }
            let r = try ModelResolver.resolve(
                ResolveRequest(explicitModel: "nano_banana:gemini-nano-banana-2.1"),
                catalogue: catalogue, providers: ["nano_banana"])
            #expect(r.imageSize == "1K")
            // Not ==: the fixture re-serialises 0.0336 as a double, so allow float noise.
            #expect(abs(r.estimateGBP - Decimal(string: "0.026544")!) < Decimal(string: "0.000000001")!)
        }
    }

    @Test func anExplicitModelStillFacesTheCapabilityAndParameterChecks() throws {
        let catalogue = try RepoCatalogue.parsed { root in
            var list = modelList(root)
            list[4]["maxReferenceImages"] = 0       // gemini-2.5-flash-image
            setModelList(&root, list)
        }
        #expect(throws: ResolveError.self) {
            try resolve(ResolveRequest(explicitModel: "nano_banana:gemini-2.5-flash-image", referenceCount: 1), catalogue)
        }
        #expect(throws: ResolveError.unsupportedResolution(requested: "2K", supported: [])) {
            try resolve(ResolveRequest(explicitModel: "nano_banana:gemini-2.5-flash-image", resolution: "2K"))
        }
        #expect(throws: ResolveError.unknownModel("nano_banana:no-such-model")) {
            try resolve(ResolveRequest(explicitModel: "nano_banana:no-such-model"))
        }
        #expect(throws: ResolveError.providerNotConfigured("openrouter")) {
            try resolve(ResolveRequest(explicitModel: "openrouter:black-forest-labs/flux.2-pro"))
        }
    }

    @Test func aModelWithNoSizeParameterSendsNoImageSize() throws {
        // gemini-2.5-flash-image takes none; 0.039 x 0.79 = 0.03081.
        let r = try resolve(ResolveRequest(explicitModel: "nano_banana:gemini-2.5-flash-image"))
        #expect(r.imageSize == nil)
        #expect(r.maxReferenceImages == 3)
        #expect(r.estimateGBP == Decimal(string: "0.03081"))
    }

    @Test func aModelWithNoKnownPriceIsGatedAtTwentyCents() throws {
        let catalogue = try RepoCatalogue.parsed { root in
            var list = modelList(root)
            list.append(["id": "unpriced-model", "api": "gemini.generateContent", "displayName": "U",
                         "aspectRatios": ["1:1"], "maxReferenceImages": 1])
            setModelList(&root, list)
        }
        let r = try resolve(ResolveRequest(explicitModel: "nano_banana:unpriced-model"), catalogue)
        #expect(r.estimateIsDefault)
        #expect(r.estimateUSD == Decimal(string: "0.20"))
        #expect(r.estimateGBP == Decimal(string: "0.158"))   // 0.20 x 0.79
        // The pair: a priced model is not flagged.
        #expect(!(try resolve(ResolveRequest(quality: "fast"), catalogue)).estimateIsDefault)
    }

    // MARK: - T10: the MCP route and the panel route agree

    @Test func t10_theMCPAndPanelRoutesResolveTheSameModelForTheSameTier() throws {
        let catalogue = try RepoCatalogue.parsed()
        let tiers: [(String, String)] = [
            ("fast", "gemini-3.1-flash-lite-image"),
            ("standard", "gemini-nano-banana-2.1"),
            ("pro", "gemini-3-pro-image"),
        ]
        for (quality, modelID) in tiers {
            // MCP: names a tier. Panel: has the tier's model selected.
            let mcp = try ModelResolver.resolve(ResolveRequest(quality: quality, aspectRatio: "16:9"), catalogue: catalogue, providers: google)
            let panel = try ModelResolver.resolveSelection(
                provider: "nano_banana", modelID: modelID, referenceCount: 0, aspectRatio: "16:9",
                catalogue: catalogue, providers: google)
            #expect(mcp.model.id == panel.model.id, "\(quality)")
            #expect(mcp.imageSize == panel.imageSize, "\(quality)")
            #expect(mcp.estimateGBP == panel.estimateGBP, "\(quality)")
            #expect(mcp.maxReferenceImages == panel.maxReferenceImages, "\(quality)")
        }
        // The pair: a model that is on no tier must NOT agree with any tier.
        let offTier = try ModelResolver.resolveSelection(
            provider: "nano_banana", modelID: "gemini-3.1-flash-image", referenceCount: 0, aspectRatio: "16:9",
            catalogue: catalogue, providers: google)
        for quality in ["fast", "standard", "pro"] {
            let mcp = try ModelResolver.resolve(ResolveRequest(quality: quality, aspectRatio: "16:9"), catalogue: catalogue, providers: google)
            #expect(mcp.model.id != offTier.model.id)
        }
    }

    @Test func t10_withReferencesAttachedBothRoutesRerouteTheSameWay() throws {
        let catalogue = try noReferenceStandard()
        // The panel has the (reference-less) Standard model selected, two references attached.
        let panel = try ModelResolver.resolveSelection(
            provider: "nano_banana", modelID: "gemini-nano-banana-2.1", referenceCount: 2, aspectRatio: "1:1",
            catalogue: catalogue, providers: google)
        let mcp = try ModelResolver.resolve(ResolveRequest(quality: "standard", referenceCount: 2), catalogue: catalogue, providers: google)
        #expect(panel.model.id == mcp.model.id)
        #expect(panel.model.id == "gemini-3-pro-image")
        #expect(panel.note == "References attached — using Gemini 3 Pro Image")
    }

    // MARK: - ImageModel handed to the provider

    @Test func theImageModelCarriesCostSizeAndReferenceCap() throws {
        let m = try resolve(ResolveRequest(quality: "pro")).imageModel
        #expect(m.id == "gemini-3-pro-image")
        #expect(m.costPerImage == Decimal(string: "0.10586"))
        #expect(m.imageSize == "2K")
        #expect(m.maxReferenceImages == 14)
        #expect(m.supportsReferences)
        #expect(m.supportedAspectRatios == [.square, .landscape, .portrait])
    }
}
