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

    @Test func aKeyInAURLQueryIsRedactedWhoseverKeyItIs() {
        let body = Data(#"{"error":{"message":"POST https://example.test/v1/models/m:generateContent?alt=json&key=AIzaOtherKey99 failed"}}"#.utf8)
        // Not in the list: the pattern alone takes the value out of the query.
        #expect(ProviderMessage.text(from: body) == "POST https://example.test/v1/models/m:generateContent?alt=json&key=[key] failed")
        // The pair: a parameter that merely ends in "key" is left alone.
        let other = Data("see ?monkey=banana".utf8)
        #expect(ProviderMessage.text(from: other) == "see ?monkey=banana")
    }

    @Test func theAnthropicClientRedactsItsKeyInTheBodyAndInAURL() async throws {
        let echoing = Data(#"{"type":"error","error":{"type":"authentication_error","message":"sk-test-key rejected at https://api.anthropic.com/v1/messages?key=sk-test-key"}}"#.utf8)
        let remote = StubSession(status: 404)
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
            #expect(!error.localizedDescription.contains("sk-test-key"))
            #expect(error.localizedDescription.contains("[key] rejected at https://api.anthropic.com/v1/messages?key=[key]"))
        }
    }

    @Test func google_and_openRouter_redactTheirKeyInTheBodyAndInAURL() async throws {
        // Each provider's error reaches the caller whole, so a key an upstream echoes must not.
        for status in [400, 500] {
            let googleBody = Data(#"{"error":{"message":"key g-test-key-123 rejected at https://generativelanguage.googleapis.com/v1beta/models/m:generateContent?key=g-test-key-123"}}"#.utf8)
            let google = try await ToolsRig.make(openRouterKey: false, google: { _ in (status, googleBody, [:]) })
            do {
                _ = try await google.call("generate", ["prompt": "p", "quality": "fast"])
                Issue.record("Google \(status) should throw")
            } catch {
                let text = error.localizedDescription
                #expect(!text.contains("g-test-key-123"))
                #expect(text.contains("key [key] rejected at https://generativelanguage.googleapis.com/v1beta/models/m:generateContent?key=[key]"))
            }

            let orBody = Data(#"{"error":{"message":"key or-test-key-456 rejected at https://openrouter.ai/api/v1/images?key=or-test-key-456"}}"#.utf8)
            let openRouter = try await ToolsRig.make(googleKey: false, openRouter: { _ in (status, orBody, [:]) })
            do {
                _ = try await openRouter.call("generate", ["prompt": "p", "quality": "fast"])
                Issue.record("OpenRouter \(status) should throw")
            } catch {
                let text = error.localizedDescription
                #expect(!text.contains("or-test-key-456"))
                #expect(text.contains("key [key] rejected at https://openrouter.ai/api/v1/images?key=[key]"))
            }
        }
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
