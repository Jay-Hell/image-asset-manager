import Testing
import Foundation
@testable import ImageAssetManagerCore

// MARK: - Mock URLProtocol

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Helpers

private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func mockImageData() -> Data {
    // 1×1 red PNG
    Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
        0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC,
        0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    ])
}

private func makeImagenSuccessResponse(imageData: Data) throws -> Data {
    let payload: [String: Any] = [
        "predictions": [["bytesBase64Encoded": imageData.base64EncodedString(), "mimeType": "image/png"]]
    ]
    return try JSONSerialization.data(withJSONObject: payload)
}

private func makeGeminiSuccessResponse(imageData: Data) throws -> Data {
    let payload: [String: Any] = [
        "candidates": [[
            "content": [
                "parts": [[
                    "inlineData": [
                        "mimeType": "image/png",
                        "data": imageData.base64EncodedString(),
                    ],
                ]],
            ],
        ]],
    ]
    return try JSONSerialization.data(withJSONObject: payload)
}

private func makeHTTPResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

private func makeParams(modelID: String = NanaBananaProvider.ModelID.imagenStandard, cost: Decimal = 0.04) -> GenerationParams {
    GenerationParams(
        prompt: "A test landscape",
        model: ImageModel(id: modelID, displayName: "Test", supportedAspectRatios: [.square], costPerImage: cost),
        aspectRatio: .square,
        width: 1024,
        height: 1024
    )
}

// MARK: - Tests

@Suite("NanaBananaProvider", .serialized)
struct NanaBananaProviderTests {
    let provider = NanaBananaProvider()

    @Test func availableModelsIncludesThreeImagenTiersAndGemini() {
        let ids = provider.availableModels.map(\.id)
        #expect(ids.contains(NanaBananaProvider.ModelID.imagenFast))
        #expect(ids.contains(NanaBananaProvider.ModelID.imagenStandard))
        #expect(ids.contains(NanaBananaProvider.ModelID.imagenUltra))
        #expect(ids.contains(NanaBananaProvider.ModelID.geminiWithRefs))
    }

    @Test func imagenTiersAreOrderedByCost() {
        let fast = provider.availableModels.first { $0.id == NanaBananaProvider.ModelID.imagenFast }!
        let std  = provider.availableModels.first { $0.id == NanaBananaProvider.ModelID.imagenStandard }!
        let ultra = provider.availableModels.first { $0.id == NanaBananaProvider.ModelID.imagenUltra }!
        #expect(fast.costPerImage < std.costPerImage)
        #expect(std.costPerImage < ultra.costPerImage)
    }

    @Test func onlyGeminiModelSupportsReferences() {
        #expect(!NanaBananaProvider.supportsReferences(modelID: NanaBananaProvider.ModelID.imagenFast))
        #expect(!NanaBananaProvider.supportsReferences(modelID: NanaBananaProvider.ModelID.imagenStandard))
        #expect(!NanaBananaProvider.supportsReferences(modelID: NanaBananaProvider.ModelID.imagenUltra))
        #expect(NanaBananaProvider.supportsReferences(modelID: NanaBananaProvider.ModelID.geminiWithRefs))
    }

    @Test func estimateCostReturnsModelRate() {
        let params = makeParams(modelID: NanaBananaProvider.ModelID.imagenStandard, cost: 0.04)
        #expect(provider.estimateCost(params) == Decimal(string: "0.04"))
    }

    @Test func modelCostsAreGBPConvertedFromPublishedUSDPrices() {
        // Published Google USD prices per image — pin the conversion path so a drift in
        // Currency.usdToGBP or a bad edit in availableModels shows up immediately.
        let expected: [(String, Decimal)] = [
            (NanaBananaProvider.ModelID.imagenFast,     Currency.gbp(fromUSD: 0.02)),
            (NanaBananaProvider.ModelID.imagenStandard, Currency.gbp(fromUSD: 0.04)),
            (NanaBananaProvider.ModelID.imagenUltra,    Currency.gbp(fromUSD: 0.06)),
            (NanaBananaProvider.ModelID.geminiWithRefs, Currency.gbp(fromUSD: 0.039)),
        ]
        for (id, expectedCost) in expected {
            let model = provider.availableModels.first { $0.id == id }
            #expect(model?.costPerImage == expectedCost)
        }
    }

    @Test func generateThrowsWhenKeyMissing() async throws {
        try? KeychainService.delete(service: NanaBananaProvider.keychainService, account: NanaBananaProvider.keychainAccount)

        await #expect(throws: ProviderError.self) {
            try await provider.generate(makeParams(), references: nil)
        }
    }

    @Test func imagenResponseParsesPredictionShape() throws {
        let imgData = mockImageData()
        let responseBody = try makeImagenSuccessResponse(imageData: imgData)
        let result = try provider.parseImagenResponseForTesting(responseBody)
        #expect(result.format == "png")
        #expect(!result.data.isEmpty)
    }

    @Test func geminiResponseParsesInlineDataFromCandidates() throws {
        let imgData = mockImageData()
        let responseBody = try makeGeminiSuccessResponse(imageData: imgData)
        let result = try provider.parseGeminiResponseForTesting(responseBody)
        #expect(result.format == "png")
        #expect(!result.data.isEmpty)
    }

    @Test func generateThrowsOnRateLimit() async throws {
        MockURLProtocol.handler = { _ in (makeHTTPResponse(statusCode: 429), Data()) }
        try KeychainService.store("test-key", service: NanaBananaProvider.keychainService, account: NanaBananaProvider.keychainAccount)
        defer { try? KeychainService.delete(service: NanaBananaProvider.keychainService, account: NanaBananaProvider.keychainAccount) }

        let session = makeSession()
        await #expect(throws: ProviderError.self) {
            try await provider.generate(makeParams(), references: nil, session: session)
        }
    }

    @Test func generateThrowsOnInvalidKey() async throws {
        MockURLProtocol.handler = { _ in (makeHTTPResponse(statusCode: 401), Data()) }
        try KeychainService.store("bad-key", service: NanaBananaProvider.keychainService, account: NanaBananaProvider.keychainAccount)
        defer { try? KeychainService.delete(service: NanaBananaProvider.keychainService, account: NanaBananaProvider.keychainAccount) }

        let session = makeSession()
        await #expect(throws: ProviderError.self) {
            try await provider.generate(makeParams(), references: nil, session: session)
        }
    }
}
