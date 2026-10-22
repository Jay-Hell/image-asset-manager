import Testing
import Foundation
@testable import ImageAssetManagerCore

// MARK: - Rig: the real call site, with providers bound to recorded stub sessions

/// A real provider driven through a stub session, so what leaves the process is recorded.
private struct BoundGoogle: ImageProvider {
    let inner: NanaBananaProvider
    let session: URLSession
    var providerID: String { inner.providerID }
    var displayName: String { inner.displayName }
    var availableModels: [ImageModel] { [] }
    var supportedAspectRatios: [AspectRatio] { inner.supportedAspectRatios }
    var supportsReferenceImages: Bool { true }
    var maxReferenceImages: Int { 14 }
    var supportedReferenceRoles: [ReferenceRole] { inner.supportedReferenceRoles }
    func estimateCost(_ params: GenerationParams) -> Decimal { inner.estimateCost(params) }
    func generate(_ params: GenerationParams, references: [ReferenceInput]?) async throws -> GeneratedImage {
        try await inner.generate(params, references: references, session: session)
    }
}

private struct BoundOpenRouter: ImageProvider {
    let inner: OpenRouterProvider
    let session: URLSession
    var providerID: String { inner.providerID }
    var displayName: String { inner.displayName }
    var availableModels: [ImageModel] { [] }
    var supportedAspectRatios: [AspectRatio] { inner.supportedAspectRatios }
    var supportsReferenceImages: Bool { true }
    var maxReferenceImages: Int { 14 }
    var supportedReferenceRoles: [ReferenceRole] { inner.supportedReferenceRoles }
    func estimateCost(_ params: GenerationParams) -> Decimal { inner.estimateCost(params) }
    func generate(_ params: GenerationParams, references: [ReferenceInput]?) async throws -> GeneratedImage {
        try await inner.generate(params, references: references, session: session)
    }
}

struct ToolsRig {
    let db: AppDatabase
    let dir: URL
    let google: StubSession
    let openRouter: StubSession
    let listing: StubSession
    let remote: StubSession
    let store: CatalogueStore
    let live: OpenRouterModelStore
    let tools: GenerateTools
    let providers: [any ImageProvider]

    static let defaultCeiling = GenerationPolicy.BudgetLimits(maxImages: 50, maxCostGBP: Decimal(string: "5.00")!)

    static func make(
        googleKey: Bool = true,
        openRouterKey: Bool = true,
        google handler: @escaping StubSession.Handler = { _ in (200, geminiSuccessBody(), [:]) },
        openRouter orHandler: @escaping StubSession.Handler = { _ in (200, okBody(), [:]) },
        ceiling: GenerationPolicy.BudgetLimits = defaultCeiling
    ) async throws -> ToolsRig {
        let google = StubSession(handler)
        let openRouter = StubSession(orHandler)
        // The model list for /images/models; the recorded Recraft record for any /endpoints path.
        let list = try ORFixture.list()
        let endpoints = try ORFixture.data("ep_recraft_recraft-v4.1-vector.json")
        let listing = StubSession { sent in
            sent.url.path.hasSuffix("/endpoints") ? (200, endpoints, [:]) : (200, list, [:])
        }
        let remote = StubSession(status: 404)
        let store = CatalogueStore(
            bundled: try RepoCatalogue.parsed(), directory: makeTempDirectory(),
            remoteURL: URL(string: "https://example.test/models.json")!, session: remote.session, build: 0)
        let live = OpenRouterModelStore(directory: makeTempDirectory(), session: listing.session)
        await live.refresh()
        var providers: [any ImageProvider] = []
        if googleKey {
            providers.append(BoundGoogle(inner: NanaBananaProvider(catalogue: store, apiKey: { "g-test-key-123" }), session: google.session))
        }
        if openRouterKey {
            providers.append(BoundOpenRouter(inner: OpenRouterProvider(catalogue: store, live: live, apiKey: { "or-test-key-456" }), session: openRouter.session))
        }
        let db = try AppDatabase(path: ":memory:")
        let dir = makeTempDirectory()
        let frozen = providers
        let tools = GenerateTools(
            database: db, libraryURL: dir, catalogue: { store.snapshot() }, live: live,
            providers: { frozen }, ceiling: { ceiling })
        return ToolsRig(db: db, dir: dir, google: google, openRouter: openRouter, listing: listing, remote: remote,
                        store: store, live: live, tools: tools, providers: providers)
    }

