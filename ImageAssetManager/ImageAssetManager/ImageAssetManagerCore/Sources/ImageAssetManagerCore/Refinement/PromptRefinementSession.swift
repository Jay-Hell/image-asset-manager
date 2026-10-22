import Foundation
import Observation

@Observable
@MainActor
public final class PromptRefinementSession {

    public enum Mode: String, CaseIterable, Sendable {
        case refine = "Refine"
        case interview = "Interview"
    }

    // MARK: - Observable state
    public var mode: Mode = .refine
    public var draftPrompt: String
    public var refinedPrompt: String = ""
    public var rationale: String = ""
    public var conversation: [RefinementConversationTurn] = []
    public var isLoading: Bool = false
    public var error: String?
    public var isComplete: Bool = false
    public var context: RefinementContext

    private let client: any AnthropicClientProtocol

    public init(
        draft: String,
        context: RefinementContext,
        client: any AnthropicClientProtocol = AnthropicClient()
    ) {
        self.draftPrompt = draft
        self.context = context
        self.client = client
    }

    // MARK: - Refine mode

    public func refine() async {
        isLoading = true
        error = nil
        conversation = []
        isComplete = false

        let system = buildSystemPrompt()
        let userContent = "Please refine this image generation prompt:\n\n\"\(draftPrompt)\"\n\nReturn only the JSON, no other text."
        let messages: [[String: String]] = [["role": "user", "content": userContent]]
        conversation.append(RefinementConversationTurn(role: "user", content: userContent))

        do {
            let response = try await client.complete(
                system: system, messages: messages,
                model: AnthropicClient.defaultModel, maxTokens: 1024, temperature: 0.7
            )
            conversation.append(RefinementConversationTurn(role: "assistant", content: response))
            parseRefineResponse(response)
            isComplete = true
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Interview mode

    public func startInterview() async {
        isLoading = true
        error = nil
        conversation = []
        isComplete = false
        refinedPrompt = ""
        rationale = ""

        let system = buildSystemPrompt(interview: true)
        let userContent = "I want to refine this image generation prompt: \"\(draftPrompt)\""
        let messages: [[String: String]] = [["role": "user", "content": userContent]]
        conversation.append(RefinementConversationTurn(role: "user", content: userContent))

        do {
            let response = try await client.complete(
                system: system, messages: messages,
                model: AnthropicClient.defaultModel, maxTokens: 1024, temperature: 0.7
            )
            conversation.append(RefinementConversationTurn(role: "assistant", content: response))
            checkForCompletion(response)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    public func addUserReply(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isLoading = true
        error = nil

        conversation.append(RefinementConversationTurn(role: "user", content: trimmed))

        let system = buildSystemPrompt(interview: true)
        let capturedConversation = conversation
        let messages = capturedConversation.map { ["role": $0.role, "content": $0.content] }

        do {
            let response = try await client.complete(
                system: system, messages: messages,
                model: AnthropicClient.defaultModel, maxTokens: 1024, temperature: 0.7
            )
            conversation.append(RefinementConversationTurn(role: "assistant", content: response))
            checkForCompletion(response)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Display helpers

    /// Conversation turns suitable for display (curated for each mode).
    public var visibleTurns: [RefinementConversationTurn] {
        switch mode {
        case .refine:
            return conversation.filter { $0.role == "assistant" }
        case .interview:
            // Skip the initial user setup message
            return conversation.count > 1 ? Array(conversation.dropFirst()) : []
        }
    }

    /// Human-readable text for an assistant turn (strips JSON signals).
    public func displayText(for turn: RefinementConversationTurn) -> String {
        guard turn.role == "assistant" else { return turn.content }
        if let json = extractJSON(from: turn.content) {
            if let done = json["done"] as? Bool, done {
                return json["rationale"] as? String ?? "Refinement complete."
            }
            if let r = json["rationale"] as? String { return r }
        }
        return turn.content
    }

    public var hasActivity: Bool { !conversation.isEmpty }

    // MARK: - Serialisation

    public func conversationJSON() -> String {
        let capturedConversation = conversation
        guard let data = try? JSONEncoder().encode(capturedConversation),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    // MARK: - Private

    private func buildSystemPrompt(interview: Bool = false) -> String {
        let clientStr = context.clientName.map { " (\($0))" } ?? ""
        let refsStr = context.activeReferences.isEmpty ? "none" :
            context.activeReferences.map { item in
                [item.role, item.notes].compactMap { $0 }.joined(separator: ": ")
            }.joined(separator: ", ")
        let similarStr = context.similarPrompts.isEmpty ? "none" :
            context.similarPrompts.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")

        var prompt = """
            You are an expert AI image prompt engineer specialising in professional \
            business and consulting imagery. You are helping refine prompts for the \
            \(context.modelName) model generating \(context.aspectRatio) images for \
            \(context.projectName)\(clientStr). Active style references: \(refsStr). \
            Similar past prompts that worked well:\n\(similarStr).\nBe concise and specific. \
            Focus on visual clarity, style consistency, and professional suitability.
            """

        if interview {
            prompt += "\n\nYou are in Interview mode. Ask 2–4 targeted clarifying questions one at a time. When you have enough information, respond with exactly this JSON and nothing else: {\"done\": true, \"refined_prompt\": \"...\", \"rationale\": \"...\"}"
        } else {
            prompt += "\n\nRespond with exactly this JSON and nothing else: {\"refined_prompt\": \"...\", \"rationale\": \"...\"}"
        }
        return prompt
    }

    private func parseRefineResponse(_ text: String) {
        guard let json = extractJSON(from: text) else {
            refinedPrompt = text
            return
        }
        refinedPrompt = json["refined_prompt"] as? String ?? text
        rationale = json["rationale"] as? String ?? ""
    }

    private func checkForCompletion(_ text: String) {
        guard let json = extractJSON(from: text),
              let done = json["done"] as? Bool, done,
              let refined = json["refined_prompt"] as? String else { return }
        refinedPrompt = refined
        rationale = json["rationale"] as? String ?? ""
        isComplete = true
    }

    private func extractJSON(from text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        let substr = String(text[start...end])
        guard let data = substr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}
