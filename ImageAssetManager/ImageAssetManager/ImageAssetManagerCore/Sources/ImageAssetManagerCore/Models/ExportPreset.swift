import GRDB
import Foundation

public struct ExportPreset: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "export_presets"

    public var id: String
    public var name: String
    public var format: String       // "png" | "jpeg" | "webp"
    public var maxWidth: Int?
    public var maxHeight: Int?
    public var jpegQuality: Double  // 0.0–1.0; ignored for png/webp
    public var suffix: String       // appended before extension, e.g. "_2x"
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, format
        case maxWidth = "max_width"
        case maxHeight = "max_height"
        case jpegQuality = "jpeg_quality"
        case suffix
        case createdAt = "created_at"
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        format: String = "png",
        maxWidth: Int? = nil,
        maxHeight: Int? = nil,
        jpegQuality: Double = 0.85,
        suffix: String = "",
        createdAt: String
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.jpegQuality = jpegQuality
        self.suffix = suffix
        self.createdAt = createdAt
    }
}
