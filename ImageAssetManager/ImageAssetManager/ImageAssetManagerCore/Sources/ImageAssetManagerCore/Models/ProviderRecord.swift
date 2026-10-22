import GRDB
import Foundation

public struct ProviderRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "providers"

    public var id: String
    public var displayName: String
    public var supportsReferenceImages: Bool
    public var maxReferenceImages: Int
    public var supportedRoles: String?  // JSON array
    public var costModel: String?       // JSON blob

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case supportsReferenceImages = "supports_reference_images"
        case maxReferenceImages = "max_reference_images"
        case supportedRoles = "supported_roles"
        case costModel = "cost_model"
    }

    public init(
        id: String,
        displayName: String,
        supportsReferenceImages: Bool = false,
        maxReferenceImages: Int = 0,
        supportedRoles: String? = nil,
        costModel: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.supportsReferenceImages = supportsReferenceImages
        self.maxReferenceImages = maxReferenceImages
        self.supportedRoles = supportedRoles
        self.costModel = costModel
    }
}
