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
    /// Where the charge came from (v10): nil for the app's own generation, `external` for a cost
    /// an import reported (`SpendLog.externalSource`).
    public var source: String?

    /// The `source` of a cost reported by `import_asset` for an image made outside the app.
    public static let externalSource = "external"

    enum CodingKeys: String, CodingKey {
        case id
        case assetID = "asset_id"
        case providerID = "provider_id"
        case estimatedCost = "estimated_cost"
        case actualCost = "actual_cost"
        case timestamp
        case source
    }

    public init(
        id: String = UUID().uuidString,
        assetID: String,
        providerID: String,
        estimatedCost: Double? = nil,
        actualCost: Double? = nil,
        timestamp: String,
        source: String? = nil
    ) {
        self.id = id
        self.assetID = assetID
        self.providerID = providerID
        self.estimatedCost = estimatedCost
        self.actualCost = actualCost
        self.timestamp = timestamp
        self.source = source
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
