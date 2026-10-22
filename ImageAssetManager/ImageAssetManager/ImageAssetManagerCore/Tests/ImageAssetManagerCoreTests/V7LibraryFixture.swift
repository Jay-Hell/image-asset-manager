import Foundation
import GRDB
@testable import ImageAssetManagerCore

/// A library as App Store 1.0.x leaves it: schema v1–v7 built by that build's own migrations
/// (`AppDatabase.appStore1_0Migrator()`, imported, not copied), WAL journal, and real rows in
/// every table the v8 change could disturb.
struct V7LibraryFixture {
    let directory: URL
    var databasePath: String { directory.appending(path: "library.db").path(percentEncoded: false) }
    var backupsURL: URL { directory.appending(path: LibraryBackup.folderName) }

    /// filename → what v8 must backfill, worked by hand from the extension.
    static let expectedMediaTypes: [String: String?] = [
        "a-png": "image/png",
        "a-jpg": "image/jpeg",
        "a-jpeg": "image/jpeg",
        "a-webp": "image/webp",
        "a-heic": "image/heic",
        "a-svg": "image/svg+xml",
        "a-gif": nil,
    ]

    static let assetRows: [(id: String, filename: String)] = [
        ("a-png", "hero.png"),
        ("a-jpg", "IMPORTED_01.JPG"),
        ("a-jpeg", "6F1C.jpeg"),
        ("a-webp", "banner.webp"),
        ("a-heic", "2026-04-18_photo.heic"),
        ("a-svg", "logo.svg"),
        ("a-gif", "spinner.gif"),
    ]

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "iam-v7-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let queue = try Self.openLikeTheApp(path: databasePath)
        try AppDatabase.appStore1_0Migrator().migrate(queue)
        try queue.write { db in try Self.seed(db) }
        try queue.close()
    }

    /// Same connection set-up as `AppDatabase.init`.
    static func openLikeTheApp(path: String) throws -> DatabaseQueue {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }
        return try DatabaseQueue(path: path, configuration: config)
    }

    private static func seed(_ db: Database) throws {
        let now = "2026-04-18T09:00:00Z"
        try db.execute(sql: "INSERT INTO clients (id, name, created_at) VALUES ('c1', 'TfWM', ?)", arguments: [now])
        try db.execute(sql: """
            INSERT INTO projects (id, name, client_name, client_id, created_at)
            VALUES ('p1', 'Swift Go', 'TfWM', 'c1', ?), ('p2', 'Ionic brand', NULL, NULL, ?)
            """, arguments: [now, now])
        try db.execute(sql: "INSERT INTO tags (id, name) VALUES ('t1', 'hero')")

        for (index, row) in assetRows.enumerated() {
            let project = index % 2 == 0 ? "p1" : "p2"
            try db.execute(sql: """
                INSERT INTO assets (id, filename, file_hash, project_id, provider_id, model_id,
                                    prompt, width, height, aspect_ratio, estimated_cost, created_at,
                                    obsidian_embedded, is_hidden)
                VALUES (?, ?, ?, ?, 'nano_banana', 'gemini-2.5-flash-image', ?, 1024, 768, '4:3', 0.03, ?, 0, 0)
                """, arguments: [row.id, row.filename, "hash-\(row.id)", project, "Prompt for \(row.id)", now])
            try db.execute(sql: "INSERT INTO asset_projects (asset_id, project_id, is_primary) VALUES (?, ?, 1)",
                           arguments: [row.id, project])
            try db.execute(sql: "INSERT INTO variants (id, name, project_id, base_asset_id, created_at) VALUES (?, ?, ?, ?, ?)",
                           arguments: ["v-\(row.id)", "Family \(row.id)", project, row.id, now])
            try db.execute(sql: "INSERT INTO variant_members (id, variant_id, asset_id, sequence, is_selected) VALUES (?, ?, ?, 1, 1)",
                           arguments: ["vm-\(row.id)", "v-\(row.id)", row.id])
            try db.execute(sql: "INSERT INTO spend_log (id, asset_id, provider_id, estimated_cost, timestamp) VALUES (?, ?, 'nano_banana', 0.03, ?)",
                           arguments: ["s-\(row.id)", row.id, now])
            try db.execute(sql: "INSERT INTO asset_tags (asset_id, tag_id) VALUES (?, 't1')", arguments: [row.id])
        }
    }

    /// An asset insert exactly as App Store 1.0.x writes one: its `Asset` has no `media_type`.
    static func insertAsOldBuild(_ db: Database, id: String, filename: String) throws {
        try db.execute(sql: """
            INSERT INTO assets (id, filename, file_hash, project_id, provider_id, model_id, prompt,
                                negative_prompt, width, height, aspect_ratio, seed, generation_params,
                                estimated_cost, actual_cost, created_at, imported_at, obsidian_embedded, is_hidden)
            VALUES (?, ?, 'h', NULL, 'imported', 'import', NULL, NULL, 10, 10, NULL, NULL, NULL,
                    NULL, NULL, '2026-10-22T10:00:00Z', NULL, 0, 0)
            """, arguments: [id, filename])
    }

    func backupFiles() throws -> [String] {
        guard FileManager.default.fileExists(atPath: backupsURL.path(percentEncoded: false)) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: backupsURL.path(percentEncoded: false))
            .filter { $0.hasPrefix("library-") && $0.hasSuffix(".db") }
            .sorted()
    }
}