    var providerIDs: Set<String> { Set(providers.map(\.providerID)) }

    /// What the MCP returns for `name(arguments)`, as the caller would read it.
    func call(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: arguments)
        let result = try await tools.call(name, arguments: body)
        return try #require(try JSONSerialization.jsonObject(with: result) as? [String: Any])
    }

    /// POSTs to OpenRouter's image endpoint, as sent.
    var orGenerations: [SentRequest] { openRouter.requests.filter { $0.method == "POST" } }
}

private func dict(_ any: Any?) -> [String: Any] { (any as? [String: Any]) ?? [:] }
private func num(_ any: Any?) -> Double { (any as? NSNumber)?.doubleValue ?? .nan }

// MARK: - T17: the batch cost stop

@Suite("generate — batch cost stop")
struct BatchCostStopTests {
    // Fast tier on an OpenRouter-only install: the OpenRouter route's catalogue estimate is
    // $0.0336 x 0.79 = £0.026544 an image; each real answer costs $0.50 x 0.79 = £0.395.
    private let args: [String: Any] = ["prompt": "a harbour at dawn", "quality": "fast", "count": 5, "max_cost_gbp": 1.0]
    private func paid() -> StubSession.Handler { { _ in (200, okBody(cost: 0.50), [:]) } }

    @Test func t17_aBatchStopsWhenActualSpendPlusTheNextEstimateWouldPassTheCap() async throws {
        let rig = try await ToolsRig.make(googleKey: false, openRouter: paid())
        let result = try await rig.call("generate", args)

        // Worked by hand: after one image 0.395, after two 0.79 (0.79 + 0.026544 = 0.8165 is still
        // under 1.00, so a third is made), after three 1.185; 1.185 + 0.026544 passes 1.00, so it stops.
        let batch = dict(result["batch"])
        #expect(num(batch["requested"]) == 5)
        #expect(num(batch["made"]) == 3)
        #expect(batch["stopped_early"] as? Bool == true)
        #expect((result["generated"] as? [Any])?.count == 3)
        #expect(rig.orGenerations.count == 3)                    // and no fourth request left the process
        #expect(abs(num(dict(result["cost"])["actual_gbp"]) - 1.185) < 1e-9)
        #expect(dict(result["cost"])["actual_from_provider"] as? Bool == true)
        let notes = (result["notes"] as? [String]) ?? []
        #expect(notes.contains { $0.hasPrefix("Stopped after 3 of 5") })
        // The assets are in the library, one spend row each.
        let spend = try await rig.db.fetchSpendSummary(since: "2000-01-01", until: "2100-01-01")
        #expect(spend.generationCount == 3)
    }

    @Test func theSameBatchUnderAHigherCapRunsToTheEnd() async throws {
        // The pair: only the cap differs (2.50 holds 1.975 for five and 1.58 + 0.0265 before the fifth).
        let rig = try await ToolsRig.make(googleKey: false, openRouter: paid())
        var roomy = args
        roomy["max_cost_gbp"] = 2.5
        let result = try await rig.call("generate", roomy)
        #expect(num(dict(result["batch"])["made"]) == 5)
        #expect(dict(result["batch"])["stopped_early"] as? Bool == false)
        #expect(rig.orGenerations.count == 5)
    }
}

// MARK: - T18: generate_image and generate resolve identically

@Suite("generate — aliases and contract")
struct GenerateContractTests {

