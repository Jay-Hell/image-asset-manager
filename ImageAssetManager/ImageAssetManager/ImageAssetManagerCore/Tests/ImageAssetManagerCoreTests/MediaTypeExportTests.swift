import Testing
import Foundation
import GRDB
@testable import ImageAssetManagerCore

@Suite("media_type out of the library")
struct MediaTypeExportTests {

    private func library() throws -> (URL, AppDatabase) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "iam-mt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, try AppDatabase(path: dir.appending(path: "library.db").path(percentEncoded: false)))
    }

    /// Ruling 8 (R2-1 finding 9): an imported SVG can be any file an agent named, so export writes
    /// the sanitised copy, as the preview draws, never the stored bytes.
    @Test func svgExportsSanitisedWithAnSVGName() throws {
        let dest = FileManager.default.temporaryDirectory.appending(path: "iam-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let given = Data("""
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 4 4" onload="alert(1)">\
            <script>alert(2)</script><rect width="4" height="4" fill="red"/></svg>
            """.utf8)

        let out = try ImageExporter.exportVector(svgData: given, to: dest, baseFilename: "logo")

        #expect(out.lastPathComponent == "logo.svg")
        let written = String(decoding: try Data(contentsOf: out), as: UTF8.self)
        #expect(!written.contains("script") && !written.contains("onload") && !written.contains("alert"))
        // The pair: the drawing itself survives.
        #expect(written.contains("<rect") && written.contains("viewBox=\"0 0 4 4\""))

        // An SVG the sanitiser cannot read is refused, and nothing is written.
        #expect(throws: ImageExporter.ExportError.self) {
            try ImageExporter.exportVector(svgData: Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><rect".utf8), to: dest, baseFilename: "broken")
        }
        #expect(!FileManager.default.fileExists(atPath: dest.appending(path: "broken.svg").path(percentEncoded: false)))
    }

    @Test func indexJSONCarriesMediaType() async throws {
        let (dir, db) = try library()
        try await db.write { db in
            try Asset(id: "s", filename: "s.svg", fileHash: "h", providerID: "p", modelID: "m", createdAt: "2026-10-22T00:00:00Z").insert(db)
            try Asset(id: "r", filename: "r.png", fileHash: "h", providerID: "p", modelID: "m", createdAt: "2026-10-22T00:00:00Z").insert(db)
            // As App Store 1.0.x writes a row: no media_type.
            try V7LibraryFixture.insertAsOldBuild(db, id: "old", filename: "old.JPG")
        }
        let indexURL = dir.appending(path: "index.json")
        try Data("[]".utf8).write(to: indexURL)

        try await IndexExporter.export(from: db, to: indexURL, assetsBaseURL: dir.appending(path: "assets"))

        let records = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [[String: Any]])
        var byID: [String: String] = [:]
        for record in records {
            byID[record["id"] as? String ?? "?"] = record["media_type"] as? String
        }
        #expect(byID == ["s": "image/svg+xml", "r": "image/png", "old": "image/jpeg"])
    }

    @Test func mcpReadToolsCarryMediaType() async throws {
        let (dir, db) = try library()
        try await db.write { db in
            try Asset(id: "s", filename: "s.svg", fileHash: "h", providerID: "p", modelID: "m", createdAt: "2026-10-22T00:00:00Z").insert(db)
            // As App Store 1.0.x writes a row: media_type NULL, so only the fallback can name it.
            try V7LibraryFixture.insertAsOldBuild(db, id: "old", filename: "old.JPG")
            try db.execute(sql: """
                INSERT INTO prompts (id, title, body, usage_count, created_at, updated_at)
                VALUES ('pr', 'Logo', 'A logo', 0, '2026-10-22T00:00:00Z', '2026-10-22T00:00:00Z')
                """)
            try db.execute(sql: "INSERT INTO prompt_asset (prompt_id, asset_id) VALUES ('pr', 's'), ('pr', 'old')")
        }
        let expected = ["s": "image/svg+xml", "old": "image/jpeg"]
        let stored = try await db.read { db in
            try String?.fetchOne(db, sql: "SELECT media_type FROM assets WHERE id = 'old'")
        }
        #expect(stored == .some(nil), "the old-build row must reach the MCP with no media_type of its own")

        var fromDetail: [String: String] = [:]
        for id in ["s", "old"] {
            let detail = try #require(try await db.mcpGetAssetDetail(id: id, libraryURL: dir))
            let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(detail)) as? [String: Any])
            let asset = try #require(json["asset"] as? [String: Any])
            fromDetail[id] = asset["media_type"] as? String
        }
        #expect(fromDetail == expected)

        let found = try await db.mcpSearchAssets(query: nil, tags: nil, project: nil, provider: nil,
                                                 aspectRatio: nil, dateFrom: nil, dateTo: nil,
                                                 limit: 10, libraryURL: dir)
        #expect(Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0.mediaType ?? "nil") }) == expected)

        let prompt = try #require(try await db.mcpGetPrompt(id: "pr", libraryURL: dir))
        #expect(Dictionary(uniqueKeysWithValues: prompt.linkedAssets.map { ($0.id, $0.mediaType ?? "nil") }) == expected)
    }
}
