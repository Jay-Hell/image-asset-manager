import GRDB
import Foundation

public enum TagError: Error, Equatable, LocalizedError {
    /// Another tag has this name, ignoring case and surrounding spaces.
    case nameInUse(String)
    case emptyName
    case notFound
    /// The tag to keep is not among the tags to merge.
    case targetNotSelected

    public var errorDescription: String? {
        switch self {
        case .nameInUse(let existing): return "A tag named \u{201C}\(existing)\u{201D} already exists (tag names are compared ignoring case)."
        case .emptyName: return "A tag needs a name."
        case .notFound: return "That tag no longer exists."
        case .targetNotSelected: return "Choose which of the selected tags to keep."
        }
    }
}

/// One line of the tag manager: a tag and how many assets carry it (zero is listed).
public struct TagRow: Sendable, Equatable {
    public let id: String
    public let name: String
    public let count: Int
}

/// The tag manager's logic. The view only calls these.
extension AppDatabase {

    /// Every tag, including unused ones, with its asset count, by name ignoring case.
    public func fetchTagRows() async throws -> [TagRow] {
        try await read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.id, t.name, COUNT(at.asset_id) AS count
                FROM tags t LEFT JOIN asset_tags at ON at.tag_id = t.id
                GROUP BY t.id
                ORDER BY t.name COLLATE NOCASE, t.id
                """).map { TagRow(id: $0["id"], name: $0["name"], count: $0["count"]) }
        }
    }

    /// Rename a tag. Refused when another tag has the new name in any case; changing only the
    /// case of the tag's own name is allowed.
    public func renameTag(id: String, newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw TagError.emptyName }
        try await write { db in
            guard try Tag.exists(db, key: id) else { throw TagError.notFound }
            if let clash = try Tag
                .filter(Column("id") != id)
                .fetchAll(db)
                .first(where: { NameMatch.same($0.name, trimmed) }) {
                throw TagError.nameInUse(clash.name)
            }
            try db.execute(sql: "UPDATE tags SET name = ? WHERE id = ?", arguments: [trimmed, id])
        }
    }

    /// Merge `ids` into `targetID` (which must be one of them): every asset that carries any of
    /// the others now carries the target once, and the others are removed. Returns how many
    /// tags were folded in.
    @discardableResult
    public func mergeTags(ids: [String], into targetID: String) async throws -> Int {
        guard ids.contains(targetID) else { throw TagError.targetNotSelected }
        let sources = Array(Set(ids.filter { $0 != targetID }))
        return try await write { db in
            guard try Tag.exists(db, key: targetID) else { throw TagError.notFound }
            var folded = 0
            for source in sources {
                guard try Tag.exists(db, key: source) else { continue }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO asset_tags (asset_id, tag_id)
                    SELECT asset_id, ? FROM asset_tags WHERE tag_id = ?
                    """, arguments: [targetID, source])
                try db.execute(sql: "DELETE FROM asset_tags WHERE tag_id = ?", arguments: [source])
                try db.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [source])
                folded += 1
            }
            return folded
        }
    }

    /// Delete a tag: its links go, never the assets.
    public func deleteTag(id: String) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM asset_tags WHERE tag_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM tags WHERE id = ?", arguments: [id])
        }
    }
}
