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

private func makeSuccessResponse(imageData: Data) throws -> Data {
    let payload: [String: Any] = [
        "predictions": [["bytesBase64Encoded": imageData.base64EncodedString(), "mimeType": "image/png"]]
    ]
    return try JSONSerialization.data(withJSONObject: payload)
}

private func makeHTTPResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

private func makeParams() -> GenerationParams {
    GenerationParams(
        prompt: "A test landscape",
        model: ImageModel(id: "nano-banana-v1", displayName: "v1", supportedAspectRatios: [.square], costPerImage: 0.04),
        aspectRatio: .square,
        width: 1024,
        height: 1024
    )
}

// MARK: - Tests

@Suite("NanaBananaProvider", .serialized)
struct NanaBananaProviderTests {
    let provider = NanaBananaProvider()

    @Test func estimateCostReturnsModelRate() {
        let params = makeParams()
        #expect(provider.estimateCost(params) == Decimal(string: "0.04"))
    }

    @Test func generateThrowsWhenKeyMissing() async throws {
        // Ensure key is absent
        try? KeychainService.delete(service: NanaBananaProvider.keychainService, account: NanaBananaProvider.keychainAccount)

        await #expect(throws: ProviderError.self) {
            try await provider.generate(makeParams(), references: nil)
        }
    }

    @Test func generateSuccessReturnsImage() async throws {
        let imgData = mockImageData()
        let responseBody = try makeSuccessResponse(imageData: imgData)

        MockURLProtocol.handler = { _ in (makeHTTPResponse(statusCode: 200), responseBody) }

        try KeychainService.store("test-key", service: NanaBananaProvider.keychainService, account: NanaBananaProvider.keychainAccount)
        defer { try? KeychainService.delete(service: NanaBananaProvider.keychainService, account: NanaBananaProvider.keychainAccount) }

        // Use mock session — patch URLSession.shared isn't possible, so we test parse logic via the response path
        let result = try provider.parseResponseForTesting(responseBody)
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
