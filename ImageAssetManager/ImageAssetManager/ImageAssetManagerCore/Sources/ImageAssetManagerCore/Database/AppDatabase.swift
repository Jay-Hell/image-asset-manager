import GRDB
import Foundation

public final class AppDatabase: Sendable {
    private let writer: DatabaseQueue

    public init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }
        writer = try DatabaseQueue(path: path, configuration: config)

        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial_schema") { db in
            try db.create(table: "projects") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("client_name", .text)
                t.column("default_provider_id", .text)
                t.column("default_model_id", .text)
                t.column("active_reference_set_id", .text)
                t.column("obsidian_note_path", .text)
                t.column("created_at", .text).notNull()
            }

            try db.create(table: "collections") { t in
                t.primaryKey("id", .text)
                t.column("project_id", .text).notNull().references("projects", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("obsidian_note_path", .text)
                t.column("created_at", .text).notNull()
            }

            try db.create(table: "assets") { t in
                t.primaryKey("id", .text)
                t.column("filename", .text).notNull()
                t.column("file_hash", .text).notNull()
                t.column("project_id", .text).references("projects", onDelete: .setNull)
                t.column("collection_id", .text).references("collections", onDelete: .setNull)
                t.column("provider_id", .text).notNull()
                t.column("model_id", .text).notNull()
                t.column("prompt", .text)
                t.column("negative_prompt", .text)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("aspect_ratio", .text)
                t.column("seed", .text)
                t.column("generation_params", .text)
                t.column("estimated_cost", .double)
                t.column("actual_cost", .double)
                t.column("created_at", .text).notNull()
                t.column("imported_at", .text)
                t.column("obsidian_embedded", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "assets_project_id", on: "assets", columns: ["project_id"])
            try db.create(index: "assets_collection_id", on: "assets", columns: ["collection_id"])
            try db.create(index: "assets_created_at", on: "assets", columns: ["created_at"])

            try db.create(table: "tags") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique()
            }

            try db.create(table: "asset_tags") { t in
                t.column("asset_id", .text).notNull().references("assets", onDelete: .cascade)
                t.column("tag_id", .text).notNull().references("tags", onDelete: .cascade)
                t.primaryKey(["asset_id", "tag_id"])
            }

            try db.create(table: "variants") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("project_id", .text).notNull().references("projects", onDelete: .cascade)
                t.column("base_asset_id", .text).references("assets", onDelete: .setNull)
                t.column("created_at", .text).notNull()
            }

            try db.create(table: "variant_members") { t in
                t.primaryKey("id", .text)
                t.column("variant_id", .text).notNull().references("variants", onDelete: .cascade)
                t.column("asset_id", .text).notNull().references("assets", onDelete: .cascade)
                t.column("sequence", .integer).notNull()
                t.column("is_selected", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "reference_sets") { t in
                t.primaryKey("id", .text)
                t.column("project_id", .text).notNull().references("projects", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("is_active", .boolean).notNull().defaults(to: false)
                t.column("created_at", .text).notNull()
            }

            try db.create(table: "reference_entries") { t in
                t.primaryKey("id", .text)
                t.column("reference_set_id", .text).notNull().references("reference_sets", onDelete: .cascade)
                t.column("asset_id", .text).notNull().references("assets", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("weight", .double).notNull().defaults(to: 1.0)
                t.column("notes", .text)
            }

            try db.create(table: "asset_references") { t in
                t.primaryKey("id", .text)
                t.column("asset_id", .text).notNull().references("assets", onDelete: .cascade)
                t.column("reference_set_id", .text).references("reference_sets", onDelete: .setNull)
                t.column("reference_entry_id", .text).references("reference_entries", onDelete: .setNull)
                t.column("role_used", .text)
                t.column("weight_used", .double)
                t.column("passed_to_api", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "prompts") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("body", .text).notNull()
                t.column("negative_prompt", .text)
                t.column("sector", .text)
                t.column("tags", .text)
                t.column("usage_count", .integer).notNull().defaults(to: 0)
                t.column("last_used_at", .text)
                t.column("obsidian_note_path", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            try db.create(table: "prompt_asset") { t in
                t.column("prompt_id", .text).notNull().references("prompts", onDelete: .cascade)
                t.column("asset_id", .text).notNull().references("assets", onDelete: .cascade)
                t.primaryKey(["prompt_id", "asset_id"])
            }

            try db.create(table: "spend_log") { t in
                t.primaryKey("id", .text)
                t.column("asset_id", .text).notNull().references("assets", onDelete: .cascade)
                t.column("provider_id", .text).notNull()
                t.column("estimated_cost", .double)
                t.column("actual_cost", .double)
                t.column("timestamp", .text).notNull()
            }
            try db.create(index: "spend_log_timestamp", on: "spend_log", columns: ["timestamp"])

            try db.create(table: "asset_usage") { t in
                t.primaryKey("id", .text)
                t.column("asset_id", .text).notNull().references("assets", onDelete: .cascade)
                t.column("used_in", .text)
                t.column("used_at", .text)
                t.column("noted_by", .text)
            }

            try db.create(table: "providers") { t in
                t.primaryKey("id", .text)
                t.column("display_name", .text).notNull()
                t.column("supports_reference_images", .boolean).notNull().defaults(to: false)
                t.column("max_reference_images", .integer).notNull().defaults(to: 0)
                t.column("supported_roles", .text)
                t.column("cost_model", .text)
            }

            try db.create(table: "prompt_refinements") { t in
                t.primaryKey("id", .text)
                t.column("asset_id", .text).notNull().references("assets", onDelete: .cascade)
                t.column("prompt_id", .text).references("prompts", onDelete: .setNull)
                t.column("mode", .text).notNull()
                t.column("draft_prompt", .text).notNull()
                t.column("final_prompt", .text).notNull()
                t.column("conversation", .text).notNull()
                t.column("model_used", .text).notNull()
                t.column("created_at", .text).notNull()
            }
        }

        migrator.registerMigration("v2_export_presets") { db in
            try db.create(table: "export_presets") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("format", .text).notNull().defaults(to: "png")
                t.column("max_width", .integer)
                t.column("max_height", .integer)
                t.column("jpeg_quality", .double).notNull().defaults(to: 0.85)
                t.column("suffix", .text).notNull().defaults(to: "")
                t.column("created_at", .text).notNull()
            }
        }

        migrator.registerMigration("v3_asset_hidden_column") { db in
            try db.alter(table: "assets") { t in
                t.add(column: "is_hidden", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v4_variants_nullable_project_and_backfill") { db in
            // 1. Rebuild `variants` with a nullable project_id (SQLite can't drop NOT NULL in-place).
            try db.execute(sql: """
                CREATE TABLE variants_new (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    project_id TEXT REFERENCES projects(id) ON DELETE CASCADE,
                    base_asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL,
                    created_at TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                INSERT INTO variants_new (id, name, project_id, base_asset_id, created_at)
                SELECT id, name, project_id, base_asset_id, created_at FROM variants
            """)
            try db.execute(sql: "DROP TABLE variants")
            try db.execute(sql: "ALTER TABLE variants_new RENAME TO variants")

            // 2. Backfill: every asset not already in a variant gets a solo family.
            let now = ISO8601DateFormatter().string(from: Date())
            let orphanAssets = try Row.fetchAll(db, sql: """
                SELECT id, project_id, filename, prompt FROM assets
                WHERE id NOT IN (SELECT asset_id FROM variant_members)
            """)
            for row in orphanAssets {
                let assetID: String = row["id"]
                let projectID: String? = row["project_id"]
                let filename: String = row["filename"]
                let prompt: String? = row["prompt"]

                let familyName = defaultVariantFamilyName(prompt: prompt, filename: filename)
                let variantID = UUID().uuidString
                try db.execute(
                    sql: "INSERT INTO variants (id, name, project_id, base_asset_id, created_at) VALUES (?, ?, ?, ?, ?)",
                    arguments: [variantID, familyName, projectID, assetID, now]
                )
                try db.execute(
                    sql: "INSERT INTO variant_members (id, variant_id, asset_id, sequence, is_selected) VALUES (?, ?, ?, ?, ?)",
                    arguments: [UUID().uuidString, variantID, assetID, 1, true]
                )
            }
        }

        try migrator.migrate(writer)
    }

    /// Flush the WAL journal into the main database file so it is self-contained before a copy or move.
    /// Must run outside a transaction — uses barrierWriteWithoutTransaction for this reason.
    public func checkpoint() async throws {
        _ = try await writer.barrierWriteWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }
    }

    /// Delete all user data from every table. Provider config and export presets are preserved.
    public func clearAllData() async throws {
        try await writer.write { db in
            // Delete in FK-safe order (children before parents).
            try db.execute(sql: "DELETE FROM prompt_refinements")
            try db.execute(sql: "DELETE FROM asset_usage")
            try db.execute(sql: "DELETE FROM spend_log")
            try db.execute(sql: "DELETE FROM prompt_asset")
            try db.execute(sql: "DELETE FROM asset_references")
            try db.execute(sql: "DELETE FROM reference_entries")
            try db.execute(sql: "DELETE FROM variant_members")
            try db.execute(sql: "DELETE FROM asset_tags")
            try db.execute(sql: "DELETE FROM assets")
            try db.execute(sql: "DELETE FROM variants")
            try db.execute(sql: "DELETE FROM reference_sets")
            try db.execute(sql: "DELETE FROM collections")
            try db.execute(sql: "DELETE FROM projects")
            try db.execute(sql: "DELETE FROM tags")
            try db.execute(sql: "DELETE FROM prompts")
            // Preserved: providers, export_presets
        }
    }

    public func read<T: Sendable>(
        _ block: @Sendable (Database) throws -> T
    ) async throws -> T {
        try await writer.read(block)
    }

    @discardableResult
    public func write<T: Sendable>(
        _ block: @Sendable (Database) throws -> T
    ) async throws -> T {
        try await writer.write(block)
    }
}

/// Derive a default variant-family name from an asset's prompt (preferred) or filename.
/// Used during the v4 backfill and by live generation/import flows so every asset ends up
/// in a family of at least one member.
public func defaultVariantFamilyName(prompt: String?, filename: String) -> String {
    let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedPrompt.isEmpty {
        let condensed = trimmedPrompt.replacingOccurrences(of: "\n", with: " ")
        return String(condensed.prefix(40)).trimmingCharacters(in: .whitespaces)
    }
    let base = (filename as NSString).deletingPathExtension
    return base.isEmpty ? "Untitled" : base
}
