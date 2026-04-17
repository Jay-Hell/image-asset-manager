import GRDB
import Foundation

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
}
