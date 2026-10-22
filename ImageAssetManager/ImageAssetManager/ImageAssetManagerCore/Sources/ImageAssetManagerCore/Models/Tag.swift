import GRDB
import Foundation

public struct Tag: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "tags"

    public var id: String
    public var name: String

    public init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AssetTag: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "asset_tags"

    public var assetID: String
    public var tagID: String

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case tagID = "tag_id"
    }

    public init(assetID: String, tagID: String) {
        self.assetID = assetID
        self.tagID = tagID
    }
}
