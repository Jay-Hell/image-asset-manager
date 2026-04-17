import Testing
import Foundation
@testable import ImageAssetManagerCore

@Suite("IndexExporter")
struct IndexExporterTests {
    func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    @Test func exportsEmptyLibraryAsEmptyArray() async throws {
        let db = try AppDatabase(path: ":memory:")
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let indexURL = dir.appending(path: "index.json")
        try Data("[]".utf8).write(to: indexURL)

        try await IndexExporter.export(from: db, to: indexURL, assetsBaseURL: dir.appending(path: "assets"))

        let data = try Data(contentsOf: indexURL)
        let decoded = try JSONDecoder().decode([IndexAssetRecord].self, from: data)
        #expect(decoded.isEmpty)
    }

    @Test func exportedRecordContainsTags() async throws {
        let db = try AppDatabase(path: ":memory:")
        let now = iso8601Now()
        let asset = Asset(filename: "x.png", fileHash: "h", providerID: "p", modelID: "m", createdAt: now)
        let tag = Tag(name: "landscape")
        let assetTag = AssetTag(assetID: asset.id, tagID: tag.id)

        try await db.write { db in
            try asset.insert(db)
            try tag.insert(db)
            try assetTag.insert(db)
        }

        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let indexURL = dir.appending(path: "index.json")
        try Data("[]".utf8).write(to: indexURL)

        try await IndexExporter.export(from: db, to: indexURL, assetsBaseURL: dir.appending(path: "assets"))

        let data = try Data(contentsOf: indexURL)
        let records = try JSONDecoder().decode([IndexAssetRecord].self, from: data)
        #expect(records.count == 1)
        #expect(records[0].tags.contains("landscape"))
    }
}
