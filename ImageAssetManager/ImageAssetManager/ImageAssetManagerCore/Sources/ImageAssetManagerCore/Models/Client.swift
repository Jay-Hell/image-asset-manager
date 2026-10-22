import GRDB
import Foundation

public struct Client: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "clients"

    public var id: String
    public var name: String
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdAt = "created_at"
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        createdAt: String
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
