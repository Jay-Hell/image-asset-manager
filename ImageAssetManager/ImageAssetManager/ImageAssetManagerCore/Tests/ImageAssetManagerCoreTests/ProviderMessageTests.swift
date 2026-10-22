import Testing
import Foundation
@testable import ImageAssetManagerCore

/// What the user reads when a provider refuses: the provider's message, whole, without its JSON
/// wrapper and without the key.
@Suite("Provider error messages")
struct ProviderMessageTests {

    // The body seen live, 22 October (the panel showed it cut off after "authenti…").
    private let anthropic401 = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"},"request_id":"req_011"}"#.utf8)
    private let google400 = Data(#"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}"#.utf8)

    @Test func anthropicsMessageIsShownNotItsJSON() {
        #expect(ProviderMessage.text(from: anthropic401) == "invalid x-api-key")
    }

    @Test func googlesMessageIsShownNotItsJSON() {
        #expect(ProviderMessage.text(from: google400) == "API key not valid. Please pass a valid API key.")
        // The same error wrapped in a list, as Google's streaming endpoints do.
        let listed = Data(#"[{"error":{"code":400,"message":"first"}}]"#.utf8)
        #expect(ProviderMessage.text(from: listed) == "first")
    }

    @Test func aBodyThatIsNotJSONIsShownAsText() {
        #expect(ProviderMessage.text(from: Data("  overloaded \n".utf8)) == "overloaded")
        #expect(ProviderMessage.text(from: Data()) == nil)
    }

    @Test func aLongMessageIsShownInFullUpToTheCap() {
        let long = String(repeating: "word ", count: 120)   // 600 characters
        let body = try! JSONSerialization.data(withJSONObject: ["error": ["message": long]])
        #expect(ProviderMessage.text(from: body) == long)
        // The pair: a page-sized body is cut, with a mark that it was.
        let huge = Data(String(repeating: "x", count: 5000).utf8)
        let cut = ProviderMessage.text(from: huge)
        #expect(cut?.count == ProviderMessage.maxLength + 1)
        #expect(cut?.hasSuffix("…") == true)
    }

    @Test func aKeyEchoedBackIsRedacted() {
        let body = Data(#"{"error":{"message":"bad key sk-ant-SECRET-1234 given"}}"#.utf8)
        let text = ProviderMessage.text(from: body, redacting: ["sk-ant-SECRET-1234"])
        #expect(text == "bad key [key] given")
        // The pair: without it in the list nothing is touched.
        #expect(ProviderMessage.text(from: body)?.contains("sk-ant-SECRET-1234") == true)
    }

    @Test func theAnthropicClientReportsTheMessageAndNeverTheKey() async throws {
        let echoing = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key sk-test-key"}}"#.utf8)
        let remote = StubSession(status: 404)       // held: a session's handler goes with it
        let anthropic = StubSession(status: 401, body: echoing)
        let store = CatalogueStore(
            bundled: try RepoCatalogue.parsed(), directory: makeTempDirectory(),
            remoteURL: URL(string: "https://example.test/models.json")!, session: remote.session, build: 0)
        let client = AnthropicClient(catalogue: store, session: anthropic.session, apiKey: { "sk-test-key" })
        defer { withExtendedLifetime((remote, anthropic)) {} }
        do {
            _ = try await client.complete(system: "s", messages: [["role": "user", "content": "hi"]])
            Issue.record("a 401 should throw")
        } catch let error as AnthropicError {
            #expect(error == .apiError(statusCode: 401, message: "invalid x-api-key [key]"))
            #expect(error.localizedDescription == "Anthropic API error 401: invalid x-api-key [key]")
            #expect(!error.localizedDescription.contains("sk-test-key"))
        }
    }
}
