import GRDB
import Foundation

public struct Project: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "projects"

    public var id: String
    public var name: String
    /// The project's client. The old `client_name` column is neither read nor written (v10).
    public var clientID: String?
    /// Set by `create_project` (v10).
    public var description: String?
    public var defaultProviderID: String?
    public var defaultModelID: String?
    public var activeReferenceSetID: String?
    public var obsidianNotePath: String?
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case clientID = "client_id"
        case defaultProviderID = "default_provider_id"
        case defaultModelID = "default_model_id"
        case activeReferenceSetID = "active_reference_set_id"
        case obsidianNotePath = "obsidian_note_path"
        case createdAt = "created_at"
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        clientID: String? = nil,
        description: String? = nil,
        defaultProviderID: String? = nil,
        defaultModelID: String? = nil,
        activeReferenceSetID: String? = nil,
        obsidianNotePath: String? = nil,
        createdAt: String
    ) {
        self.id = id
        self.name = name
        self.clientID = clientID
        self.description = description
        self.defaultProviderID = defaultProviderID
        self.defaultModelID = defaultModelID
        self.activeReferenceSetID = activeReferenceSetID
        self.obsidianNotePath = obsidianNotePath
        self.createdAt = createdAt
    }
}
