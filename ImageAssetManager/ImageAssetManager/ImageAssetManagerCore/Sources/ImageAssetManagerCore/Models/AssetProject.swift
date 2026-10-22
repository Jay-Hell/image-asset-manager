import GRDB
import Foundation

public struct AssetProject: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "asset_projects"

    public var assetID: String
    public var projectID: String
    public var isPrimary: Bool

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case projectID = "project_id"
        case isPrimary = "is_primary"
    }

    public init(assetID: String, projectID: String, isPrimary: Bool = false) {
        self.assetID = assetID
        self.projectID = projectID
        self.isPrimary = isPrimary
    }
}
