import Testing
import Foundation
@testable import ImageAssetManagerCore

@Suite("media_type out of the library")
struct MediaTypeExportTests {

    private func library() throws -> (URL, AppDatabase) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "iam-mt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, try AppDatabase(path: dir.appending(path: "library.db").path(percentEncoded: false)))
    }

    @Test func svgExportsAsTheSameBytesWithAnSVGName() throws {
        let dest = FileManager.default.temporaryDirectory.appending(path: "iam-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let given = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 4 4\">\r\n<!-- kept -->\r\n</svg>".utf8)

        let out = try ImageExporter.exportVector(svgData: given, to: dest, baseFilename: "logo")

        #expect(out.lastPathComponent == "logo.svg")
        #expect(try Data(contentsOf: out) == given)
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
        }

        let detail = try #require(try await db.mcpGetAssetDetail(id: "s", libraryURL: dir))
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(detail)) as? [String: Any])
        let asset = try #require(json["asset"] as? [String: Any])
        #expect(asset["media_type"] as? String == "image/svg+xml")

        let found = try await db.mcpSearchAssets(query: nil, tags: nil, project: nil, provider: nil,
                                                 aspectRatio: nil, dateFrom: nil, dateTo: nil,
                                                 limit: 10, libraryURL: dir)
        #expect(found.map(\.mediaType) == ["image/svg+xml"])
    }
}
