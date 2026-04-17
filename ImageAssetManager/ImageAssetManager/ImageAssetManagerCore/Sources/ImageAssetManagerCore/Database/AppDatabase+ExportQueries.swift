import GRDB
import Foundation

extension AppDatabase {
    public func fetchExportPresets() async throws -> [ExportPreset] {
        try await read { db in
            try ExportPreset.order(Column("created_at")).fetchAll(db)
        }
    }

    public func insertExportPreset(_ preset: ExportPreset) async throws {
        try await write { db in try preset.insert(db) }
    }

    public func updateExportPreset(_ preset: ExportPreset) async throws {
        try await write { db in try preset.update(db) }
    }

    public func deleteExportPreset(id: String) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM export_presets WHERE id = ?", arguments: [id])
        }
    }
}
