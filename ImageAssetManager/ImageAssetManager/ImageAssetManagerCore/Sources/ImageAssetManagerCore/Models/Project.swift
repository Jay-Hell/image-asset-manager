import GRDB
import Foundation

public struct Project: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "projects"

    public var id: String
    public var name: String
    /// Deprecated: kept during the v5 transition; new code should read Client via clientID.
    public var clientName: String?
    public var clientID: String?
    public var defaultProviderID: String?
    public var defaultModelID: String?
    public var activeReferenceSetID: String?
    public var obsidianNotePath: String?
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case clientName = "client_name"
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
        clientName: String? = nil,
        clientID: String? = nil,
        defaultProviderID: String? = nil,
        defaultModelID: String? = nil,
        activeReferenceSetID: String? = nil,
        obsidianNotePath: String? = nil,
        createdAt: String
    ) {
        self.id = id
        self.name = name
        self.clientName = clientName
        self.clientID = clientID
        self.defaultProviderID = defaultProviderID
        self.defaultModelID = defaultModelID
        self.activeReferenceSetID = activeReferenceSetID
        self.obsidianNotePath = obsidianNotePath
        self.createdAt = createdAt
    }
}
