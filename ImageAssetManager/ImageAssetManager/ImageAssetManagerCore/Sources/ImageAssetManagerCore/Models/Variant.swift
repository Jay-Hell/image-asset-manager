import GRDB
import Foundation

public struct Variant: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "variants"

    public var id: String
    public var name: String
    public var projectID: String?
    public var baseAssetID: String?
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case projectID = "project_id"
        case baseAssetID = "base_asset_id"
        case createdAt = "created_at"
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        projectID: String?,
        baseAssetID: String? = nil,
        createdAt: String
    ) {
        self.id = id
        self.name = name
        self.projectID = projectID
        self.baseAssetID = baseAssetID
        self.createdAt = createdAt
    }
}

public struct VariantMember: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "variant_members"

    public var id: String
    public var variantID: String
    public var assetID: String
    public var sequence: Int
    public var isSelected: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case variantID = "variant_id"
        case assetID = "asset_id"
        case sequence
        case isSelected = "is_selected"
    }

    public init(
        id: String = UUID().uuidString,
        variantID: String,
        assetID: String,
        sequence: Int,
        isSelected: Bool = false
    ) {
        self.id = id
        self.variantID = variantID
        self.assetID = assetID
        self.sequence = sequence
        self.isSelected = isSelected
    }
}
