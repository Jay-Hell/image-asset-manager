import Testing
import Foundation
@testable import ImageAssetManagerCore

/// A provider wired to a fake Google and a fake catalogue host.
private struct ProviderRig {
    let google: StubSession
    let remote: StubSession
    let store: CatalogueStore
    let provider: NanaBananaProvider

    init(
        catalogue: Catalogue? = nil,
        remoteBody: Data? = nil,
        apiKey: @escaping @Sendable () throws -> String = { "test-key-123" },
        google handler: @escaping StubSession.Handler
    ) throws {
        google = StubSession(handler)
        let body = remoteBody ?? Data()
        remote = StubSession(status: remoteBody == nil ? 404 : 200, body: body)
        store = CatalogueStore(
            bundled: try catalogue ?? RepoCatalogue.parsed(),
            directory: makeTempDirectory(),
            remoteURL: URL(string: "https://example.test/models.json")!,
            session: remote.session,
            build: 0
        )
        provider = NanaBananaProvider(catalogue: store, apiKey: apiKey)
    }

    func params(quality: String = "standard", aspect: AspectRatio = .square, resolution: String? = nil,
                prompt: String = "A test landscape", negative: String? = nil,
                catalogue: Catalogue? = nil) throws -> GenerationParams {
        let res = try ModelResolver.resolve(
            ResolveRequest(quality: quality, aspectRatio: aspect.rawValue, resolution: resolution),
            catalogue: catalogue ?? store.snapshot(), providers: ["nano_banana"])
        return GenerationParams(prompt: prompt, negativePrompt: negative, model: res.imageModel,
                                aspectRatio: aspect, width: 1024, height: 1024)
    }
}

private func ok() -> StubSession.Handler { { _ in (200, geminiSuccessBody(), [:]) } }

private func reference(_ id: String) -> ReferenceInput {
    ReferenceInput(assetID: id, imageData: Data([1, 2, 3]), role: .subjectAnchor)
}

@Suite("NanaBananaProvider")
struct NanaBananaProviderTests {

    // MARK: - Catalogue-driven models

