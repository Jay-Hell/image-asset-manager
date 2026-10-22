import Testing
import Foundation
import GRDB
@testable import ImageAssetManagerCore

// MARK: - Fixtures and rigs

/// The recorded OpenRouter responses under Tests/Fixtures/openrouter (the real listing, not a
/// hand-written one; T20).
enum ORFixture {
    static let dir: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()   // ImageAssetManagerCoreTests
        url.deleteLastPathComponent()   // Tests
        return url.appending(path: "Fixtures/openrouter", directoryHint: .isDirectory)
    }()
    static func data(_ name: String) throws -> Data { try Data(contentsOf: dir.appending(path: name)) }
    static func list() throws -> Data { try data("images_models.json") }
    static func live() throws -> OpenRouterModels { try OpenRouterModels.parse(try list()) }
    /// The number of models in the recorded listing: one `endpoints` path each, counted outside the decoder.
    static let modelCount = 61
}

private func okBody(cost: Double? = 0.0336, mime: String? = nil, bytes: String = tinyPNGBase64) -> Data {
    var item: [String: Any] = ["b64_json": bytes]
    if let mime { item["media_type"] = mime }
    var root: [String: Any] = ["data": [item]]
    if let cost { root["usage"] = ["cost": cost] }
    return try! JSONSerialization.data(withJSONObject: root)
}

