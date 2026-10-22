import GRDB
import Foundation

public struct SpendLog: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "spend_log"

    public var id: String
    public var assetID: String
    public var providerID: String
    public var estimatedCost: Double?
    public var actualCost: Double?
    public var timestamp: String

    enum CodingKeys: String, CodingKey {
        case id
        case assetID = "asset_id"
        case providerID = "provider_id"
        case estimatedCost = "estimated_cost"
        case actualCost = "actual_cost"
        case timestamp
    }

    public init(
        id: String = UUID().uuidString,
        assetID: String,
        providerID: String,
        estimatedCost: Double? = nil,
        actualCost: Double? = nil,
        timestamp: String
    ) {
        self.id = id
        self.assetID = assetID
        self.providerID = providerID
        self.estimatedCost = estimatedCost
        self.actualCost = actualCost
        self.timestamp = timestamp
    }
}

public struct AssetUsage: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "asset_usage"

    public var id: String
    public var assetID: String
    public var usedIn: String?
    public var usedAt: String?
    public var notedBy: String?     // "manual" | "claude_code"

    enum CodingKeys: String, CodingKey {
        case id
        case assetID = "asset_id"
        case usedIn = "used_in"
        case usedAt = "used_at"
        case notedBy = "noted_by"
    }

    public init(
        id: String = UUID().uuidString,
        assetID: String,
        usedIn: String? = nil,
        usedAt: String? = nil,
        notedBy: String? = nil
    ) {
        self.id = id
        self.assetID = assetID
        self.usedIn = usedIn
        self.usedAt = usedAt
        self.notedBy = notedBy
    }
}
