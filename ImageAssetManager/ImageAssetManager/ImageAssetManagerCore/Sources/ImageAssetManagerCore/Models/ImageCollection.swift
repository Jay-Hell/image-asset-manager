import GRDB
import Foundation

public struct ImageCollection: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "collections"

    public var id: String
    public var projectID: String
    public var name: String
    public var description: String?
    public var obsidianNotePath: String?
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case name, description
        case obsidianNotePath = "obsidian_note_path"
        case createdAt = "created_at"
    }

    public init(
        id: String = UUID().uuidString,
        projectID: String,
        name: String,
        description: String? = nil,
        obsidianNotePath: String? = nil,
        createdAt: String
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.description = description
        self.obsidianNotePath = obsidianNotePath
        self.createdAt = createdAt
    }
}
