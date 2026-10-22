import GRDB
import Foundation

public struct Prompt: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "prompts"

    public var id: String
    public var title: String
    public var body: String
    public var negativePrompt: String?
    public var sector: String?
    public var tags: String?        // JSON array of tag strings
    public var usageCount: Int
    public var lastUsedAt: String?
    public var obsidianNotePath: String?
    public var createdAt: String
    public var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, body
        case negativePrompt = "negative_prompt"
        case sector, tags
        case usageCount = "usage_count"
        case lastUsedAt = "last_used_at"
        case obsidianNotePath = "obsidian_note_path"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String = UUID().uuidString,
        title: String,
        body: String,
        negativePrompt: String? = nil,
        sector: String? = nil,
        tags: String? = nil,
        usageCount: Int = 0,
        lastUsedAt: String? = nil,
        obsidianNotePath: String? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.negativePrompt = negativePrompt
        self.sector = sector
        self.tags = tags
        self.usageCount = usageCount
        self.lastUsedAt = lastUsedAt
        self.obsidianNotePath = obsidianNotePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PromptAsset: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "prompt_asset"

    public var promptID: String
    public var assetID: String

    enum CodingKeys: String, CodingKey {
        case promptID = "prompt_id"
        case assetID = "asset_id"
    }

    public init(promptID: String, assetID: String) {
        self.promptID = promptID
        self.assetID = assetID
    }
}
