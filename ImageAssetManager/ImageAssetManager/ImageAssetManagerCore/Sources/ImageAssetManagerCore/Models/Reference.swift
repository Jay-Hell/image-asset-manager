import GRDB
import Foundation

public struct ReferenceSet: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "reference_sets"

    public var id: String
    public var projectID: String
    public var name: String
    public var isActive: Bool
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case name
        case isActive = "is_active"
        case createdAt = "created_at"
    }

    public init(
        id: String = UUID().uuidString,
        projectID: String,
        name: String,
        isActive: Bool = false,
        createdAt: String
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.isActive = isActive
        self.createdAt = createdAt
    }
}

public struct ReferenceEntry: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "reference_entries"

    public var id: String
    public var referenceSetID: String
    public var assetID: String
    public var role: String
    public var weight: Double
    public var notes: String?

    enum CodingKeys: String, CodingKey {
        case id
        case referenceSetID = "reference_set_id"
        case assetID = "asset_id"
        case role, weight, notes
    }

    public init(
        id: String = UUID().uuidString,
        referenceSetID: String,
        assetID: String,
        role: String,
        weight: Double = 1.0,
        notes: String? = nil
    ) {
        self.id = id
        self.referenceSetID = referenceSetID
        self.assetID = assetID
        self.role = role
        self.weight = weight
        self.notes = notes
    }
}

public struct AssetReference: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "asset_references"

    public var id: String
    public var assetID: String
    public var referenceSetID: String?
    public var referenceEntryID: String?
    public var roleUsed: String?
    public var weightUsed: Double?
    public var passedToAPI: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case assetID = "asset_id"
        case referenceSetID = "reference_set_id"
        case referenceEntryID = "reference_entry_id"
        case roleUsed = "role_used"
        case weightUsed = "weight_used"
        case passedToAPI = "passed_to_api"
    }

    public init(
        id: String = UUID().uuidString,
        assetID: String,
        referenceSetID: String? = nil,
        referenceEntryID: String? = nil,
        roleUsed: String? = nil,
        weightUsed: Double? = nil,
        passedToAPI: Bool = false
    ) {
        self.id = id
        self.assetID = assetID
        self.referenceSetID = referenceSetID
        self.referenceEntryID = referenceEntryID
        self.roleUsed = roleUsed
        self.weightUsed = weightUsed
        self.passedToAPI = passedToAPI
    }
}
