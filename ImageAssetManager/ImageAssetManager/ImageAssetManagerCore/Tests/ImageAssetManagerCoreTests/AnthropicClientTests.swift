import Testing
import Foundation
@testable import ImageAssetManagerCore

private func message(
    model: String = "claude-sonnet-5-5",
    stop: String = "end_turn",
    content: String,
    extra: String = ""
) -> Data {
    Data(#"{"model":"\#(model)","stop_reason":"\#(stop)","content":\#(content)\#(extra)}"#.utf8)
}

private func bodyOf(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let textBlock = #"[{"type":"text","text":"hello"}]"#
private let thinkingThenText = #"[{"type":"thinking","thinking":""},{"type":"text","text":"hello"}]"#

private struct ClientRig {
    let anthropic: StubSession
    let remote: StubSession
    let store: CatalogueStore
    let client: AnthropicClient

    init(catalogue: Catalogue? = nil, remoteBody: Data? = nil, anthropic handler: @escaping StubSession.Handler) throws {
        anthropic = StubSession(handler)
        remote = StubSession(status: remoteBody == nil ? 404 : 200, body: remoteBody ?? Data())
        store = CatalogueStore(
            bundled: try catalogue ?? RepoCatalogue.parsed(),
            directory: makeTempDirectory(),
            remoteURL: URL(string: "https://example.test/models.json")!,
            session: remote.session,
            build: 0
        )
        client = AnthropicClient(catalogue: store, session: anthropic.session, apiKey: { "sk-test-key" })
    }

    init(catalogue: Catalogue? = nil, remoteBody: Data? = nil, status: Int = 200, body: Data) throws {
        try self.init(catalogue: catalogue, remoteBody: remoteBody, anthropic: { _ in (status, body, [:]) })
    }

    func ask() async throws -> AnthropicCompletion {
        try await client.complete(system: "sys", messages: [["role": "user", "content": "hi"]])
    }
}

@Suite("AnthropicClient")
struct AnthropicClientTests {

    // MARK: - T6: the request that leaves the process

    @Test func t6_theRequestHasNoSamplingParametersTheCataloguesModelAndOnlyAllowListedHeaders() async throws {
        let rig = try ClientRig(body: message(content: textBlock))
        _ = try await rig.ask()

        let sent = try #require(rig.anthropic.requests.first)
        #expect(rig.anthropic.requests.count == 1)
        #expect(sent.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.method == "POST")

        let body = try #require(sent.bodyJSON)
        for forbidden in ["temperature", "top_p", "top_k"] {
            #expect(body[forbidden] == nil, "\(forbidden) must not be sent")
        }
        #expect(body["thinking"] == nil)   // omitted: adaptive is the default and disabled is a 400
        #expect(body["model"] as? String == "claude-sonnet-5-5")
        #expect(body["max_tokens"] as? Int == 4096)
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["system"] as? String == "sys")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "hi"]])

        #expect(sent.headers["x-api-key"] == "sk-test-key")
        #expect(sent.headers["anthropic-version"] == "2026-10-21")
        #expect(sent.headers["anthropic-beta"] == "server-side-fallback-2026-07-01")
        #expect(sent.headers["content-type"] == "application/json")
    }

    @Test func t6_theHeaderSetIsExactlyTheAllowListPlusTheFixedOnes() throws {
        let refinement = try #require(try RepoCatalogue.parsed().refinement)
        let request = try AnthropicClient.urlRequest(refinement: refinement, apiKey: "k", system: "s", messages: [])
        let names = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        #expect(names == ["content-type", "x-api-key", "anthropic-version", "anthropic-beta"])
    }

    @Test func t6_aCatalogueCannotAddHeadersSamplingParametersOrChangeTheCompiledVersion() throws {
        let hostile = Catalogue.Refinement(
            api: "anthropic.messages",
            model: "claude-sonnet-5-5",
            headers: ["x-evil": "1", "anthropic-version": "2023-06-01", "anthropic-beta": "b", "authorization": "Bearer z"],
            body: [
                "max_tokens": .number(100), "temperature": .number(0.7), "top_p": .number(0.9), "top_k": .number(5),
                "model": .string("other"), "system": .string("other"), "stream": .bool(true),
            ])
        let request = try AnthropicClient.urlRequest(refinement: hostile, apiKey: "k", system: "mine", messages: [["role": "user", "content": "q"]])

        let headers = Dictionary(uniqueKeysWithValues: (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) })
        #expect(headers["x-evil"] == nil)
        #expect(headers["authorization"] == nil)
        #expect(headers["anthropic-version"] == "2026-10-21")   // compiled wins
        #expect(headers["anthropic-beta"] == "b")

        let body = try bodyOf(request)
        for forbidden in ["temperature", "top_p", "top_k"] { #expect(body[forbidden] == nil) }
        #expect(body["model"] as? String == "claude-sonnet-5-5")   // app-owned fields win
        #expect(body["system"] as? String == "mine")
        #expect(body["max_tokens"] as? Int == 100)                  // catalogue defaults otherwise flow through
        #expect(body["stream"] as? Bool == true)
    }

    @Test func aCatalogueWithoutMaxTokensStillSendsOne() throws {
        let bare = Catalogue.Refinement(api: "anthropic.messages", model: "claude-sonnet-5-5", headers: [:], body: [:])
        let request = try AnthropicClient.urlRequest(refinement: bare, apiKey: "k", system: "s", messages: [])
        let body = try bodyOf(request)
        #expect(body["max_tokens"] as? Int == 4096)
    }

    @Test func theModelComesFromTheCatalogueNotFromCode() async throws {
        let catalogue = try RepoCatalogue.parsed { root in
            var r = root["refinement"] as! [String: Any]
            r["model"] = "claude-future-9"
            root["refinement"] = r
        }
        let rig = try ClientRig(catalogue: catalogue, body: message(model: "claude-future-9", content: textBlock))
        _ = try await rig.ask()
        #expect(rig.anthropic.requests[0].bodyJSON?["model"] as? String == "claude-future-9")
    }

    // MARK: - T7: thinking blocks

    @Test func t7_aThinkingBlockBeforeTheTextBlockReturnsTheText() async throws {
        let rig = try ClientRig(body: message(content: thinkingThenText))
        #expect(try await rig.ask().text == "hello")
    }

    @Test func t7_aTextOnlyResponseStillWorks() async throws {
        let rig = try ClientRig(body: message(content: textBlock))
        #expect(try await rig.ask().text == "hello")
    }

    @Test func t7_aResponseWithNoTextBlockIsMalformed() async throws {
        let rig = try ClientRig(body: message(content: #"[{"type":"thinking","thinking":"hm"}]"#))
        await #expect(throws: AnthropicError.malformedResponse) { try await rig.ask() }
    }

    // MARK: - stop_reason

    @Test func aRefusalHasItsOwnMessageWithTheCategory() async throws {
        let rig = try ClientRig(body: message(stop: "refusal", content: "[]", extra: #","stop_details":{"category":"cyber"}"#))
        do {
            _ = try await rig.ask()
            Issue.record("expected a refusal")
        } catch let error as AnthropicError {
            #expect(error == .refused(category: "cyber"))
            #expect(error.errorDescription == "Claude declined to refine this prompt (cyber). Try rewording it.")
        }
    }

    @Test func aMaxTokensCutOffHasItsOwnMessageEvenWhenTextIsPresent() async throws {
        let rig = try ClientRig(body: message(stop: "max_tokens", content: textBlock))
        do {
            _ = try await rig.ask()
            Issue.record("expected truncation")
        } catch let error as AnthropicError {
            #expect(error == .truncated)
            #expect(error.errorDescription == "Claude's reply was cut off before it finished. Try a shorter prompt.")
        }
    }

    // MARK: - modelUsed

    @Test func modelUsedIsTheResponsesModelWhichNamesAFallbackWhenOneServed() async throws {
        let rig = try ClientRig(body: message(model: "claude-fallback-1", content: textBlock))
        let completion = try await rig.ask()
        #expect(completion.model == "claude-fallback-1")    // not the catalogue's claude-sonnet-5-5
        #expect(completion.text == "hello")
    }

    @Test func modelUsedFallsBackToTheRequestedModelWhenTheResponseOmitsIt() async throws {
        let rig = try ClientRig(body: Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"x"}]}"#.utf8))
        #expect(try await rig.ask().model == "claude-sonnet-5-5")
    }

    // MARK: - Errors

    @Test func aMissingKeyIsReportedWithoutARequest() async throws {
        let anthropic = StubSession(status: 200, body: message(content: textBlock))
        let client = AnthropicClient(catalogue: CatalogueStore(bundled: try RepoCatalogue.parsed(), directory: makeTempDirectory()),
                                     session: anthropic.session,
                                     apiKey: { throw KeychainService.KeychainError.itemNotFound })
        await #expect(throws: AnthropicError.missingAPIKey) {
            try await client.complete(system: "s", messages: [])
        }
        #expect(anthropic.requests.isEmpty)
    }

    @Test func otherHTTPErrorsCarryTheStatusAndBody() async throws {
        let rig = try ClientRig(status: 529, body: Data("overloaded".utf8))
        await #expect(throws: AnthropicError.apiError(statusCode: 529, message: "overloaded")) { try await rig.ask() }
        #expect(rig.anthropic.requests.count == 1)   // not retried, no refresh
        #expect(rig.remote.requests.isEmpty)
    }

    @Test func a404RefreshesTheCatalogueOnceAndRetriesOnce() async throws {
        let rig = try ClientRig(remoteBody: try RepoCatalogue.json { $0["revision"] = 2 }, status: 404, body: Data())
        await #expect(throws: AnthropicError.modelUnavailable("claude-sonnet-5-5")) { try await rig.ask() }
        #expect(rig.anthropic.requests.count == 2)
        #expect(rig.remote.requests.count == 1)
    }

    @Test func theRetryUsesTheRefreshedModel() async throws {
        let fresh = try RepoCatalogue.json { root in
            root["revision"] = 2
            var r = root["refinement"] as! [String: Any]
            r["model"] = "claude-newer-1"
            root["refinement"] = r
        }
        let rig = try ClientRig(remoteBody: fresh, anthropic: { request in
            let model = request.bodyJSON?["model"] as? String
            return model == "claude-newer-1"
                ? (200, message(model: "claude-newer-1", content: textBlock), [:])
                : (404, Data(), [:])
        })
        let completion = try await rig.ask()
        #expect(completion.model == "claude-newer-1")
        #expect(rig.anthropic.requests.compactMap { $0.bodyJSON?["model"] as? String } == ["claude-sonnet-5-5", "claude-newer-1"])
    }
}
