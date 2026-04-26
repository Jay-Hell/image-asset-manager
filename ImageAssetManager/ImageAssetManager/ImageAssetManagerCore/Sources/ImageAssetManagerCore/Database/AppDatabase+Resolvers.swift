import GRDB
import Foundation

/// Name-or-UUID resolution for entities that might be referenced by either form
/// (e.g. the MCP `generate_image` tool, where a human caller uses names and
/// Claude Code often has UUIDs from previous tool results).
extension AppDatabase {

    /// Try to find a project by its UUID first; if the input isn't a valid UUID
    /// or no project matches, fall back to an exact name match.
    public func findProject(idOrName: String) async throws -> Project? {
        try await read { db in
            if UUID(uuidString: idOrName) != nil,
               let byID = try Project.fetchOne(db, key: idOrName) {
                return byID
            }
            return try Project
                .filter(Column("name") == idOrName)
                .fetchOne(db)
        }
    }
}
