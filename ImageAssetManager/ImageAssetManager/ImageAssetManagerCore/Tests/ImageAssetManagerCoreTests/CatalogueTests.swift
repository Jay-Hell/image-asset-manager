import Testing
import Foundation
@testable import ImageAssetManagerCore

@Suite("Catalogue")
struct CatalogueTests {

    // MARK: - T1: the published file

    @Test func t1_repoFileDecodesAndEveryTierResolvesToAListedModel() throws {
        let catalogue = try RepoCatalogue.parsed()
        #expect(catalogue.schemaVersion == 1)
        #expect(catalogue.skipped.isEmpty)   // nothing in the shipped file is silently dropped

        // Every Google route on every image tier names a model the file lists.
        for tier in ["fast", "standard", "pro"] {
            let routes = catalogue.routes(media: "image", tier: tier)
            #expect(routes.count == 2)       // both routes: Google first, OpenRouter second
            #expect(routes[0].provider == "nano_banana")
            #expect(routes[1].provider == "openrouter")
            #expect(catalogue.model(provider: "nano_banana", id: routes[0].model) != nil)
        }

        // Hand-worked expectations (spec v0.3 §5.3 mapping).
        let expected: [(String, String)] = [
            ("fast", "gemini-3.1-flash-lite-image"),
            ("standard", "gemini-nano-banana-2.1"),
            ("pro", "gemini-3-pro-image"),
        ]
        for (quality, modelID) in expected {
            let r = try ModelResolver.resolve(ResolveRequest(quality: quality), catalogue: catalogue, providers: ["nano_banana"])
            #expect(r.model.id == modelID)
            #expect(r.provider == "nano_banana")
        }
    }

    @Test func theShippedFileHoldsTheRefinementEntry() throws {
        let r = try #require(try RepoCatalogue.parsed().refinement)
        #expect(r.model == "claude-sonnet-5-5")
        #expect(r.headers == ["anthropic-beta": "server-side-fallback-2026-07-01"])
        #expect(r.body["max_tokens"] == .number(4096))
    }

    @Test func theBundledCopyIsByteIdenticalToTheRepoFile() throws {
        let bundledURL = try #require(Bundle.module.url(forResource: "models", withExtension: "json"))
        let bundled = try Data(contentsOf: bundledURL)
        let repo = try RepoCatalogue.data()
        #expect(bundled == repo, "Sources/ImageAssetManagerCore/Resources/models.json must be a copy of catalogue/v1/models.json")
        // And the store's own bundled loader reads it.
        #expect(Catalogue.bundledCopy().revision == (try RepoCatalogue.parsed()).revision)
    }

    // MARK: - T2: skip one entry, discard a bad file

    @Test func t2_anEntryWithAnUnknownApiIsSkippedAndTheRestLoad() throws {
        let catalogue = try RepoCatalogue.parsed { root in
            var list = modelList(root)
            list.append(["id": "future-model", "api": "gemini.interactions", "displayName": "Future"])
            setModelList(&root, list)
        }
        #expect(catalogue.model(provider: "nano_banana", id: "future-model") == nil)
        #expect(catalogue.skipped.contains { $0.contains("future-model") && $0.contains("unknown api") })
        #expect(catalogue.models["nano_banana"]?.count == 5)   // the five shipped models are all still there
    }