    @Test func theModelListComesFromTheCatalogueInTierOrderWithGBPPrices() throws {
        let rig = try ProviderRig(google: ok())
        let models = rig.provider.availableModels
        #expect(models.map(\.id) == [
            "gemini-3.1-flash-lite-image", "gemini-nano-banana-2.1", "gemini-3-pro-image",
            "gemini-3.1-flash-image", "gemini-2.5-flash-image",
        ])
        // Hand-worked: USD x 0.79.
        #expect(models[0].costPerImage == Decimal(string: "0.026544"))
        #expect(models[2].costPerImage == Decimal(string: "0.10586"))
        #expect(models[4].costPerImage == Decimal(string: "0.03081"))
        #expect(models.map(\.id).allSatisfy { !$0.contains("imagen") })
        #expect(rig.provider.maxReferenceImages == 14)
        #expect(rig.provider.providerID == "nano_banana")
    }

    @Test func aNewCatalogueRevisionChangesTheListWithoutAnyCodeChange() async throws {
        let rig = try ProviderRig(
            remoteBody: try RepoCatalogue.json { root in
                root["revision"] = 2
                var list = modelList(root)
                list.append(["id": "gemini-brand-new", "api": "gemini.generateContent", "displayName": "Brand New",
                             "aspectRatios": ["1:1"], "maxReferenceImages": 2, "usdEstimate": 0.5])
                setModelList(&root, list)
            },
            google: ok())
        #expect(!rig.provider.availableModels.map(\.id).contains("gemini-brand-new"))
        await rig.store.refresh()
        #expect(rig.provider.availableModels.map(\.id).last == "gemini-brand-new")
    }

    // MARK: - T5: the request that leaves the process

    @Test func t5_theRequestCarriesTheCatalogueModelInThePathAndItsImageSizeInTheBody() async throws {
        let rig = try ProviderRig(google: ok())
        let params = try rig.params(quality: "standard", aspect: .landscape)

        _ = try await rig.provider.generate(params, references: nil, session: rig.google.session)

        let sent = try #require(rig.google.requests.first)
        #expect(rig.google.requests.count == 1)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString ==
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-nano-banana-2.1:generateContent")
        #expect(sent.headers["x-goog-api-key"] == "test-key-123")
        #expect(!sent.url.absoluteString.contains("test-key-123"))   // never in the URL
        #expect(sent.headers["content-type"] == "application/json")

        let body = try #require(sent.bodyJSON)
        let config = try #require(body["generationConfig"] as? [String: Any])
        #expect(config["responseModalities"] as? [String] == ["IMAGE"])
        let image = try #require(config["imageConfig"] as? [String: Any])
        #expect(image["imageSize"] as? String == "1K")
        #expect(image["aspectRatio"] as? String == "16:9")
        let contents = try #require(body["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        #expect(parts.count == 1)
        #expect(parts[0]["text"] as? String == "A test landscape")
    }

    @Test func t5_everyTierGoesToGenerateContentNeverPredict() async throws {
        let rig = try ProviderRig(google: ok())
        for quality in ["fast", "standard", "pro"] {
            _ = try await rig.provider.generate(try rig.params(quality: quality), references: nil, session: rig.google.session)
        }
        let paths = rig.google.requests.map(\.url.path)
        #expect(paths == [
            "/v1beta/models/gemini-3.1-flash-lite-image:generateContent",
            "/v1beta/models/gemini-nano-banana-2.1:generateContent",
            "/v1beta/models/gemini-3-pro-image:generateContent",
        ])
        #expect(!paths.contains { $0.contains(":predict") })
    }

    @Test func t5_theProTierSendsItsOwn2KAndARequestedResolutionBeatsTheCatalogueDefault() async throws {
        let rig = try ProviderRig(google: ok())
        _ = try await rig.provider.generate(try rig.params(quality: "pro"), references: nil, session: rig.google.session)
        _ = try await rig.provider.generate(try rig.params(quality: "standard", resolution: "4K"), references: nil, session: rig.google.session)

        func size(_ i: Int) throws -> String? {
            let config = try #require(rig.google.requests[i].bodyJSON?["generationConfig"] as? [String: Any])
            return (config["imageConfig"] as? [String: Any])?["imageSize"] as? String
        }
        #expect(try size(0) == "2K")
        #expect(try size(1) == "4K")   // the entry's body says 1K; the request wins
    }

    @Test func t5_appOwnedFieldsBeatAnythingTheCatalogueBodySays() async throws {
        // The parser now refuses most of this (see CatalogueTests); the request builder still
        // defends itself, so the entry is built by hand to reach it.
        let hostile = Catalogue.Model(
            id: "gemini-nano-banana-2.1", api: "gemini.generateContent", displayName: "x", aspectRatios: ["9:16"],
            maxReferenceImages: 14, imageSizes: ["1K", "2K", "4K"], extraCapabilities: [], usdEstimate: 0.1, usdByImageSize: [:],
            body: [
                "contents": .string("overwritten by the catalogue"),
                "generationConfig": .object([
                    "responseModalities": .array([.string("TEXT")]),
                    "imageConfig": .object(["aspectRatio": .string("21:9"), "imageSize": .string("2K")]),
                    "topK": .number(7),
                ]),
            ], minBuild: nil)
        let rig = try ProviderRig(google: ok())
        let params = try rig.params(quality: "standard", aspect: .portrait, resolution: "4K", prompt: "owned prompt", negative: "no cats")
        let built = try NanaBananaProvider.urlRequest(entry: hostile, params: params, references: nil, apiKey: "k")

        let sentData = try #require(built.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: sentData) as? [String: Any])
        let contents = try #require(body["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        #expect(parts[0]["text"] as? String == "owned prompt\n\nAvoid: no cats")
        let config = try #require(body["generationConfig"] as? [String: Any])
        #expect(config["responseModalities"] as? [String] == ["IMAGE"])
        let image = try #require(config["imageConfig"] as? [String: Any])
        #expect(image["aspectRatio"] as? String == "9:16")
        #expect(image["imageSize"] as? String == "4K")      // the request's size, not the catalogue's "2K"
        // The pair: a catalogue field the app does not own still flows through.
        #expect(config["topK"] as? Int == 7)
    }

    // MARK: - Reference cap comes from the model entry

    @Test func theReferenceCapIsTheModelEntrysNotAFixedThree() async throws {
        let rig = try ProviderRig(google: ok())
        let refs = (1...5).map { reference("r\($0)") }

        // Standard: 14. All five go.
        _ = try await rig.provider.generate(try rig.params(quality: "standard"), references: refs, session: rig.google.session)
        // Gemini 2.5 Flash Image: 3. Only three go.
        let old = try ModelResolver.resolve(ResolveRequest(explicitModel: "nano_banana:gemini-2.5-flash-image"),
                                            catalogue: rig.store.snapshot(), providers: ["nano_banana"])
        let oldParams = GenerationParams(prompt: "p", model: old.imageModel, aspectRatio: .square, width: 1, height: 1)
        _ = try await rig.provider.generate(oldParams, references: refs, session: rig.google.session)

        func inlineCount(_ i: Int) throws -> Int {
            let contents = try #require(rig.google.requests[i].bodyJSON?["contents"] as? [[String: Any]])
            let parts = try #require(contents.first?["parts"] as? [[String: Any]])
            return parts.filter { $0["inlineData"] != nil }.count
        }
        #expect(try inlineCount(0) == 5)
        #expect(try inlineCount(1) == 3)
    }

    // MARK: - Response: image, seed, cost

    @Test func theImageSeedAndCostAreParsedFromTheResponse() async throws {
        // usage.cost 0.04 USD x 0.79 = 0.0316 GBP.
        let body = geminiSuccessBody(top: ["seed": 12345, "usage": ["cost": 0.04]])
        let rig = try ProviderRig(google: { _ in (200, body, [:]) })
        let result = try await rig.provider.generate(try rig.params(), references: nil, session: rig.google.session)
        #expect(result.format == "png")
        #expect(!result.data.isEmpty)
        #expect(result.seed == "12345")
        #expect(result.actualCost == Decimal(string: "0.0316"))
    }

    @Test func aResponseWithNoSeedOrCostLeavesBothEmpty() async throws {
        let rig = try ProviderRig(google: ok())
        let result = try await rig.provider.generate(try rig.params(), references: nil, session: rig.google.session)
        #expect(result.seed == nil)
        #expect(result.actualCost == nil)
    }

    @Test func aThoughtImageIsSkippedForTheFinalOne() async throws {
        let thought: [String: Any] = ["thought": true, "inlineData": ["mimeType": "image/jpeg", "data": "AAAA"]]
        let body = geminiSuccessBody(extraParts: [thought])
        let rig = try ProviderRig(google: { _ in (200, body, [:]) })
        let result = try await rig.provider.generate(try rig.params(), references: nil, session: rig.google.session)
        #expect(result.format == "png")   // the final image, not the jpeg thought
    }

    @Test func aResponseWithNoImageIsInvalid() async throws {
        let rig = try ProviderRig(google: { _ in (200, Data(#"{"candidates":[{"content":{"parts":[{"text":"sorry"}]}}]}"#.utf8), [:]) })
        await #expect(throws: ProviderError.self) {
            try await rig.provider.generate(try rig.params(), references: nil, session: rig.google.session)
        }
    }

    // MARK: - Keys

    @Test func aMissingKeyStopsBeforeAnyRequest() async throws {
        let rig = try ProviderRig(apiKey: { throw KeychainService.KeychainError.itemNotFound }, google: ok())
        do {
            _ = try await rig.provider.generate(try rig.params(), references: nil, session: rig.google.session)
            Issue.record("expected apiKeyNotFound")
        } catch ProviderError.apiKeyNotFound {
            #expect(rig.google.requests.isEmpty)
        }
    }

    // MARK: - T9: errors

    @Test func t9_a404RaisesModelUnavailableAfterOneRefreshAndOneRetry() async throws {
        let rig = try ProviderRig(remoteBody: try RepoCatalogue.json { $0["revision"] = 2 }, google: { _ in (404, Data(), [:]) })
        do {
            _ = try await rig.provider.generate(try rig.params(), references: nil, session: rig.google.session)
            Issue.record("expected modelUnavailable")
        } catch ProviderError.modelUnavailable(let id) {
            #expect(id == "gemini-nano-banana-2.1")
        }
        #expect(rig.google.requests.count == 2)   // the call and one retry, no more
        #expect(rig.remote.requests.count == 1)   // one forced catalogue refresh
        #expect(rig.store.status().revision == 2)
    }

    @Test func t9_theRetryRecoversWhenTheRefreshedCatalogueRetiresTheModel() async throws {
        // Google 404s the old model; the fresh catalogue retires it in favour of another.
        let fresh = try RepoCatalogue.json { root in
            root["revision"] = 2
            let kept = modelList(root).filter { ($0["id"] as? String) != "gemini-3.1-flash-image" }
            setModelList(&root, kept)
            root["retired"] = (root["retired"] as! [[String: Any]]) + [
                ["id": "gemini-3.1-flash-image", "displayName": "Gone", "replacedBy": "gemini-nano-banana-2.1"],
            ]
        }
        let rig = try ProviderRig(remoteBody: fresh, google: { request in
            request.url.path.contains("gemini-3.1-flash-image") ? (404, Data(), [:]) : (200, geminiSuccessBody(), [:])
        })
        let old = try ModelResolver.resolve(ResolveRequest(explicitModel: "nano_banana:gemini-3.1-flash-image"),
                                            catalogue: rig.store.snapshot(), providers: ["nano_banana"])
        let params = GenerationParams(prompt: "p", model: old.imageModel, aspectRatio: .square, width: 1, height: 1)

        let result = try await rig.provider.generate(params, references: nil, session: rig.google.session)

        #expect(!result.data.isEmpty)
        #expect(rig.google.requests.map(\.url.path) == [
            "/v1beta/models/gemini-3.1-flash-image:generateContent",
            "/v1beta/models/gemini-nano-banana-2.1:generateContent",
        ])
    }

    // MARK: - P2-1: a retry that changes model is re-resolved, re-priced and re-gated

    /// Google 404s a model the fresh catalogue retires in favour of the dearer Pro model.
    private func retiredToDearerRig() throws -> ProviderRig {
        let fresh = try RepoCatalogue.json { root in
            root["revision"] = 2
            let kept = modelList(root).filter { ($0["id"] as? String) != "gemini-2.5-flash-image" }
            setModelList(&root, kept)
            root["retired"] = (root["retired"] as! [[String: Any]]) + [
                ["id": "gemini-2.5-flash-image", "displayName": "Gone", "replacedBy": "gemini-3-pro-image"],
            ]
        }
        return try ProviderRig(remoteBody: fresh, google: { request in
            request.url.path.contains("gemini-2.5-flash-image") ? (404, Data(), [:]) : (200, geminiSuccessBody(), [:])
        })
    }

    private func oldModelParams(_ rig: ProviderRig, budget: GenerationPolicy.BudgetContext?) throws -> GenerationParams {
        let old = try ModelResolver.resolve(ResolveRequest(explicitModel: "nano_banana:gemini-2.5-flash-image"),
                                            catalogue: rig.store.snapshot(), providers: ["nano_banana"])
        return GenerationParams(prompt: "p", model: old.imageModel, aspectRatio: .square, width: 1, height: 1, budget: budget)
    }

    @Test func p2_aRetryToADearerModelOverBudgetIsRefusedBeforeTheSecondRequest() async throws {
        let rig = try retiredToDearerRig()
        // Old model £0.03081 passed a £0.05 cap; the replacement is 0.134 x 0.79 = £0.10586.
        let limits = GenerationPolicy.BudgetLimits(maxImages: 20, maxCostGBP: Decimal(string: "0.05")!)
        let params = try oldModelParams(rig, budget: .init(count: 1, limits: limits))
        await #expect(throws: GenerationPolicy.BudgetViolation.tooCostly(subtotal: Decimal(string: "0.10586")!, max: Decimal(string: "0.05")!)) {
            try await rig.provider.generate(params, references: nil, session: rig.google.session)
        }
        #expect(rig.google.requests.count == 1)   // the 404 only: nothing was sent to the dearer model
    }

    @Test func p2_aRetryWithinBudgetUsesTheNewModelsSizeAndReportsTheModelUsed() async throws {
        let rig = try retiredToDearerRig()
        let limits = GenerationPolicy.BudgetLimits(maxImages: 20, maxCostGBP: Decimal(string: "0.50")!)
        let params = try oldModelParams(rig, budget: .init(count: 1, limits: limits))
        #expect(params.model.imageSize == nil)   // the old model took no size

        let result = try await rig.provider.generate(params, references: nil, session: rig.google.session)

        #expect(rig.google.requests.map(\.url.path) == [
            "/v1beta/models/gemini-2.5-flash-image:generateContent",
            "/v1beta/models/gemini-3-pro-image:generateContent",
        ])
        let config = try #require(rig.google.requests[1].bodyJSON?["generationConfig"] as? [String: Any])
        #expect((config["imageConfig"] as? [String: Any])?["imageSize"] as? String == "2K")   // Pro's size, not the old model's none
        #expect(result.modelUsed == "gemini-3-pro-image")
        #expect(result.estimatedCostGBP == Decimal(string: "0.10586"))
    }

    @Test func p2_aCallThatNeverChangesModelReportsNoOverride() async throws {
        let rig = try ProviderRig(google: ok())
        let result = try await rig.provider.generate(try rig.params(), references: nil, session: rig.google.session)
        #expect(result.modelUsed == nil)
        #expect(result.estimatedCostGBP == nil)
    }

    @Test func t9_a400IsReportedWithTheProvidersMessageAndNeverAsABadKey() async throws {
        let message = Data(#"{"error":{"code":400,"message":"Invalid value at generationConfig.imageConfig"}}"#.utf8)
        let rig = try ProviderRig(google: { _ in (400, message, [:]) })
        do {
            _ = try await rig.provider.generate(try rig.params(), references: nil, session: rig.google.session)
            Issue.record("expected badRequest")
        } catch ProviderError.badRequest(let text) {
            #expect(text == "Invalid value at generationConfig.imageConfig")
        }
        // A 400 is not retried and does not trigger a catalogue refresh.
        #expect(rig.google.requests.count == 1)
        #expect(rig.remote.requests.isEmpty)
    }

    @Test func t9_theErrorTextOfA400NamesTheProblemNotTheKey() {
        let e = ProviderError.badRequest("Invalid value at generationConfig")
        #expect(e.errorDescription?.contains("Invalid value at generationConfig") == true)
        #expect(e.errorDescription?.lowercased().contains("api key") == false)
    }

    @Test func t9_401And403AreBadKeys429IsRateLimitOtherStatusesAreFailures() async throws {
        for status in [401, 403] {
            let rig = try ProviderRig(google: { _ in (status, Data(), [:]) })
            do {
                _ = try await rig.provider.generate(try rig.params(), references: nil, session: rig.google.session)
                Issue.record("expected invalidAPIKey for \(status)")
            } catch ProviderError.invalidAPIKey {
                #expect(rig.google.requests.count == 1)
            }
        }
        let limited = try ProviderRig(google: { _ in (429, Data(), [:]) })
        do {
            _ = try await limited.provider.generate(try limited.params(), references: nil, session: limited.google.session)
            Issue.record("expected rateLimited")
        } catch ProviderError.rateLimited {}

        let broken = try ProviderRig(google: { _ in (500, Data(#"{"error":{"message":"backend down"}}"#.utf8), [:]) })
        do {
            _ = try await broken.provider.generate(try broken.params(), references: nil, session: broken.google.session)
            Issue.record("expected generationFailed")
        } catch ProviderError.generationFailed(let text) {
            #expect(text == "backend down")
        }
    }

    @Test func estimateCostIsTheResolvedModelsRate() throws {
        let rig = try ProviderRig(google: ok())
        let params = try rig.params(quality: "pro")
        #expect(rig.provider.estimateCost(params) == Decimal(string: "0.10586"))
    }
}
