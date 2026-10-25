import GRDB
import Foundation

/// Name-or-UUID resolution for entities that might be referenced by either form
/// (e.g. the MCP `generate_image` tool, where a human caller uses names and
/// Claude Code often has UUIDs from previous tool results).
extension AppDatabase {

    /// Try to find a project by its UUID first; if the input isn't a valid UUID
    /// or no project matches, fall back to an exact name match, then to the same name in any
    /// case (names are unique case-insensitively, so "labs" can only mean "Labs").
    public func findProject(idOrName: String) async throws -> Project? {
        try await read { db in
            if UUID(uuidString: idOrName) != nil,
               let byID = try Project.fetchOne(db, key: idOrName) {
                return byID
            }
            if let exact = try Project.filter(Column("name") == idOrName).fetchOne(db) {
                return exact
            }
            let trimmed = idOrName.trimmingCharacters(in: .whitespaces)
            return try Project
                .filter(SQL("LOWER(name) = LOWER(\(trimmed))"))
                .order(Column("created_at"), Column("id"))
                .fetchOne(db)
        }
    }

    /// The error for a project name or ID that matches nothing, listing the projects there are
    /// (Q1): an agent picks one, or makes a new one with `create_project`, rather than guessing.
    public func unknownProjectError(_ raw: String) async throws -> MCPGenerateError {
        let names = try await read { db in
            try String.fetchAll(db, sql: "SELECT name FROM projects ORDER BY name COLLATE NOCASE")
        }
        let list = names.isEmpty ? "there are no projects yet" : "existing projects: \(names.joined(separator: ", "))"
        return .notFound("project '\(raw)' (\(list)). Use one of those, or create it first with create_project")
    }
}