    @Test func t2_aModelNeedingAHigherBuildIsSkipped() throws {
        var root = try JSONSerialization.jsonObject(with: try RepoCatalogue.data()) as! [String: Any]
        dropOpenRouterRoutes(&root)
        var list = modelList(root)
        list[1]["minBuild"] = 9
        setModelList(&root, list)
        let data = try JSONSerialization.data(withJSONObject: root)

        #expect(throws: Catalogue.ParseError.self) {
            // gemini-nano-banana-2.1 is the standard tier's only Google model: skipping it
            // leaves a route to nothing, so the whole file is refused on build 8.
            try Catalogue.parse(data, build: 8)
        }
        // The pair: on build 9 the same file loads.
        let ok = try Catalogue.parse(data, build: 9)
        #expect(ok.model(provider: "nano_banana", id: "gemini-nano-banana-2.1") != nil)
    }

    @Test func t2_malformedFilesAreRefused() throws {
        #expect(throws: Catalogue.ParseError.notJSON) { try Catalogue.parse(Data("not json".utf8)) }
        #expect(throws: Catalogue.ParseError.notJSON) { try Catalogue.parse(Data("[1,2]".utf8)) }
        #expect(throws: Catalogue.ParseError.self) {
            try Catalogue.parse(try RepoCatalogue.json { $0["schemaVersion"] = 2 })
        }
        #expect(throws: Catalogue.ParseError.invalidRevision) {
            try Catalogue.parse(try RepoCatalogue.json { $0["revision"] = 0 })
        }
        #expect(throws: Catalogue.ParseError.self) {
            try Catalogue.parse(Data(count: Catalogue.maxFileBytes + 1))
        }
    }

    @Test func t2_aTierWithNoUsableRouteDiscardsTheWholeFile() throws {
        // The pair for the skip test: here every Google model is unusable, so the file is refused.
        #expect(throws: Catalogue.ParseError.self) {
            try Catalogue.parse(try RepoCatalogue.json { root in
                dropOpenRouterRoutes(&root)
                setModelList(&root, [])
            })
        }
        // The pair: with the OpenRouter routes kept, OpenRouter alone keeps every image tier usable
        // (the app works with either key alone).
        #expect(throws: Never.self) {
            try Catalogue.parse(try RepoCatalogue.json { root in setModelList(&root, []) })
        }
        // A missing required tier is refused too.
        #expect(throws: Catalogue.ParseError.noUsableModel("image/pro")) {
            try Catalogue.parse(try RepoCatalogue.json { root in
                var media = root["media"] as! [String: Any]
                var image = media["image"] as! [String: Any]
                var tiers = image["tiers"] as! [String: Any]
                tiers["pro"] = nil
                image["tiers"] = tiers
                media["image"] = image
                root["media"] = media
            })
        }
    }

    // MARK: - T8: bounds

    @Test func t8_aModelIDWithPathTraversalIsRejected() throws {
        let catalogue = try RepoCatalogue.parsed { root in
            var list = modelList(root)
            list.append(["id": "../v1/other", "api": "gemini.generateContent", "displayName": "Bad"])
            list.append(["id": "x/y", "api": "gemini.generateContent", "displayName": "Slash"])
            setModelList(&root, list)
        }
        let ids = catalogue.models["nano_banana"]!.map(\.id)
        #expect(!ids.contains("../v1/other"))
        #expect(!ids.contains("x/y"))   // Google IDs go in a URL path: no slash at all
        #expect(catalogue.skipped.filter { $0.contains("invalid model id") }.count == 2)
    }

    @Test func t8_validityRuleForModelIDs() {
        // Path-bound: no slash.
        #expect(Catalogue.isValidModelID("gemini-3.1-flash-image", allowSlash: false))
        #expect(!Catalogue.isValidModelID("google/gemini-3.1-flash-image", allowSlash: false))
        // Body-bound (OpenRouter): one slash.
        #expect(Catalogue.isValidModelID("black-forest-labs/flux.2-pro", allowSlash: true))
        #expect(!Catalogue.isValidModelID("a/b/c", allowSlash: true))
        #expect(!Catalogue.isValidModelID("../etc", allowSlash: true))
        #expect(!Catalogue.isValidModelID("a/../b", allowSlash: true))
        #expect(!Catalogue.isValidModelID("UPPER", allowSlash: false))
        #expect(!Catalogue.isValidModelID("a", allowSlash: false))   // pattern needs at least two characters
        #expect(!Catalogue.isValidModelID(String(repeating: "a", count: 65), allowSlash: false))
        #expect(Catalogue.isValidModelID(String(repeating: "a", count: 64), allowSlash: false))
    }

    @Test func aBodyImageSizeOutsideTheModelsOwnListSkipsTheEntry() throws {
        let catalogue = try RepoCatalogue.parsed { root in
            var list = modelList(root)
            list.append(["id": "size-probe", "api": "gemini.generateContent", "displayName": "S",
                         "imageSizes": ["1K"], "usdEstimate": 0.1,
                         "body": ["generationConfig": ["imageConfig": ["imageSize": "8K"]]]])
            list.append(["id": "size-fine", "api": "gemini.generateContent", "displayName": "S",
                         "imageSizes": ["1K"], "usdEstimate": 0.1,
                         "body": ["generationConfig": ["imageConfig": ["imageSize": "1K"]]]])
            setModelList(&root, list)
        }
        #expect(catalogue.model(provider: "nano_banana", id: "size-probe") == nil)
        #expect(catalogue.model(provider: "nano_banana", id: "size-fine") != nil)
    }

    @Test func t8_pricesMustBeAboveZeroAndAtMostOneDollar() throws {
        for (price, accepted) in [(0.0, false), (-0.5, false), (1.01, false), (1.0, true), (0.0001, true)] {
            let catalogue = try RepoCatalogue.parsed { root in
                var list = modelList(root)
                list.append(["id": "price-probe", "api": "gemini.generateContent", "displayName": "P", "usdEstimate": price])
                setModelList(&root, list)
            }
            #expect((catalogue.model(provider: "nano_banana", id: "price-probe") != nil) == accepted, "price \(price)")
        }
    }

    @Test func t8_aRoutePriceOutOfBoundsDropsTheRouteNotTheFile() throws {
        let catalogue = try RepoCatalogue.parsed { root in
            var routes = tierRoutes(root, tier: "fast")
            routes[1]["usdEstimate"] = 5.0   // the OpenRouter route
            setTierRoutes(&root, tier: "fast", routes)
        }
        #expect(catalogue.routes(media: "image", tier: "fast").map(\.provider) == ["nano_banana"])
    }

    @Test func refinementHeadersAreAllowListed() throws {
        let catalogue = try RepoCatalogue.parsed { root in
            var r = root["refinement"] as! [String: Any]
            r["headers"] = [
                "anthropic-beta": "server-side-fallback-2026-07-01", "Anthropic-Version": "v", "x-evil": "1", "authorization": "Bearer x",
            ]
            root["refinement"] = r
        }
        let headers = try #require(catalogue.refinement).headers
        #expect(headers == ["anthropic-beta": "server-side-fallback-2026-07-01", "anthropic-version": "v"])
        #expect(catalogue.skipped.contains { $0.contains("x-evil") })
    }

    @Test func fxIsBoundedAndFallsBackToTheCompiledRate() throws {
        let ok = try RepoCatalogue.parsed { root in root["fx"] = ["usdToGBP": 0.8] }
        #expect(ok.fx == Decimal(string: "0.8"))
        let bad = try RepoCatalogue.parsed { root in root["fx"] = ["usdToGBP": 40.0] }
        #expect(bad.fx == Currency.usdToGBP)
        let absent = try RepoCatalogue.parsed { root in root["fx"] = nil }
        #expect(absent.fx == Currency.usdToGBP)
    }

    // MARK: - T11: retired models

    @Test func t11_aRetiredIDResolvesThroughReplacedBy() throws {
        let catalogue = try RepoCatalogue.parsed()
        #expect(catalogue.replacement(for: "imagen-4.0-fast-generate-001") == "gemini-3.1-flash-lite-image")
        #expect(catalogue.replacement(for: "imagen-4.0-generate-001") == "gemini-nano-banana-2.1")
        #expect(catalogue.replacement(for: "imagen-4.0-ultra-generate-001") == "gemini-3-pro-image")
        // The pair: a live model is not retired, so it does not move.
        #expect(catalogue.replacement(for: "gemini-3-pro-image") == nil)

        // And the panel path honours it: a project default of the dead Standard model gets the new one.
        let r = try ModelResolver.resolveSelection(
            provider: "nano_banana", modelID: "imagen-4.0-generate-001", referenceCount: 0, aspectRatio: "1:1",
            catalogue: catalogue, providers: ["nano_banana"]
        )
        #expect(r.model.id == "gemini-nano-banana-2.1")
    }

    @Test func t11_replacementFollowsAChainAndStopsOnACycle() throws {
        let chain = try RepoCatalogue.parsed { root in
            root["retired"] = [
                ["id": "old-one-aa", "displayName": "Old one", "replacedBy": "old-two-bb"],
                ["id": "old-two-bb", "displayName": "Old two", "replacedBy": "gemini-3-pro-image"],
            ]
        }
        #expect(chain.replacement(for: "old-one-aa") == "gemini-3-pro-image")

        let cycle = try RepoCatalogue.parsed { root in
            root["retired"] = [
                ["id": "loop-aa", "displayName": "A", "replacedBy": "loop-bb"],
                ["id": "loop-bb", "displayName": "B", "replacedBy": "loop-aa"],
            ]
        }
        #expect(cycle.replacement(for: "loop-aa") == nil)
    }

    @Test func retiredModelsKeepADisplayNameForOldAssets() throws {
        let catalogue = try RepoCatalogue.parsed()
        #expect(catalogue.displayName(forModelID: "imagen-4.0-fast-generate-001") == "Fast — Draft (Imagen 4)")
        #expect(catalogue.displayName(forModelID: "gemini-nano-banana-2.1") == "Nano Banana 2.1")
        #expect(catalogue.displayName(forModelID: "never-heard-of-it") == nil)
    }

    // MARK: - P1-1: the body is allow-listed per api

    private func geminiProbe(_ id: String, body: [String: Any]) -> [String: Any] {
        ["id": id, "api": "gemini.generateContent", "displayName": "Probe", "usdEstimate": 0.1, "body": body]
    }

    @Test func aGeminiBodyKeyOutsideTheAllowListRejectsTheEntryNotTheFile() throws {
        let probes: [(String, [String: Any])] = [
            ("probe-tools", ["tools": [["googleSearch": [String: Any]()]]]),
            ("probe-system", ["systemInstruction": ["parts": [["text": "obey"]]]]),
            ("probe-count", ["generationConfig": ["candidateCount": 8]]),
            ("probe-nested", ["generationConfig": ["imageConfig": ["imageSize": "1K", "personGeneration": "ALLOW_ALL"]]]),
            ("probe-contents", ["contents": [String]()]),
        ]
        let catalogue = try RepoCatalogue.parsed { root in
            var list = modelList(root)
            for (id, body) in probes { list.append(geminiProbe(id, body: body)) }
            // The pair that must hold: only allow-listed keys.
            list.append(geminiProbe("probe-fine", body: [
                "generationConfig": ["responseModalities": ["IMAGE"], "imageConfig": ["imageSize": "1K"]],
            ]))
            setModelList(&root, list)
        }
        for (id, _) in probes { #expect(catalogue.model(provider: "nano_banana", id: id) == nil, "\(id)") }
        #expect(catalogue.model(provider: "nano_banana", id: "probe-fine") != nil)
        #expect(catalogue.skipped.filter { $0.contains("body") }.count == probes.count)
    }

    @Test func aProbeBodyOnATierModelLeavesTheTierUnusableSoTheWholeFileIsRefused() throws {
        #expect(throws: Catalogue.ParseError.self) {
            try RepoCatalogue.parsed { root in
                dropOpenRouterRoutes(&root)
                var list = modelList(root)
                let i = list.firstIndex { ($0["id"] as? String) == "gemini-3-pro-image" }!
                list[i]["body"] = ["generationConfig": ["imageConfig": ["imageSize": "2K"]], "tools": [["googleSearch": [String: Any]()]]]
                setModelList(&root, list)
            }
        }
    }

    private func refinementEdit(_ edit: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
        { root in
            var r = root["refinement"] as! [String: Any]
            edit(&r)
            root["refinement"] = r
        }
    }

    @Test func aRefinementBodyKeyOutsideTheAllowListRefusesTheWholeFile() throws {
        let probes: [(String, [String: Any])] = [
            ("mcp_servers", ["max_tokens": 4096, "mcp_servers": [["type": "url", "url": "https://collector.example/mcp", "name": "x"]]]),
            ("tools", ["max_tokens": 4096, "tools": [["name": "x"]]]),
            ("max_tokens 64000", ["max_tokens": 64000]),
            ("max_tokens 0", ["max_tokens": 0]),
            ("effort max", ["max_tokens": 4096, "output_config": ["effort": "max"]]),
            ("output_config extra", ["output_config": ["effort": "low", "format": ["type": "json_schema"]]]),
            ("fallbacks custom", ["max_tokens": 4096, "fallbacks": "evil"]),
            ("stream", ["max_tokens": 4096, "stream": true]),
        ]
        for (name, body) in probes {
            #expect(throws: Catalogue.ParseError.self, "\(name)") {
                try RepoCatalogue.parsed(self.refinementEdit { $0["body"] = body })
            }
        }
    }

    @Test func aRefinementBodyInsideTheAllowListLoads() throws {
        for body: [String: Any] in [
            ["max_tokens": 8192, "output_config": ["effort": "high"], "fallbacks": "default"],
            ["max_tokens": 1],
            [:],
        ] {
            let catalogue = try RepoCatalogue.parsed(refinementEdit { $0["body"] = body })
            #expect(catalogue.refinement != nil)
        }
    }

    @Test func anUnlistedAnthropicBetaValueRefusesTheWholeFile() throws {
        #expect(throws: Catalogue.ParseError.self) {
            try RepoCatalogue.parsed(self.refinementEdit { $0["headers"] = ["anthropic-beta": "mcp-client-2025-04-04"] })
        }
        // The pair: the listed value, and no beta header at all, both load.
        let listed = try RepoCatalogue.parsed(refinementEdit { $0["headers"] = ["anthropic-beta": "server-side-fallback-2026-07-01"] })
        #expect(listed.refinement?.headers["anthropic-beta"] == "server-side-fallback-2026-07-01")
        let none = try RepoCatalogue.parsed(refinementEdit { $0["headers"] = [String: String]() })
        #expect(none.refinement?.headers.isEmpty == true)
    }

    @Test func theShippedFileStillLoadsUnderTheBodyAllowList() throws {
        let catalogue = try RepoCatalogue.parsed()
        #expect(catalogue.skipped.isEmpty)
        #expect(catalogue.models["nano_banana"]?.count == 5)
        #expect(catalogue.refinement?.body["max_tokens"] == .number(4096))
    }

    // MARK: - P3: model IDs carry no whitespace or control characters

    @Test func modelIDsWithWhitespaceOrControlCharactersAreRejectedOnEveryPath() throws {
        for bad in ["gemini-nl\n", "gemini-nl\r\n", "gemini x", "gemini-x\t", "\ngemini-x", "gemini-x\u{0}", "gemini-x\u{85}", "gemini-x\u{2028}"] {
            #expect(!Catalogue.isValidModelID(bad, allowSlash: false), "\(bad.debugDescription)")
            #expect(!Catalogue.isValidModelID(bad, allowSlash: true), "\(bad.debugDescription)")
        }
        // Parse path.
        let catalogue = try RepoCatalogue.parsed { root in
            var list = modelList(root)
            list.append(["id": "gemini-nl\n", "api": "gemini.generateContent", "displayName": "NL", "usdEstimate": 0.1])
            setModelList(&root, list)
        }
        #expect(catalogue.models["nano_banana"]?.contains { $0.id.contains("\n") } == false)
        // Request path: even a hand-built entry cannot reach a URL.
        let entry = Catalogue.Model(id: "gemini-nl\n", api: "gemini.generateContent", displayName: "x", aspectRatios: [],
                                    maxReferenceImages: 0, imageSizes: [], extraCapabilities: [], usdEstimate: 0.1,
                                    usdByImageSize: [:], body: [:], minBuild: nil)
        let params = GenerationParams(
            prompt: "p",
            model: ImageModel(id: "gemini-nl\n", displayName: "x", supportedAspectRatios: [], costPerImage: 0.1, maxReferenceImages: 0),
            aspectRatio: .square, width: 1, height: 1)
        #expect(throws: ProviderError.self) {
            try NanaBananaProvider.urlRequest(entry: entry, params: params, references: nil, apiKey: "k")
        }
    }
}