    @Test func t18_generateImageAndGenerateWithMediaImageResolveAndSendTheSame() async throws {
        let input: [String: Any] = ["prompt": "a lighthouse", "quality": "pro", "aspect_ratio": "landscape"]
        let a = try await ToolsRig.make()
        let b = try await ToolsRig.make()
        let viaGenerate = try await a.call("generate", input.merging(["media": "image"]) { $1 })
        let viaAlias = try await b.call("generate_image", input)

        #expect(dict(viaGenerate["resolved"]).mapValues { "\($0)" } == dict(viaAlias["resolved"]).mapValues { "\($0)" })
        #expect(dict(viaGenerate["resolved"])["model"] as? String == "gemini-3-pro-image")
        #expect(num(dict(viaGenerate["cost"])["estimated_gbp"]) == num(dict(viaAlias["cost"])["estimated_gbp"]))
        // What left the process agrees too: same URL, same body.
        let sentA = try #require(a.google.requests.first)
        let sentB = try #require(b.google.requests.first)
        #expect(sentA.url == sentB.url)
        #expect(sentA.url.absoluteString.contains("gemini-3-pro-image"))
        #expect(sentA.body == sentB.body || (sentA.bodyJSON as NSDictionary?) == (sentB.bodyJSON as NSDictionary?))

        // The pair that must differ: another tier resolves to another model, so the equality above is not vacuous.
        let fast = try await ToolsRig.make()
        let other = try await fast.call("generate_image", input.merging(["quality": "fast"]) { $1 })
        #expect(dict(other["resolved"])["model"] as? String == "gemini-3.1-flash-lite-image")
        #expect(dict(other["resolved"])["model"] as? String != dict(viaAlias["resolved"])["model"] as? String)
    }

    @Test func theAliasIgnoresAMediaArgumentAndStaysImage() async throws {
        let rig = try await ToolsRig.make()
        let result = try await rig.call("generate_image", ["prompt": "p", "media": "vector", "quality": "standard"])
        #expect(dict(result["resolved"])["model"] as? String == "gemini-nano-banana-2.1")
    }

    @Test func videoAndAudioAreNotYetSupportedAndNothingIsSent() async throws {
        let rig = try await ToolsRig.make()
        for media in ["video", "audio"] {
            do {
                _ = try await rig.call("generate", ["prompt": "p", "media": media])
                Issue.record("\(media) should be refused")
            } catch {
                #expect(error.localizedDescription.contains("not yet supported"))
            }
        }
        #expect(rig.google.requests.isEmpty && rig.openRouter.requests.isEmpty)
    }

    @Test func theResponseCarriesResolvedCostAndMediaTypePerAsset() async throws {
        let rig = try await ToolsRig.make()
        let result = try await rig.call("generate", ["prompt": "p", "quality": "standard"])
        let resolved = dict(result["resolved"])
        #expect(resolved["provider"] as? String == "nano_banana")
        #expect(resolved["model"] as? String == "gemini-nano-banana-2.1")
        #expect(resolved["tier"] as? String == "standard")
        #expect(resolved["reason"] is NSNull)                           // the first route served
        // 0.0336 USD x 0.79
        #expect(abs(num(dict(result["cost"])["estimated_gbp"]) - 0.026544) < 1e-9)
        #expect(dict(result["cost"])["actual_gbp"] is NSNull)           // Google returns no cost
        #expect(dict(result["cost"])["actual_from_provider"] as? Bool == false)
        let asset = try #require((result["generated"] as? [[String: Any]])?.first)
        #expect(asset["media_type"] as? String == "image/png")
    }

