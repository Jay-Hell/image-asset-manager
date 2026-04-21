import GRDB
import Foundation

public struct Asset: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "assets"

    public var id: String
    public var filename: String
    public var fileHash: String
    public var projectID: String?
    public var providerID: String
    public var modelID: String
    public var prompt: String?
    public var negativePrompt: String?
    public var width: Int?
    public var height: Int?
    public var aspectRatio: String?
    public var seed: String?
    public var generationParams: String?
    public var estimatedCost: Double?
    public var actualCost: Double?
    public var createdAt: String
    public var importedAt: String?
    public var obsidianEmbedded: Bool
    public var isHidden: Bool

    enum CodingKeys: String, CodingKey {
        case id, filename
        case fileHash = "file_hash"
        case projectID = "project_id"
        case providerID = "provider_id"
        case modelID = "model_id"
        case prompt
        case negativePrompt = "negative_prompt"
        case width, height
        case aspectRatio = "aspect_ratio"
        case seed
        case generationParams = "generation_params"
        case estimatedCost = "estimated_cost"
        case actualCost = "actual_cost"
        case createdAt = "created_at"
        case importedAt = "imported_at"
        case obsidianEmbedded = "obsidian_embedded"
        case isHidden = "is_hidden"
    }

    public init(
        id: String = UUID().uuidString,
        filename: String,
        fileHash: String,
        projectID: String? = nil,
        providerID: String,
        modelID: String,
        prompt: String? = nil,
        negativePrompt: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        aspectRatio: String? = nil,
        seed: String? = nil,
        generationParams: String? = nil,
        estimatedCost: Double? = nil,
        actualCost: Double? = nil,
        createdAt: String,
        importedAt: String? = nil,
        obsidianEmbedded: Bool = false,
        isHidden: Bool = false
    ) {
        self.id = id
        self.filename = filename
        self.fileHash = fileHash
        self.projectID = projectID
        self.providerID = providerID
        self.modelID = modelID
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.aspectRatio = aspectRatio
        self.seed = seed
        self.generationParams = generationParams
        self.estimatedCost = estimatedCost
        self.actualCost = actualCost
        self.createdAt = createdAt
        self.importedAt = importedAt
        self.obsidianEmbedded = obsidianEmbedded
        self.isHidden = isHidden
    }
}
