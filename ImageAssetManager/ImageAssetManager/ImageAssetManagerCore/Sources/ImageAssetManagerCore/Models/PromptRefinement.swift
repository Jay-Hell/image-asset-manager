import GRDB
import Foundation

// MARK: - Supporting types for prompt refinement

public struct RefinementConversationTurn: Codable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ReferenceContextItem: Sendable {
    public let role: String
    public let notes: String?

    public init(role: String, notes: String? = nil) {
        self.role = role
        self.notes = notes
    }
}

public struct RefinementContext: Sendable {
    public var projectName: String
    public var clientName: String?
    public var activeReferences: [ReferenceContextItem]
    public var similarPrompts: [String]
    public var aspectRatio: String
    public var modelName: String

    public init(
        projectName: String,
        clientName: String? = nil,
        activeReferences: [ReferenceContextItem] = [],
        similarPrompts: [String] = [],
        aspectRatio: String,
        modelName: String
    ) {
        self.projectName = projectName
        self.clientName = clientName
        self.activeReferences = activeReferences
        self.similarPrompts = similarPrompts
        self.aspectRatio = aspectRatio
        self.modelName = modelName
    }
}

// MARK: - Persisted refinement record

public struct PromptRefinement: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "prompt_refinements"

    public var id: String
    public var assetID: String
    public var promptID: String?
    public var mode: String             // "refine" | "interview"
    public var draftPrompt: String
    public var finalPrompt: String
    public var conversation: String     // JSON array of {role, content} turns
    public var modelUsed: String
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case assetID = "asset_id"
        case promptID = "prompt_id"
        case mode
        case draftPrompt = "draft_prompt"
        case finalPrompt = "final_prompt"
        case conversation
        case modelUsed = "model_used"
        case createdAt = "created_at"
    }

    public init(
        id: String = UUID().uuidString,
        assetID: String,
        promptID: String? = nil,
        mode: String,
        draftPrompt: String,
        finalPrompt: String,
        conversation: String,
        modelUsed: String,
        createdAt: String
    ) {
        self.id = id
        self.assetID = assetID
        self.promptID = promptID
        self.mode = mode
        self.draftPrompt = draftPrompt
        self.finalPrompt = finalPrompt
        self.conversation = conversation
        self.modelUsed = modelUsed
        self.createdAt = createdAt
    }

    public var parsedConversation: [RefinementConversationTurn] {
        guard let data = conversation.data(using: .utf8),
              let turns = try? JSONDecoder().decode([RefinementConversationTurn].self, from: data) else {
            return []
        }
        return turns
    }
}