    @Test func aFallbackIsReportedFromTheRouteThatServed() async throws {
        // Google answers 404 for every model; OpenRouter serves the same tier (review P3 7).
        let rig = try await ToolsRig.make(google: { _ in (404, Data(), [:]) })
        let result = try await rig.call("generate", ["prompt": "p", "quality": "fast"])
        let resolved = dict(result["resolved"])
        #expect(resolved["provider"] as? String == "openrouter")
        #expect(resolved["model"] as? String == "google/gemini-3.1-flash-lite-image")
        #expect((resolved["reason"] as? String)?.contains("used the next route") == true)
        #expect(((result["notes"] as? [String]) ?? []).contains { $0.contains("used the next route") })
        #expect(abs(num(result["total_cost_gbp"]) - 0.026544) < 1e-9)    // the serving route's price
        #expect(rig.orGenerations.count == 1)
        // The pair: a 400 on route one is reported and never falls back.
        let bad = try await ToolsRig.make(google: { _ in (400, Data(#"{"error":{"message":"bad prompt"}}"#.utf8), [:]) })
        do {
            _ = try await bad.call("generate", ["prompt": "p", "quality": "fast"])
            Issue.record("a 400 should be reported")
        } catch {
            #expect(error.localizedDescription.contains("bad prompt"))
        }
        #expect(bad.orGenerations.isEmpty)
    }

    @Test func requireFiltersAndAnUnknownCapabilityIsRefusedBeforeAnyCall() async throws {
        let rig = try await ToolsRig.make()
        do {
            _ = try await rig.call("generate", ["prompt": "p", "require": ["telepathy"]])
            Issue.record("unknown capability")
        } catch {
            #expect(error.localizedDescription.contains("unknown capability 'telepathy'"))
        }
        #expect(rig.google.requests.isEmpty)
    }
}

// MARK: - Explicit model and exact ratios

@Suite("generate — explicit model")
struct ExplicitModelTests {
    // Not in the catalogue, in the recorded list, priced per image by the recorded endpoints record.
    private let model = "openrouter:recraft/recraft-v4.1-flash"

    @Test func anExplicitOpenRouterModelIsPricedBeforeItIsResolvedAndTheGateUsesThatPrice() async throws {
        let rig = try await ToolsRig.make()
        // £0.10 clears the endpoint price ($0.08 x 0.79 = £0.0632) but not the unpriced $0.20 gate (£0.158).
        let result = try await rig.call("generate", ["prompt": "p", "model": model, "max_cost_gbp": 0.10])
        #expect(dict(result["resolved"])["model"] as? String == "recraft/recraft-v4.1-flash")
        #expect(abs(num(dict(result["cost"])["estimated_gbp"]) - 0.0632) < 1e-9)
        let asks = rig.listing.requests.filter { $0.url.path.hasSuffix("/endpoints") }
        #expect(asks.map(\.url.path) == ["/api/v1/images/models/recraft/recraft-v4.1-flash/endpoints"])
        // The request body names the model, and the price was asked for before the image was.
        #expect(rig.orGenerations.first?.bodyJSON?["model"] as? String == "recraft/recraft-v4.1-flash")
    }

    @Test func aTierRequestNeverAsksForAPrice() async throws {
        let rig = try await ToolsRig.make()
        _ = try await rig.call("generate", ["prompt": "p", "quality": "fast"])
        #expect(rig.listing.requests.filter { $0.url.path.hasSuffix("/endpoints") }.isEmpty)
    }

    @Test func anExplicitModelStillMeetsTheCapabilityCheckAndTheGate() async throws {
        let rig = try await ToolsRig.make()
        do {
            _ = try await rig.call("generate", ["prompt": "p", "model": model, "require": ["references"]])
            Issue.record("a text-only model cannot take references")
        } catch {
            #expect(error.localizedDescription.contains("references"))
        }
        do {
            _ = try await rig.call("generate", ["prompt": "p", "model": model, "max_cost_gbp": 0.01])
            Issue.record("the gate applies to an explicit model")
        } catch {
            #expect(error.localizedDescription.contains("exceeds max_cost_gbp"))
        }
        #expect(rig.orGenerations.isEmpty)
    }

    @Test func aRatioSuchAs4by3IsSentExactlyWhereTheModelListsItAndRefusedWhereItDoesNot() async throws {
        let rig = try await ToolsRig.make()
        let result = try await rig.call("generate", ["prompt": "p", "model": model, "aspect_ratio": "4:3"])
        #expect(rig.orGenerations.first?.bodyJSON?["aspect_ratio"] as? String == "4:3")
        let asset = try #require((result["generated"] as? [[String: Any]])?.first?["asset_id"] as? String)
        #expect(try await rig.db.fetchAsset(id: asset)?.aspectRatio == "4:3")
        // The pair: Google's list has no 4:3, so a Google tier is refused with its supported list, and nothing is sent.
        let google = try await ToolsRig.make(openRouterKey: false)
        do {
            _ = try await google.call("generate", ["prompt": "p", "quality": "fast", "aspect_ratio": "4:3"])
            Issue.record("Google cannot do 4:3")
        } catch {
            #expect(error.localizedDescription.contains("1:1"))
        }
        #expect(google.google.requests.isEmpty)
    }
}

// MARK: - T19: the panel and the MCP agree

@Suite("panel and MCP agree")
struct PanelAndMCPTests {

    @Test func t19_thePanelAndTheMCPResolveTheSameRouteAndSendTheSameRequest() async throws {
        var models = Set<String>()
        defer { #expect(models.count == 3) }   // the tiers differ, so agreeing on each is not vacuous
        for tier in ["fast", "standard", "pro"] {
            let mcp = try await ToolsRig.make()
            let panel = try await ToolsRig.make()
            let viaMCP = try await mcp.call("generate", ["prompt": "a viaduct", "quality": tier])

            // The panel: its own selection type, through the planner and the service, as the view model does.
            let prepared = try await GenerationPlanner(catalogue: { panel.store.snapshot() }, live: panel.live).prepare(
                .tier(tier), referenceCount: 0, aspectRatio: "1:1", providers: panel.providerIDs)
            let service = GenerationService(
                database: panel.db, libraryURL: panel.dir, provider: panel.providers[0],
                router: RouteExecutor(providers: panel.providers, liveModels: panel.live))
            let request = prepared.request(prompt: "a viaduct", aspectRatio: .square, width: 1024, height: 1024)
            let generated = try await service.call(request)
            let outcome = try await service.record(generated, for: request)

            let resolved = dict(viaMCP["resolved"])
            #expect(resolved["provider"] as? String == prepared.resolution.provider)
            #expect(resolved["model"] as? String == prepared.resolution.model.id)
            #expect(resolved["tier"] as? String == prepared.resolution.tier)
            #expect(abs(num(dict(viaMCP["cost"])["estimated_gbp"]) - Double(truncating: prepared.resolution.estimateGBP as NSDecimalNumber)) < 1e-9)
            #expect(outcome.modelID == prepared.resolution.model.id)
            models.insert(prepared.resolution.model.id)
            // What left the process: the same URL and the same body.
            let a = try #require(mcp.google.requests.first)
            let b = try #require(panel.google.requests.first)
            #expect(a.url == b.url)
            #expect((a.bodyJSON as NSDictionary?) == (b.bodyJSON as NSDictionary?))
        }
    }

    @Test func thePanelFallsBackAndStoresThroughTheLibraryNotRawBytes() async throws {
        let rig = try await ToolsRig.make(google: { _ in (404, Data(), [:]) })
        let prepared = try await GenerationPlanner(catalogue: { rig.store.snapshot() }, live: rig.live).prepare(
            .tier("fast"), referenceCount: 0, aspectRatio: "1:1", providers: rig.providerIDs)
        let service = GenerationService(
            database: rig.db, libraryURL: rig.dir, provider: rig.providers[0],
            router: RouteExecutor(providers: rig.providers, liveModels: rig.live))
        let request = prepared.request(prompt: "p", aspectRatio: .square, width: 1024, height: 1024)
        let generated = try await service.call(request)
        #expect(generated.providerID == "openrouter")                    // fell back
        #expect(generated.fallbackNotes.count == 1)
        let outcome = try await service.record(generated, for: request)
        let row = try #require(try await rig.db.fetchAsset(id: outcome.assetID))
        #expect(row.providerID == "openrouter")
        #expect(row.mediaType == "image/png")                            // set, because AssetStore stored it
    }

    @Test func aNamedModelInThePanelResolvesLikeTheSameModelOverMCP() async throws {
        let rig = try await ToolsRig.make()
        let viaMCP = try await rig.call("generate", ["prompt": "p", "model": "nano_banana:gemini-3-pro-image", "aspect_ratio": "square"])
        let prepared = try await GenerationPlanner(catalogue: { rig.store.snapshot() }, live: rig.live).prepare(
            .model(provider: "nano_banana", id: "gemini-3-pro-image"), referenceCount: 0, aspectRatio: "1:1",
            providers: rig.providerIDs)
        #expect(dict(viaMCP["resolved"])["model"] as? String == prepared.resolution.model.id)
        #expect(abs(num(dict(viaMCP["cost"])["estimated_gbp"]) - Double(truncating: prepared.resolution.estimateGBP as NSDecimalNumber)) < 1e-9)
        #expect(prepared.routes.count == 1)     // a named model has no fallback
    }
}

// MARK: - list_generation_options

@Suite("list_generation_options")
struct ListOptionsTests {

    @Test func withoutIncludeAllItListsTiersEstimatesAndProvidersButNoModelList() async throws {
        let rig = try await ToolsRig.make()
        let result = try await rig.call("list_generation_options", [:])
        #expect(result["models"] == nil)
        let providers = (result["providers"] as? [[String: Any]]) ?? []
        #expect(providers.map { $0["id"] as? String } == ["nano_banana", "openrouter"])
        #expect(providers.allSatisfy { $0["configured"] as? Bool == true })

        let image = dict(dict(dict(result["media"])["image"])["tiers"])
        let pro = dict(image["pro"])
        #expect(pro["available"] as? Bool == true)
        #expect(pro["model"] as? String == "gemini-3-pro-image")
        #expect(abs(num(pro["estimate_gbp"]) - 0.10586) < 1e-9)          // 0.134 USD x 0.79
        #expect(pro["estimate_source"] as? String == "catalogue")
        #expect((pro["capabilities"] as? [String])?.contains("references") == true)
        #expect(dict((pro["fallbacks"] as? [Any])?.first)["provider"] as? String == "openrouter")
        let vector = dict(dict(dict(result["media"])["vector"])["tiers"])
        #expect(dict(vector["standard"])["model"] as? String == "recraft/recraft-v4.1-vector")
        #expect(dict(dict(result["media"])["video"])["note"] as? String == "not yet supported")
        #expect((result["capabilities"] as? [String]) == ["references", "transparent_background", "seed"])
    }

    @Test func includeAllAddsEveryCatalogueModelAndTheWholeLiveList() async throws {
        let rig = try await ToolsRig.make()
        let result = try await rig.call("list_generation_options", ["include_all": true])
        let models = (result["models"] as? [[String: Any]]) ?? []
        let byRef = Dictionary(uniqueKeysWithValues: models.map { ($0["model"] as! String, $0) })

        // A catalogue model, priced by the catalogue.
        let pro = try #require(byRef["nano_banana:gemini-3-pro-image"])
        #expect(pro["estimate_source"] as? String == "catalogue")
        // A live-list model nothing prices: the compiled $0.20 gate, and it says so.
        let flux = try #require(byRef["openrouter:black-forest-labs/flux.2-pro"])
        #expect(flux["estimate_source"] as? String == "unknown_default")
        #expect(abs(num(flux["estimate_gbp"]) - 0.158) < 1e-9)           // 0.20 x 0.79
        #expect((flux["capabilities"] as? [String])?.contains("seed") == true)
        // The vector model is listed as vector.
        #expect(byRef["openrouter:recraft/recraft-v4.1-vector"]?["media"] as? String == "vector")
        // Every one of the recorded list's models is there (61), plus the Google catalogue's own.
        let openRouter = models.filter { $0["provider"] as? String == "openrouter" }
        #expect(openRouter.count == ORFixture.modelCount)
        #expect(models.filter { $0["provider"] as? String == "nano_banana" }.count == 5)
    }

    @Test func aProviderWithoutAKeyIsReportedNotConfiguredAndOffersNoModels() async throws {
        let rig = try await ToolsRig.make(openRouterKey: false)
        let result = try await rig.call("list_generation_options", ["include_all": true])
        let providers = (result["providers"] as? [[String: Any]]) ?? []
        #expect(providers.first { $0["id"] as? String == "openrouter" }?["configured"] as? Bool == false)
        let models = (result["models"] as? [[String: Any]]) ?? []
        #expect(!models.contains { $0["provider"] as? String == "openrouter" })
        // Tiers fall to Google alone, with no fallback.
        let fast = dict(dict(dict(dict(result["media"])["image"])["tiers"])["fast"])
        #expect(fast["provider"] as? String == "nano_banana")
        #expect((fast["fallbacks"] as? [Any])?.isEmpty == true)
        // And the vector tiers, which only OpenRouter serves, say they are unavailable.
        #expect(dict(dict(dict(dict(result["media"])["vector"])["tiers"])["standard"])["available"] as? Bool == false)
    }
}

// MARK: - The panel's model picker reads the same list

@Suite("model options")
struct ModelOptionsTests {
    @Test func theOptionsMatchWhatTheMCPListsForTheSameInstall() async throws {
        let rig = try await ToolsRig.make()
        let options = ModelOptions.all(catalogue: rig.store.snapshot(), providers: rig.providerIDs, live: rig.live.snapshot())
        let listed = try await rig.call("list_generation_options", ["include_all": true])
        let models = (listed["models"] as? [[String: Any]]) ?? []
        #expect(options.map(\.reference).sorted() == models.compactMap { $0["model"] as? String }.sorted())
        // The same model, the same estimate.
        let flux = try #require(options.first { $0.reference == "openrouter:black-forest-labs/flux.2-pro" })
        #expect(flux.estimateGBP == Decimal(string: "0.158"))
        #expect(flux.estimateSource == .unknownDefault)
    }
}