private actor WaitLog {
    private(set) var values: [TimeInterval] = []
    func record(_ v: TimeInterval) { values.append(v) }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

private let svgBytes = Data(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50"><rect width="100" height="50" fill="white"/></svg>"#.utf8)

private struct ORRig {
    let list: StubSession
    let live: OpenRouterModelStore
    let remote: StubSession
    let store: CatalogueStore
    let provider: OpenRouterProvider

    static func make(
        catalogue: Catalogue? = nil,
        apiKey: @escaping @Sendable () throws -> String = { "or-test-key-456" }
    ) async throws -> ORRig {
        let fixture = try ORFixture.list()
        let list = StubSession(status: 200, body: fixture)
        let remote = StubSession(status: 404)
        let live = OpenRouterModelStore(directory: makeTempDirectory(), session: list.session)
        await live.refresh()
        let store = CatalogueStore(
            bundled: try catalogue ?? RepoCatalogue.parsed(), directory: makeTempDirectory(),
            remoteURL: URL(string: "https://example.test/models.json")!, session: remote.session, build: 0)
        return ORRig(list: list, live: live, remote: remote, store: store,
                     provider: OpenRouterProvider(catalogue: store, live: live, apiKey: apiKey))
    }

    func resolve(_ request: ResolveRequest, providers: Set<String> = ["openrouter"]) throws -> Resolution {
        try ModelResolver.resolve(request, catalogue: store.snapshot(), providers: providers, live: live.snapshot())
    }

    func params(_ r: Resolution, aspect: AspectRatio = .square, prompt: String = "A test landscape") -> GenerationParams {
        GenerationParams(prompt: prompt, model: r.imageModel, aspectRatio: aspect,
                         width: aspect == .landscape ? 1792 : 1024, height: aspect == .portrait ? 1792 : 1024,
                         outputFormat: r.outputFormat)
    }
}

private func reference() -> ReferenceInput {
    ReferenceInput(assetID: "a1", imageData: Data(base64Encoded: tinyPNGBase64)!, role: .subjectAnchor)
}

// MARK: - T20: the live-list decoder reads the recorded listing

@Suite("OpenRouter live list")
struct OpenRouterLiveListTests {

    @Test func t20_theDecoderReadsTheRecordedListingInFull() throws {
        let live = try ORFixture.live()
        #expect(live.models.count == ORFixture.modelCount)
        // Independent count of the recorded file's own entries, not through the decoder.
        let raw = try JSONSerialization.jsonObject(with: try ORFixture.list()) as! [String: Any]
        #expect((raw["data"] as! [Any]).count == ORFixture.modelCount)

        let pro = try #require(live.model("google/gemini-3-pro-image"))
        #expect(pro.values(of: "resolution") == ["1K", "2K", "4K"])
        #expect(pro.values(of: "aspect_ratio").count == 10)
        #expect(pro.maxOf("input_references") == 14)
        #expect(pro.maxOf("n") == 1)
        #expect(pro.name == "Google: Nano Banana Pro (Gemini 3 Pro Image)")

        let svg = try #require(live.model("recraft/recraft-v4.1-vector"))
        #expect(svg.values(of: "output_format") == ["svg"])
        let flux = try #require(live.model("black-forest-labs/flux.2-pro"))
        #expect(flux.parameters["seed"] == .flag(true))
        #expect(flux.values(of: "output_format") == ["png", "jpeg"])
        // A model that lists no parameters at all is still a model.
        #expect(try #require(live.model("meta/muse-image")).parameters.isEmpty)
        // Range minimums are kept: Krea K3 Edit needs at least one reference.
        #expect(try #require(live.model("krea/k3-edit")).parameters["input_references"] == .range(min: 1, max: 8))
    }

    @Test func t20_capabilitiesComeFromTheLiveRecord() throws {
        let live = try ORFixture.live()
        let flux = try #require(live.model("black-forest-labs/flux.2-pro")).asCatalogueModel()
        #expect(flux.supports(.seed))
        #expect(flux.supports(.references))
        #expect(!flux.supports(.transparentBackground))
        let gpt = try #require(live.model("openai/gpt-image-1")).asCatalogueModel()
        #expect(gpt.supports(.transparentBackground))
        #expect(!gpt.supports(.seed))
        // The pair: the same model without transparent in its list.
        let gpt2 = try #require(live.model("openai/gpt-image-2")).asCatalogueModel()
        #expect(!gpt2.supports(.transparentBackground))
        // Text-only: no references.
        #expect(!(try #require(live.model("recraft/recraft-v4.1-flash")).asCatalogueModel()).supports(.references))
    }

    @Test func aListThatIsNotAListingOrHasNoImageModelIsRefused() throws {
        #expect(throws: OpenRouterModels.ParseError.notAModelList) { try OpenRouterModels.parse(Data("[]".utf8)) }
        #expect(throws: OpenRouterModels.ParseError.noModels) { try OpenRouterModels.parse(Data(#"{"data":[]}"#.utf8)) }
        let textOnly = #"{"data":[{"id":"a/some-model","architecture":{"output_modalities":["text"]},"supported_parameters":{}}]}"#
        #expect(throws: OpenRouterModels.ParseError.noModels) { try OpenRouterModels.parse(Data(textOnly.utf8)) }
        // An ID that would not pass the catalogue's check never becomes a model.
        let badID = #"{"data":[{"id":"A/Upper Case","architecture":{"output_modalities":["image"]},"supported_parameters":{}}]}"#
        #expect(throws: OpenRouterModels.ParseError.noModels) { try OpenRouterModels.parse(Data(badID.utf8)) }
    }

    // MARK: store

    @Test func aGoodListIsCachedAndSurvivesARelaunch() async throws {
        let dir = makeTempDirectory()
        let session = StubSession(status: 200, body: try ORFixture.list())
        let store = OpenRouterModelStore(directory: dir, session: session.session)
        #expect(store.snapshot().isEmpty)
        let result = await store.refresh()
        #expect(result == .updated(count: ORFixture.modelCount))
        #expect(session.requests.first?.url.absoluteString == "https://openrouter.ai/api/v1/images/models")
        #expect(session.requests.first?.headers["authorization"] == nil)   // public: no key leaves for the list

        let down = StubSession(status: 500)   // held: a StubSession's handler dies with it
        let relaunched = OpenRouterModelStore(directory: dir, session: down.session)
        #expect(relaunched.snapshot().models.count == ORFixture.modelCount)
    }

    @Test func aFailedFetchNeverReplacesAGoodCacheAndIsNeverCached() async throws {
        let dir = makeTempDirectory()
        let goodSession = StubSession(status: 200, body: try ORFixture.list())
        let good = OpenRouterModelStore(directory: dir, session: goodSession.session)
        await good.refresh()

        // Each way to fail, against the same cache: HTTP error, junk, an empty list, a text-only list.
        let failures: [(Int, Data)] = [
            (500, Data()), (200, Data("not json".utf8)), (200, Data(#"{"data":[]}"#.utf8)),
            (200, Data(#"{"data":[{"id":"a/some-model","architecture":{"output_modalities":["text"]}}]}"#.utf8)),
        ]
        for (status, body) in failures {
            let bad = StubSession(status: status, body: body)
            let store = OpenRouterModelStore(directory: dir, session: bad.session)
            let result = await store.refresh()
            guard case .failed = result else { Issue.record("expected failure for \(status)"); continue }
            #expect(store.snapshot().models.count == ORFixture.modelCount)
            #expect(store.status().lastError != nil)
        }
        // And what is on disk is still the good list.
        let offline = StubSession(status: 500)
        let after = OpenRouterModelStore(directory: dir, session: offline.session)
        #expect(after.snapshot().models.count == ORFixture.modelCount)
    }

    @Test func aModelNotFoundForcesOneRefreshAMinuteAtMost() async throws {
        let clock = TestClock()
        let session = StubSession(status: 200, body: try ORFixture.list())
        let store = OpenRouterModelStore(directory: makeTempDirectory(), session: session.session, now: { clock.now })
        #expect(await store.refreshAfterModelUnavailable() != nil)
        #expect(await store.refreshAfterModelUnavailable() == nil)
        #expect(session.requests.count == 1)
        clock.advance(61)
        #expect(await store.refreshAfterModelUnavailable() != nil)
        #expect(session.requests.count == 2)
    }

    @Test func aFailedLaunchFetchWithNoCacheRetriesAt1And5And30MinutesThenDaily() async throws {
        // The schedule itself, worked by hand: 60 s, 300 s, 1800 s, then 86 400 s.
        #expect(OpenRouterModelStore.delay(afterFailures: 1, hasList: false) == 60)
        #expect(OpenRouterModelStore.delay(afterFailures: 2, hasList: false) == 300)
        #expect(OpenRouterModelStore.delay(afterFailures: 3, hasList: false) == 1800)
        #expect(OpenRouterModelStore.delay(afterFailures: 4, hasList: false) == 86_400)
        // The pair: with a list held, or after a success, it is the daily cadence.
        #expect(OpenRouterModelStore.delay(afterFailures: 1, hasList: true) == 86_400)
        #expect(OpenRouterModelStore.delay(afterFailures: 0, hasList: false) == 86_400)

        // And the loop really uses it: three failures, then a success, then the daily wait.
        let list = try ORFixture.list()
        let calls = CallCounter()
        let session = StubSession { _ in calls.next() <= 3 ? (500, Data(), [:]) : (200, list, [:]) }
        let store = OpenRouterModelStore(directory: makeTempDirectory(), session: session.session)
        let waits = WaitLog()
        // Waits are recorded, not served; once four are in, the loop parks until stop() cancels it.
        store.start(sleep: { seconds in
            await waits.record(seconds)
            if await waits.values.count >= 4 { try? await Task.sleep(for: .seconds(60)) }
        })
        defer { store.stop() }
        var spins = 0
        while await waits.values.count < 4 && spins < 400 { try await Task.sleep(for: .milliseconds(10)); spins += 1 }
        // Three failures wait 60, 300 and 1800 s; the fourth fetch succeeds, so the wait is a day.
        #expect(Array(await waits.values.prefix(4)) == [60, 300, 1800, 86_400])
        #expect(!store.snapshot().isEmpty)
    }

    @Test func aRequestThatNeedsTheListFetchesItOnDemandWhenNoneIsCached() async throws {
        let clock = TestClock()
        let session = StubSession(status: 200, body: try ORFixture.list())
        let store = OpenRouterModelStore(directory: makeTempDirectory(), session: session.session, now: { clock.now })
        #expect(await store.refreshIfNotLoaded() != nil)
        #expect(!store.snapshot().isEmpty)
        // The pair: with a list held there is no fetch.
        #expect(await store.refreshIfNotLoaded() == nil)
        #expect(session.requests.count == 1)
    }

    @Test func theNotLoadedErrorSaysItIsRetryingNotJustTryAgain() {
        let message = ResolveError.liveListNotLoaded.localizedDescription
        #expect(message.contains("not yet loaded"))
        #expect(message.contains("retrying"))
        #expect(!message.contains("try again"))
    }

    // MARK: prices

    @Test func aPerImageEndpointPriceIsReadAndATokenPriceIsNot() throws {
        // Recraft vector: $0.08 an image, from the recorded /endpoints record.
        #expect(OpenRouterModels.perImageUSD(fromEndpoints: try ORFixture.data("ep_recraft_recraft-v4.1-vector.json")) == Decimal(string: "0.08"))
        // Gemini 3 Pro is priced per token; tokens per image are not in the record, so no estimate.
        #expect(OpenRouterModels.perImageUSD(fromEndpoints: try ORFixture.data("ep_google_gemini-3-pro-image.json")) == nil)
    }

    @Test func anExplicitModelWithNoCataloguePriceUsesEndpointPricingThenTheObservedCostAndSaysWhich() async throws {
        // A store holding the list, asked for the price of an unpriced model. The stub answers the
        // list URL with the listing and any /endpoints URL with the recorded Recraft record.
        let stub = StubSession { req in
            req.url.path.hasSuffix("/endpoints")
                ? (200, try ORFixture.data("ep_recraft_recraft-v4.1-vector.json"), [:])
                : (200, try ORFixture.list(), [:])
        }
        let listStore = OpenRouterModelStore(directory: makeTempDirectory(), session: stub.session)
        await listStore.refresh()
        let request = ResolveRequest(explicitModel: "openrouter:recraft/recraft-v4.1-pro-vector")
        let catalogue = try RepoCatalogue.parsed { root in
            // Take the pro vector model off its tier so the catalogue gives it no price.
            var media = root["media"] as! [String: Any]
            media["vector"] = ["tiers": ["standard": [["provider": "openrouter", "model": "recraft/recraft-v4.1-vector", "usdEstimate": 0.08]]]]
            root["media"] = media
        }
        func resolveNow() throws -> Resolution {
            try ModelResolver.resolve(request, catalogue: catalogue, providers: ["openrouter"], live: listStore.snapshot())
        }
        let unknown = try resolveNow()
        #expect(unknown.estimateSource == .unknownDefault)
        #expect(unknown.estimateUSD == Decimal(string: "0.20"))

        // The price endpoint is the pro model's own; the stub answers with the recorded Recraft record.
        let learnt = await listStore.loadPrice(for: "recraft/recraft-v4.1-pro-vector")
        #expect(learnt?.usdPerImage == Decimal(string: "0.08"))
        let priced = try resolveNow()
        #expect(priced.estimateSource == .endpointPricing)
        #expect(priced.estimateUSD == Decimal(string: "0.08"))
        #expect(priced.estimateGBP == Decimal(string: "0.0632"))   // 0.08 x 0.79

        // The first real cost replaces it, and the endpoint record may not overwrite it later.
        listStore.recordObservedCost(usd: Decimal(string: "0.31")!, for: "recraft/recraft-v4.1-pro-vector")
        #expect(try resolveNow().estimateSource == .observedCost)
        #expect(try resolveNow().estimateUSD == Decimal(string: "0.31"))
        await listStore.loadPrice(for: "recraft/recraft-v4.1-pro-vector")
        #expect(try resolveNow().estimateUSD == Decimal(string: "0.31"))
    }

    @Test func theEndpointsPathIsBuiltFromACheckedIDNotTakenFromTheList() async throws {
        let session = StubSession(status: 200, body: try ORFixture.data("ep_recraft_recraft-v4.1-vector.json"))
        let store = OpenRouterModelStore(directory: makeTempDirectory(), session: session.session)
        await store.loadPrice(for: "recraft/recraft-v4.1-vector")
        #expect(session.requests.first?.url.absoluteString == "https://openrouter.ai/api/v1/images/models/recraft/recraft-v4.1-vector/endpoints")
        // The pair: an ID that would climb out of the path never reaches the network.
        #expect(await store.loadPrice(for: "../../keys") == nil)
        #expect(await store.loadPrice(for: "a/b/c") == nil)
        #expect(session.requests.count == 1)
    }
}

// MARK: - The catalogue's allow-list for this api

@Suite("openrouter.images catalogue body")
struct OpenRouterCatalogueBodyTests {
    private func catalogue(body: [String: Any]) throws -> Catalogue {
        try RepoCatalogue.parsed { root in
            setModelList(&root, [["id": "acme/new-model", "api": "openrouter.images", "displayName": "New",
                                  "aspectRatios": ["1:1"], "usdEstimate": 0.05, "body": body]], provider: "openrouter")
        }
    }

    @Test func onlyResolutionAndOutputFormatMayBeDefaulted() throws {
        let ok = try catalogue(body: ["resolution": "2K", "output_format": "svg"])
        #expect(ok.model(provider: "openrouter", id: "acme/new-model")?.defaultImageSize == "2K")
        #expect(ok.skipped.isEmpty)
        // The pair: each key that would add billed work or route the prompt elsewhere skips the entry.
        for bad in [["n": 4], ["provider": ["order": ["x"]]], ["plugins": [["id": "web"]]], ["models": ["other/model"]],
                    ["model": "other/model"], ["aspect_ratio": "1:1"], ["resolution": 2]] as [[String: Any]] {
            let c = try catalogue(body: bad)
            #expect(c.model(provider: "openrouter", id: "acme/new-model") == nil, "\(bad)")
            #expect(c.skipped.contains { $0.contains("body key not allowed") }, "\(bad)")
        }
    }

    @Test func aSlashedIDIsAcceptedForOpenRouterButStillRefusedForGoogle() throws {
        #expect(Catalogue.isValidModelID("black-forest-labs/flux.2-pro", allowSlash: true))
        #expect(!Catalogue.isValidModelID("black-forest-labs/flux.2-pro", allowSlash: false))
    }
}

// MARK: - T12 and T13: the resolver with OpenRouter routes

@Suite("Resolver with OpenRouter")
struct OpenRouterResolverTests {
    private let both: Set<String> = ["nano_banana", "openrouter"]

    @Test func t12_withBothKeysGoogleIsFirstWithOnlyOpenRouterTheSecondRouteServesEveryTier() async throws {
        let rig = try await ORRig.make()
        let expected: [(String, String, String)] = [   // tier, OpenRouter model, hand-worked GBP (USD x 0.79)
            ("fast", "google/gemini-3.1-flash-lite-image", "0.026544"),
            ("standard", "google/gemini-nano-banana-2.1", "0.026544"),
            ("pro", "google/gemini-3-pro-image", "0.10586"),
        ]
        for (tier, orModel, gbp) in expected {
            let first = try rig.resolve(ResolveRequest(quality: tier), providers: both)
            #expect(first.provider == "nano_banana", "\(tier)")
            #expect(first.note == nil, "\(tier)")

            let second = try rig.resolve(ResolveRequest(quality: tier), providers: ["openrouter"])
            #expect(second.provider == "openrouter", "\(tier)")
            #expect(second.model.id == orModel, "\(tier)")
            #expect(second.tier == tier)
            #expect(second.estimateGBP == Decimal(string: gbp), "\(tier)")
            #expect(second.estimateSource == .catalogue)
            #expect(second.note == "Used openrouter for \(tier): the first route was unavailable")
        }
        // Google alone still serves, as before.
        #expect(try rig.resolve(ResolveRequest(quality: "fast"), providers: ["nano_banana"]).provider == "nano_banana")
    }

    @Test func anOpenRouterKeyWithNoLoadedListSaysSoRatherThanNoRoute() throws {
        #expect(throws: ResolveError.liveListNotLoaded) {
            try ModelResolver.resolve(ResolveRequest(quality: "fast"), catalogue: try RepoCatalogue.parsed(), providers: ["openrouter"], live: .empty)
        }
        // The pair: with Google also configured the same request just uses Google.
        let r = try ModelResolver.resolve(ResolveRequest(quality: "fast"), catalogue: try RepoCatalogue.parsed(), providers: both, live: .empty)
        #expect(r.provider == "nano_banana")
    }

    @Test func anExplicitOpenRouterModelIsUsedByNameWithItsOwnLiveRecord() async throws {
        let rig = try await ORRig.make()
        let r = try rig.resolve(ResolveRequest(explicitModel: "openrouter:black-forest-labs/flux.2-pro", aspectRatio: "1:1"))
        #expect(r.provider == "openrouter")
        #expect(r.model.id == "black-forest-labs/flux.2-pro")
        #expect(r.tier == nil)
        #expect(r.maxReferenceImages == 8)
        #expect(r.estimateIsDefault)                      // no price anywhere: the $0.20 gate
        #expect(r.estimateUSD == Decimal(string: "0.20"))
        #expect(r.estimateGBP == Decimal(string: "0.158"))
        #expect(throws: ResolveError.unknownModel("openrouter:no-such/model-xx")) {
            try rig.resolve(ResolveRequest(explicitModel: "openrouter:no-such/model-xx"))
        }
    }

    @Test func unsupportedParametersAreRejectedWithTheListNeverChanged() async throws {
        let rig = try await ORRig.make()
        // GPT Image 1 lists four ratios and no 16:9.
        do {
            _ = try rig.resolve(ResolveRequest(explicitModel: "openrouter:openai/gpt-image-1", aspectRatio: "16:9"))
            Issue.record("expected unsupportedAspectRatio")
        } catch let ResolveError.unsupportedAspectRatio(requested, supported) {
            #expect(requested == "16:9")
            #expect(supported == ["1:1", "3:2", "2:3", "auto"])
        }
        // The pair: a listed ratio goes through.
        #expect(try rig.resolve(ResolveRequest(explicitModel: "openrouter:openai/gpt-image-1", aspectRatio: "3:2")).aspectRatio == "3:2")

        // Resolution: Nano Banana 2.1 lists 1K, 2K and 4K.
        do {
            _ = try rig.resolve(ResolveRequest(explicitModel: "openrouter:google/gemini-nano-banana-2.1", resolution: "8K"))
            Issue.record("expected unsupportedResolution")
        } catch let ResolveError.unsupportedResolution(requested, supported) {
            #expect(requested == "8K")
            #expect(supported == ["1K", "2K", "4K"])
        }
        #expect(try rig.resolve(ResolveRequest(explicitModel: "openrouter:google/gemini-nano-banana-2.1", resolution: "4K")).imageSize == "4K")

        // Output format: FLUX.2 Pro lists png and jpeg, not svg.
        do {
            _ = try rig.resolve(ResolveRequest(explicitModel: "openrouter:black-forest-labs/flux.2-pro", outputFormat: "svg"))
            Issue.record("expected unsupportedOutputFormat")
        } catch let ResolveError.unsupportedOutputFormat(requested, supported) {
            #expect(requested == "svg")
            #expect(supported == ["png", "jpeg"])
        }
        #expect(try rig.resolve(ResolveRequest(explicitModel: "openrouter:black-forest-labs/flux.2-pro", outputFormat: "jpeg")).outputFormat == "jpeg")
    }

    @Test func aVectorRequestAsksForSVGAndRaisesNoFormatOnARasterTier() async throws {
        let rig = try await ORRig.make()
        let vector = try rig.resolve(ResolveRequest(media: "vector", quality: "standard"))
        #expect(vector.model.id == "recraft/recraft-v4.1-vector")
        #expect(vector.outputFormat == "svg")
        #expect(vector.estimateGBP == Decimal(string: "0.0632"))   // 0.08 x 0.79
        let pro = try rig.resolve(ResolveRequest(media: "vector", quality: "pro"))
        #expect(pro.model.id == "recraft/recraft-v4.1-pro-vector")
        #expect(pro.estimateGBP == Decimal(string: "0.237"))        // 0.30 x 0.79
        // The pair: an image tier model lists no format and is sent none.
        #expect(try rig.resolve(ResolveRequest(quality: "fast")).outputFormat == nil)
    }

    // T13

    @Test func t13_requireReferencesSkipsARouteThatCannotTakeThemAndAnImpossibleOneListsWhatCan() async throws {
        let rig = try await ORRig.make()
        // Route one is a text-only model; route two takes 14 references.
        let catalogue = try RepoCatalogue.parsed { root in
            setTierRoutes(&root, tier: "fast", [
                ["provider": "openrouter", "model": "recraft/recraft-v4.1-flash", "usdEstimate": 0.04],
                ["provider": "openrouter", "model": "google/gemini-3.1-flash-lite-image", "usdEstimate": 0.0336],
            ])
        }
        let live = rig.live.snapshot()
        let free = try ModelResolver.resolve(ResolveRequest(quality: "fast"), catalogue: catalogue, providers: ["openrouter"], live: live)
        #expect(free.model.id == "recraft/recraft-v4.1-flash")          // no requirement: route one
        let need = try ModelResolver.resolve(ResolveRequest(quality: "fast", require: [.references]), catalogue: catalogue, providers: ["openrouter"], live: live)
        #expect(need.model.id == "google/gemini-3.1-flash-lite-image")  // the pair: route two once references are needed

        // Nothing configured can make a transparent background except the models that list it.
        do {
            _ = try ModelResolver.resolve(ResolveRequest(quality: "fast", require: [.transparentBackground]),
                                          catalogue: try RepoCatalogue.parsed(), providers: ["openrouter"], live: live)
            Issue.record("expected capabilityUnavailable")
        } catch let ResolveError.capabilityUnavailable(missing, alternatives) {
            #expect(missing == ["transparent_background"])
            #expect(alternatives.contains("openrouter:openai/gpt-image-1"))
            #expect(alternatives.contains("openrouter:sourceful/riverflow-v2.5-pro"))
            #expect(!alternatives.contains("openrouter:openai/gpt-image-2"))          // lists auto and opaque only
            #expect(!alternatives.contains("openrouter:google/gemini-3-pro-image"))
        }
        // An explicit model that cannot take references is refused with the same list.
        do {
            _ = try rig.resolve(ResolveRequest(explicitModel: "openrouter:recraft/recraft-v4.1-flash", referenceCount: 1))
            Issue.record("expected capabilityUnavailable")
        } catch let ResolveError.capabilityUnavailable(missing, alternatives) {
            #expect(missing == ["references"])
            #expect(alternatives.contains("openrouter:google/gemini-3-pro-image"))
            #expect(!alternatives.contains("openrouter:recraft/recraft-v4.1-flash"))
        }
    }

    @Test func aLongAlternativesListIsShortenedInTheMessageButNotInTheError() {
        let many = (0..<30).map { "openrouter:vendor/model-\($0)" }
        let error = ResolveError.capabilityUnavailable(missing: ["seed"], alternatives: many)
        let message = error.localizedDescription
        #expect(message.contains("openrouter:vendor/model-11"))
        #expect(!message.contains("openrouter:vendor/model-12"))
        #expect(message.contains("and 18 more"))
        #expect(error == ResolveError.capabilityUnavailable(missing: ["seed"], alternatives: many))
    }

    @Test func resolveAllReturnsEveryUsableRouteInOrderAndResolveTakesTheFirst() async throws {
        let rig = try await ORRig.make()
        let routes = try ModelResolver.resolveAll(ResolveRequest(quality: "pro"), catalogue: rig.store.snapshot(), providers: both, live: rig.live.snapshot())
        #expect(routes.map(\.provider) == ["nano_banana", "openrouter"])
        #expect(routes.map(\.model.id) == ["gemini-3-pro-image", "google/gemini-3-pro-image"])
        #expect(try rig.resolve(ResolveRequest(quality: "pro"), providers: both) == routes[0])
    }
}

// MARK: - T14: the request that leaves the process

@Suite("OpenRouterProvider request")
struct OpenRouterRequestTests {

    @Test func t14_theRequestHasTheRightURLBearerHeaderAndOnlyTheParametersTheModelLists() async throws {
        let rig = try await ORRig.make()
        let route = try rig.resolve(ResolveRequest(quality: "standard", aspectRatio: "16:9"))
        let session = StubSession(status: 200, body: okBody())
        _ = try await rig.provider.generate(rig.params(route, aspect: .landscape), references: nil, session: session.session)

        let sent = try #require(session.requests.first)
        #expect(session.requests.count == 1)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString == "https://openrouter.ai/api/v1/images")
        #expect(sent.headers["authorization"] == "Bearer or-test-key-456")
        #expect(sent.headers["content-type"] == "application/json")
        // The key is nowhere else, and the model ID is in the body, never the URL.
        #expect(!sent.url.absoluteString.contains("or-test-key-456"))
        #expect(!(String(data: sent.body, encoding: .utf8) ?? "").contains("or-test-key-456"))
        #expect(!sent.url.absoluteString.contains("gemini"))

        let body = try #require(sent.bodyJSON)
        #expect(body["model"] as? String == "google/gemini-nano-banana-2.1")
        #expect(body["prompt"] as? String == "A test landscape")
        #expect(body["aspect_ratio"] as? String == "16:9")
        #expect(body["n"] as? Int == 1)
        // Exactly the app-owned keys that this model's record lists: nothing else is sent.
        #expect(Set(body.keys) == ["model", "prompt", "aspect_ratio", "n"])
    }

    @Test func aModelThatListsNothingGetsOnlyTheModelAndThePrompt() async throws {
        let rig = try await ORRig.make()
        let route = try rig.resolve(ResolveRequest(explicitModel: "openrouter:meta/muse-image", aspectRatio: "1:1"))
        let session = StubSession(status: 200, body: okBody())
        _ = try await rig.provider.generate(rig.params(route), references: nil, session: session.session)
        #expect(Set(try #require(session.requests.first?.bodyJSON).keys) == ["model", "prompt"])
    }

    @Test func aRequestedResolutionAndTheVectorFormatAreSentOnlyWhereListed() async throws {
        let rig = try await ORRig.make()
        // Resolution listed on Nano Banana 2.1.
        let sized = try rig.resolve(ResolveRequest(explicitModel: "openrouter:google/gemini-nano-banana-2.1", resolution: "2K"))
        let a = StubSession(status: 200, body: okBody())
        _ = try await rig.provider.generate(rig.params(sized), references: nil, session: a.session)
        #expect(try #require(a.requests.first?.bodyJSON)["resolution"] as? String == "2K")

        // Vector: output_format svg; this model lists no resolution so none is sent.
        let vector = try rig.resolve(ResolveRequest(media: "vector", quality: "standard"))
        let b = StubSession(status: 200, body: okBody(mime: "image/svg+xml", bytes: svgBytes.base64EncodedString()))
        _ = try await rig.provider.generate(rig.params(vector), references: nil, session: b.session)
        let body = try #require(b.requests.first?.bodyJSON)
        #expect(body["output_format"] as? String == "svg")
        #expect(body["resolution"] == nil)
        #expect(body["model"] as? String == "recraft/recraft-v4.1-vector")
    }

    @Test func referencesGoAsBase64DataNeverURLsAndAreCappedAtTheModelsLimit() async throws {
        let rig = try await ORRig.make()
        // Krea 2 Large takes one reference.
        let route = try rig.resolve(ResolveRequest(explicitModel: "openrouter:krea/krea-2-large", referenceCount: 1))
        let session = StubSession(status: 200, body: okBody())
        _ = try await rig.provider.generate(rig.params(route), references: [reference(), reference(), reference()], session: session.session)
        let body = try #require(session.requests.first?.bodyJSON)
        let refs = try #require(body["input_references"] as? [[String: Any]])
        #expect(refs.count == 1)
        let itemJSON = String(data: try JSONSerialization.data(withJSONObject: refs[0], options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)
        #expect(itemJSON == "{\"image_url\":{\"url\":\"data:image/png;base64,\(tinyPNGBase64)\"},\"type\":\"image_url\"}")
        let raw = String(data: try #require(session.requests.first?.body), encoding: .utf8) ?? ""
        #expect(!raw.contains("http://") && !raw.contains("https://"))
    }

    @Test func aModelThatTakesNoReferencesRefusesThemBeforeAnythingIsSent() async throws {
        let rig = try await ORRig.make()
        let route = try rig.resolve(ResolveRequest(explicitModel: "openrouter:recraft/recraft-v4.1-flash"))
        let session = StubSession(status: 200, body: okBody())
        await #expect(throws: ProviderError.self) {
            try await rig.provider.generate(rig.params(route), references: [reference()], session: session.session)
        }
        #expect(session.requests.isEmpty)
    }

    @Test func theProviderChecksItsOwnRequestAgainstTheLiveRecordToo() async throws {
        let rig = try await ORRig.make()
        // A params built for a ratio the record does not list never leaves, even if the resolver was bypassed.
        let route = try rig.resolve(ResolveRequest(explicitModel: "openrouter:openai/gpt-image-1", aspectRatio: "1:1"))
        let session = StubSession(status: 200, body: okBody())
        do {
            _ = try await rig.provider.generate(rig.params(route, aspect: .landscape), references: nil, session: session.session)
            Issue.record("expected unsupportedAspectRatio")
        } catch let ResolveError.unsupportedAspectRatio(requested, supported) {
            #expect(requested == "16:9")
            #expect(supported == ["1:1", "3:2", "2:3", "auto"])
        }
        #expect(session.requests.isEmpty)
    }

    @Test func aModelMissingFromTheLiveListIsUnavailableWithoutACall() async throws {
        let rig = try await ORRig.make()
        let ghost = ImageModel(id: "gone/model-zz", displayName: "x", supportedAspectRatios: [], costPerImage: 0.1)
        let session = StubSession(status: 200, body: okBody())
        await #expect(throws: ProviderError.self) {
            try await rig.provider.generate(
                GenerationParams(prompt: "p", model: ghost, aspectRatio: .square, width: 1, height: 1),
                references: nil, session: session.session)
        }
        #expect(session.requests.isEmpty)
    }

    @Test func noKeyInTheKeychainMeansNoRequest() async throws {
        let rig = try await ORRig.make(apiKey: { throw KeychainService.KeychainError.itemNotFound })
        let route = try rig.resolve(ResolveRequest(quality: "fast"))
        let session = StubSession(status: 200, body: okBody())
        do {
            _ = try await rig.provider.generate(rig.params(route), references: nil, session: session.session)
            Issue.record("expected apiKeyNotFound")
        } catch ProviderError.apiKeyNotFound {}
        #expect(session.requests.isEmpty)
    }

    // §5.8

    @Test func errorsMapAsTheSpecSays() async throws {
        let rig = try await ORRig.make()
        let route = try rig.resolve(ResolveRequest(quality: "fast"))
        func outcome(_ status: Int, _ body: String = "") async -> ProviderError? {
            let session = StubSession(status: status, body: Data(body.utf8))
            do { _ = try await rig.provider.generate(rig.params(route), references: nil, session: session.session); return nil }
            catch let e as ProviderError { return e }
            catch { return .generationFailed("\(error)") }
        }
        guard case .invalidAPIKey? = await outcome(401) else { Issue.record("401"); return }
        guard case .invalidAPIKey? = await outcome(403) else { Issue.record("403"); return }
        guard case .outOfCredit? = await outcome(402, #"{"error":{"message":"Insufficient credits"}}"#) else { Issue.record("402"); return }
        guard case .modelUnavailable(let id)? = await outcome(404) else { Issue.record("404"); return }
        #expect(id == "google/gemini-3.1-flash-lite-image")
        guard case .rateLimited? = await outcome(429) else { Issue.record("429"); return }
        // 400 shows the provider's message and is not a rejected key.
        guard case .badRequest(let message)? = await outcome(400, #"{"error":{"message":"aspect_ratio 9:16 is not supported"}}"#) else { Issue.record("400"); return }
        #expect(message == "aspect_ratio 9:16 is not supported")
        guard case .generationFailed(let other)? = await outcome(500, #"{"error":{"message":"upstream down"}}"#) else { Issue.record("500"); return }
        #expect(other == "upstream down")
    }

    // "Test key"

    @Test func testKeyCallsTheKeyEndpointAndShowsLabelAndRemainingLimitNeverTheKey() async throws {
        let body = #"{"data":{"label":"sk-or-v1-abc...xyz","limit":10,"limit_remaining":7.5,"usage":2.5}}"#
        let session = StubSession(status: 200, body: Data(body.utf8))
        let info = try await OpenRouterKeyInfo.check(apiKey: "or-test-key-456", session: session.session)
        let sent = try #require(session.requests.first)
        #expect(sent.url.absoluteString == "https://openrouter.ai/api/v1/key")
        #expect(sent.method == "GET")
        #expect(sent.headers["authorization"] == "Bearer or-test-key-456")
        #expect(info.label == "sk-or-v1-abc...xyz")
        #expect(info.limitRemaining == 7.5)
        #expect(info.summary == "sk-or-v1-abc...xyz: $7.50 remaining")
        #expect(!info.summary.contains("or-test-key-456"))
        // No limit set on the key.
        let open = StubSession(status: 200, body: Data(#"{"data":{"label":"home","limit":null,"limit_remaining":null}}"#.utf8))
        #expect(try await OpenRouterKeyInfo.check(apiKey: "k", session: open.session).summary == "home: no spend limit")
        // A rejected key.
        let bad = StubSession(status: 401)
        await #expect(throws: ProviderError.self) { try await OpenRouterKeyInfo.check(apiKey: "k", session: bad.session) }
    }
}

// MARK: - Response, cost and storage (T15)

/// Binds a real provider to a stub session, so the service can drive the real request path.
private struct BoundProvider: ImageProvider {
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

@Suite("OpenRouter response and storage")
struct OpenRouterResponseTests {

    @Test func t15_aResponseNamingSVGIsReadAsSVGAndUsageCostBecomesGBP() async throws {
        let rig = try await ORRig.make()
        let vector = try rig.resolve(ResolveRequest(media: "vector", quality: "standard"))
        let session = StubSession(status: 200, body: okBody(cost: 0.08, mime: "image/svg+xml", bytes: svgBytes.base64EncodedString()))
        let image = try await rig.provider.generate(rig.params(vector), references: nil, session: session.session)
        #expect(image.mimeType == "image/svg+xml")
        #expect(image.format == "svg")
        #expect(image.data == svgBytes)
        #expect(image.actualCost == Decimal(string: "0.0632"))   // 0.08 USD x 0.79

        // The pair: a PNG answer with no declared type is sniffed, and a response with no cost has no actual.
        let plain = StubSession(status: 200, body: okBody(cost: nil))
        let raster = try await rig.provider.generate(
            rig.params(try rig.resolve(ResolveRequest(quality: "fast"))), references: nil, session: plain.session)
        #expect(raster.mimeType == "image/png")
        #expect(raster.format == "png")
        #expect(raster.actualCost == nil)
    }

    @Test func t15_theServiceStoresAnSVGResponseAsAnSVGAssetWithTheActualCostInGBP() async throws {
        let rig = try await ORRig.make()
        let vector = try rig.resolve(ResolveRequest(media: "vector", quality: "standard"))
        let session = StubSession(status: 200, body: okBody(cost: 0.08, mime: "image/svg+xml", bytes: svgBytes.base64EncodedString()))
        let bound = BoundProvider(inner: rig.provider, session: session.session)
        let db = try AppDatabase(path: ":memory:")
        let dir = makeTempDirectory()
        let service = GenerationService(database: db, libraryURL: dir, provider: bound)
        let outcome = try await service.generate(GenerationService.Request(
            prompt: "a logo", model: vector.imageModel, aspectRatio: .square, width: 1024, height: 1024))

        #expect(outcome.filename.hasSuffix(".svg"))
        #expect(try Data(contentsOf: outcome.fileURL) == svgBytes)         // as delivered
        let row = try #require(try await db.fetchAsset(id: outcome.assetID))
        #expect(row.mediaType == "image/svg+xml")
        #expect(row.providerID == "openrouter")
        #expect(row.modelID == "recraft/recraft-v4.1-vector")
        #expect(abs(try #require(row.actualCost) - 0.0632) < 1e-9)
        #expect(abs(row.estimatedCost! - 0.0632) < 1e-9)
        #expect(row.width == 100 && row.height == 50)                       // from the viewBox, not the request
    }

    @Test func aLabelTheBytesContradictIsRefusedNotStored() async throws {
        let rig = try await ORRig.make()
        let route = try rig.resolve(ResolveRequest(quality: "fast"))
        // Declared SVG, but the bytes are a PNG.
        let session = StubSession(status: 200, body: okBody(mime: "image/svg+xml"))
        let db = try AppDatabase(path: ":memory:")
        let dir = makeTempDirectory()
        let service = GenerationService(database: db, libraryURL: dir, provider: BoundProvider(inner: rig.provider, session: session.session))
        await #expect(throws: GenerationServiceError.self) {
            try await service.generate(GenerationService.Request(prompt: "p", model: route.imageModel, aspectRatio: .square, width: 1, height: 1))
        }
        let assets = (try? FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "assets").path)) ?? []
        #expect(assets.isEmpty)
    }

    @Test func theFirstRealCostIsRememberedForThatModel() async throws {
        let rig = try await ORRig.make()
        let route = try rig.resolve(ResolveRequest(explicitModel: "openrouter:black-forest-labs/flux.2-pro"))
        #expect(route.estimateSource == .unknownDefault)
        let paid = StubSession(status: 200, body: okBody(cost: 0.03))
        _ = try await rig.provider.generate(rig.params(route), references: nil, session: paid.session)
        let next = try rig.resolve(ResolveRequest(explicitModel: "openrouter:black-forest-labs/flux.2-pro"))
        #expect(next.estimateSource == .observedCost)
        #expect(next.estimateUSD == Decimal(string: "0.03"))
    }
}

// MARK: - T16: fallback on exactly three conditions

private final class Script: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var models: [String] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var modelIDs: [String] { lock.lock(); defer { lock.unlock() }; return models }
    func record(_ model: String) { lock.lock(); calls += 1; models.append(model); lock.unlock() }
}

private struct ScriptedProvider: ImageProvider {
    let providerID: String
    let failure: ProviderError?
    let script = Script()
    var displayName: String { providerID }
    var availableModels: [ImageModel] { [] }
    var supportedAspectRatios: [AspectRatio] { [.square] }
    var supportsReferenceImages: Bool { false }
    var maxReferenceImages: Int { 0 }
    var supportedReferenceRoles: [ReferenceRole] { [] }
    func estimateCost(_ params: GenerationParams) -> Decimal { params.model.costPerImage }
    func generate(_ params: GenerationParams, references: [ReferenceInput]?) async throws -> GeneratedImage {
        script.record(params.model.id)
        if let failure { throw failure }
        return GeneratedImage(data: Data(base64Encoded: tinyPNGBase64)!, format: "png", actualCost: 0.01)
    }
}

private struct FixedProvider: ImageProvider {
    let providerID: String
    let image: GeneratedImage
    var displayName: String { providerID }
    var availableModels: [ImageModel] { [] }
    var supportedAspectRatios: [AspectRatio] { [.square] }
    var supportsReferenceImages: Bool { false }
    var maxReferenceImages: Int { 0 }
    var supportedReferenceRoles: [ReferenceRole] { [] }
    func estimateCost(_ params: GenerationParams) -> Decimal { params.model.costPerImage }
    func generate(_ params: GenerationParams, references: [ReferenceInput]?) async throws -> GeneratedImage { image }
}

@Suite("RouteExecutor")
struct RouteExecutorTests {
    private func routes(catalogue: Catalogue? = nil, rig: ORRig) throws -> [Resolution] {
        try ModelResolver.resolveAll(
            ResolveRequest(quality: "fast"), catalogue: catalogue ?? rig.store.snapshot(),
            providers: ["nano_banana", "openrouter"], live: rig.live.snapshot())
    }
    private func base(_ r: Resolution, budget: GenerationPolicy.BudgetContext? = nil) -> GenerationParams {
        GenerationParams(prompt: "p", model: r.imageModel, aspectRatio: .square, width: 1, height: 1, budget: budget)
    }

    @Test func t16_aNotFoundOnRouteOneUsesRouteTwoExactlyOnce() async throws {
        let rig = try await ORRig.make()
        let list = try routes(rig: rig)
        let google = ScriptedProvider(providerID: "nano_banana", failure: .modelUnavailable("gemini-3.1-flash-lite-image"))
        let openRouter = ScriptedProvider(providerID: "openrouter", failure: nil)
        let executor = RouteExecutor(providers: [google, openRouter])
        let outcome = try await executor.generate(routes: list, base: base(list[0]), references: nil)
        #expect(google.script.count == 1)
        #expect(openRouter.script.count == 1)
        #expect(openRouter.script.modelIDs == ["google/gemini-3.1-flash-lite-image"])
        #expect(outcome.route.provider == "openrouter")
        #expect(outcome.image.providerUsed == "openrouter")
        #expect(outcome.image.modelUsed == "google/gemini-3.1-flash-lite-image")   // the model that served, not the one asked
        #expect(outcome.image.estimatedCostGBP == list[1].estimateGBP)
        #expect(outcome.fallbackNotes.count == 1)
    }

    // The path the MCP uses: GenerationService with a router and routes. The executor tests above call
    // the executor directly, so a service that ignored `router` would pass them all.
    @Test func t16_theServiceFallsBackAndStoresWhatServedNotWhatWasAsked() async throws {
        let rig = try await ORRig.make()
        let list = try routes(rig: rig)
        let google = ScriptedProvider(providerID: "nano_banana", failure: .modelUnavailable("gemini-3.1-flash-lite-image"))
        let openRouter = ScriptedProvider(providerID: "openrouter", failure: nil)
        let db = try AppDatabase(path: ":memory:")
        let service = GenerationService(
            database: db, libraryURL: makeTempDirectory(), provider: google,
            router: RouteExecutor(providers: [google, openRouter]))
        let outcome = try await service.generate(GenerationService.Request(
            prompt: "p", model: list[0].imageModel, aspectRatio: .square, width: 1, height: 1, routes: list))

        #expect(google.script.count == 1)                       // route 1 was tried, once
        #expect(openRouter.script.count == 1)                   // and route 2 served
        let row = try #require(try await db.fetchAsset(id: outcome.assetID))
        #expect(row.providerID == "openrouter")
        #expect(row.modelID == "google/gemini-3.1-flash-lite-image")
        let expected = Double(truncating: list[1].estimateGBP as NSDecimalNumber)
        #expect(expected > 0)
        #expect(abs(try #require(row.estimatedCost) - expected) < 1e-9)
        let spend = try #require(try await db.fetchRecentSpendLog(limit: 1).first)
        #expect(spend.providerID == "openrouter")
        #expect(abs(try #require(spend.estimatedCost) - expected) < 1e-9)
        #expect(outcome.providerID == "openrouter")
        #expect(outcome.fallbackNotes.count == 1)

        // The pair: without routes the service calls its one provider and does not move.
        let single = GenerationService(
            database: db, libraryURL: makeTempDirectory(), provider: google,
            router: RouteExecutor(providers: [google, openRouter]))
        await #expect(throws: ProviderError.self) {
            try await single.generate(GenerationService.Request(
                prompt: "p", model: list[0].imageModel, aspectRatio: .square, width: 1, height: 1))
        }
        #expect(openRouter.script.count == 1)
    }

    @Test func aPaidImageTheLibraryRefusesStillRecordsItsSpendAndSaysSo() async throws {
        // Declared SVG, bytes are a PNG: AssetStore refuses. Both providers charge before that.
        for providerID in ["nano_banana", "openrouter"] {
            let paid = GeneratedImage(
                data: Data(base64Encoded: tinyPNGBase64)!, format: "svg", actualCost: Decimal(string: "0.05"),
                providerUsed: providerID, mimeType: "image/svg+xml")
            let db = try AppDatabase(path: ":memory:")
            let dir = makeTempDirectory()
            let service = GenerationService(database: db, libraryURL: dir, provider: FixedProvider(providerID: providerID, image: paid))
            let model = ImageModel(id: "some-model-aa", displayName: "M", supportedAspectRatios: [], costPerImage: Decimal(string: "0.03")!)
            do {
                _ = try await service.generate(GenerationService.Request(prompt: "p", model: model, aspectRatio: .square, width: 1, height: 1))
                Issue.record("\(providerID): the refusal should have thrown")
            } catch let error as GenerationServiceError {
                let message = error.localizedDescription
                #expect(message.contains("refused"))
                #expect(message.contains("0.0500"))             // the actual cost, in the message
                #expect(message.contains("recorded in Spend"))
            }
            // Nothing stored …
            let assets = (try? FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "assets").path)) ?? []
            #expect(assets.isEmpty)
            // … and the charge recorded, with the actual cost, and counted in the totals.
            let rows = try await db.read { db in
                try Row.fetchAll(db, sql: "SELECT provider_id, model_id, estimated_cost, actual_cost FROM refused_spend")
                    .map { ($0["provider_id"] as String?, $0["model_id"] as String?, $0["actual_cost"] as Double?) }
            }
            #expect(rows.count == 1)
            #expect(rows.first?.0 == providerID)
            #expect(rows.first?.1 == "some-model-aa")
            #expect(abs((rows.first?.2 ?? 0) - 0.05) < 1e-9)
            let summary = try await db.fetchSpendSummary(since: "2000-01-01", until: "2999-01-01")
            #expect(abs(summary.totalActual - 0.05) < 1e-9)
            #expect(summary.totalEstimated > 0)
        }
    }

    @Test func t16_theOtherTwoConditionsAlsoFallBack() async throws {
        let rig = try await ORRig.make()
        let list = try routes(rig: rig)
        for failure in [ProviderError.apiKeyNotFound, ProviderError.outOfCredit] {
            let google = ScriptedProvider(providerID: "nano_banana", failure: failure)
            let openRouter = ScriptedProvider(providerID: "openrouter", failure: nil)
            let outcome = try await RouteExecutor(providers: [google, openRouter]).generate(routes: list, base: base(list[0]), references: nil)
            #expect(outcome.route.provider == "openrouter", "\(failure)")
            #expect(google.script.count == 1 && openRouter.script.count == 1, "\(failure)")
        }
    }

    @Test func t16_anythingElseIsReportedAndNeverRetriedOnAnotherRoute() async throws {
        let rig = try await ORRig.make()
        let list = try routes(rig: rig)
        let others: [ProviderError] = [
            .badRequest("bad"), .invalidAPIKey, .rateLimited, .generationFailed("boom"),
            .networkError("offline"), .invalidResponse,
        ]
        for failure in others {
            let google = ScriptedProvider(providerID: "nano_banana", failure: failure)
            let openRouter = ScriptedProvider(providerID: "openrouter", failure: nil)
            do {
                _ = try await RouteExecutor(providers: [google, openRouter]).generate(routes: list, base: base(list[0]), references: nil)
                Issue.record("expected \(failure) to be thrown")
            } catch {
                #expect(error.localizedDescription == failure.localizedDescription, "\(failure)")
            }
            #expect(google.script.count == 1, "\(failure)")
            #expect(openRouter.script.count == 0, "\(failure)")          // the second route was never paid for
        }
    }

    @Test func t16_aConditionMovesARequestOnAtMostOnceAndTheLastRouteFailingIsReported() async throws {
        let rig = try await ORRig.make()
        // Three routes, all answering 404. A -> B is the one fallback this condition gets; C is not tried.
        let catalogue = try RepoCatalogue.parsed { root in
            setTierRoutes(&root, tier: "fast", [
                ["provider": "nano_banana", "model": "gemini-3.1-flash-lite-image", "usdEstimate": 0.0336],
                ["provider": "openrouter", "model": "google/gemini-3.1-flash-lite-image", "usdEstimate": 0.0336],
                ["provider": "openrouter", "model": "google/gemini-3.1-flash-image", "usdEstimate": 0.0336],
            ])
        }
        let list = try routes(catalogue: catalogue, rig: rig)
        #expect(list.count == 3)
        let google = ScriptedProvider(providerID: "nano_banana", failure: .modelUnavailable("x"))
        let openRouter = ScriptedProvider(providerID: "openrouter", failure: .modelUnavailable("y"))
        do {
            _ = try await RouteExecutor(providers: [google, openRouter]).generate(routes: list, base: base(list[0]), references: nil)
            Issue.record("expected modelUnavailable")
        } catch ProviderError.modelUnavailable(let id) {
            #expect(id == "y")                                   // route two's error, not a loop
        }
        #expect(google.script.count == 1)
        #expect(openRouter.script.count == 1)                    // route three (also OpenRouter) was not tried
        // The pair: a different condition on route two does move on to route three.
        let credit = ScriptedProvider(providerID: "openrouter", failure: .outOfCredit)
        do {
            _ = try await RouteExecutor(providers: [ScriptedProvider(providerID: "nano_banana", failure: .modelUnavailable("x")), credit])
                .generate(routes: list, base: base(list[0]), references: nil)
            Issue.record("expected outOfCredit")
        } catch ProviderError.outOfCredit {}
        #expect(credit.script.count == 2)                        // route two (402) then route three (402, last)
    }

    @Test func aFallbackRouteIsBudgetCheckedAtItsOwnPriceBeforeAnythingIsSent() async throws {
        let rig = try await ORRig.make()
        func executor(openRouterUSD: Double) async throws -> (RouteExecutor, [Resolution], ScriptedProvider) {
            let catalogue = try RepoCatalogue.parsed { root in
                setTierRoutes(&root, tier: "fast", [
                    ["provider": "nano_banana", "model": "gemini-3.1-flash-lite-image", "usdEstimate": 0.0336],
                    ["provider": "openrouter", "model": "google/gemini-3.1-flash-lite-image", "usdEstimate": openRouterUSD],
                ])
            }
            let list = try routes(catalogue: catalogue, rig: rig)
            let or = ScriptedProvider(providerID: "openrouter", failure: nil)
            return (RouteExecutor(providers: [ScriptedProvider(providerID: "nano_banana", failure: .modelUnavailable("x")), or]), list, or)
        }
        let budget = GenerationPolicy.BudgetContext(count: 1, limits: .init(maxImages: 5, maxCostGBP: Decimal(string: "0.50")!))
        // 0.90 USD x 0.79 = £0.711: over the £0.50 the first route was gated against.
        let (dear, dearList, dearOR) = try await executor(openRouterUSD: 0.90)
        await #expect(throws: GenerationPolicy.BudgetViolation.self) {
            try await dear.generate(routes: dearList, base: base(dearList[0], budget: budget), references: nil)
        }
        #expect(dearOR.script.count == 0)
        // The pair: at 0.0336 USD the same fallback is inside the budget and goes ahead.
        let (cheap, cheapList, cheapOR) = try await executor(openRouterUSD: 0.0336)
        _ = try await cheap.generate(routes: cheapList, base: base(cheapList[0], budget: budget), references: nil)
        #expect(cheapOR.script.count == 1)
    }

    @Test func aNotFoundOnOpenRouterAsksForOneLiveListRefresh() async throws {
        let list = StubSession(status: 200, body: try ORFixture.list())
        let live = OpenRouterModelStore(directory: makeTempDirectory(), session: list.session)
        await live.refresh()
        let before = list.requests.count
        let rig = try await ORRig.make()
        let catalogue = try RepoCatalogue.parsed { root in
            setTierRoutes(&root, tier: "fast", [
                ["provider": "openrouter", "model": "google/gemini-3.1-flash-lite-image", "usdEstimate": 0.0336],
                ["provider": "nano_banana", "model": "gemini-3.1-flash-lite-image", "usdEstimate": 0.0336],
            ])
        }
        let routes = try ModelResolver.resolveAll(ResolveRequest(quality: "fast"), catalogue: catalogue,
                                                  providers: ["nano_banana", "openrouter"], live: rig.live.snapshot())
        let or = ScriptedProvider(providerID: "openrouter", failure: .modelUnavailable("m"))
        let google = ScriptedProvider(providerID: "nano_banana", failure: nil)
        _ = try await RouteExecutor(providers: [or, google], liveModels: live).generate(routes: routes, base: base(routes[0]), references: nil)
        #expect(list.requests.count == before + 1)
        #expect(google.script.count == 1)
    }
}
