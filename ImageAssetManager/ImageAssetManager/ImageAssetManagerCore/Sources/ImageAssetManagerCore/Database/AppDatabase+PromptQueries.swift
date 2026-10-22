import GRDB
import Foundation

extension AppDatabase {
    public func searchPrompts(text: String? = nil, sector: String? = nil) async throws -> [Prompt] {
        try await read { db in
            var request = Prompt.order(Column("usage_count").desc, Column("updated_at").desc)
            if let sector {
                request = request.filter(Column("sector") == sector)
            }
            if let text, !text.isEmpty {
                let pattern = "%\(text)%"
                request = request.filter(SQL("title LIKE \(pattern) OR body LIKE \(pattern)"))
            }
            return try request.fetchAll(db)
        }
    }

    public func updatePrompt(_ prompt: Prompt) async throws {
        try await write { db in try prompt.update(db) }
    }

    public func deletePrompt(id: String) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM prompts WHERE id = ?", arguments: [id])
        }
    }

    public func incrementPromptUsage(promptID: String) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try await write { db in
            try db.execute(
                sql: "UPDATE prompts SET usage_count = usage_count + 1, last_used_at = ? WHERE id = ?",
                arguments: [now, promptID]
            )
        }
    }

    public func fetchAssetsForPrompt(promptID: String) async throws -> [Asset] {
        try await read { db in
            try Asset
                .filter(SQL("id IN (SELECT asset_id FROM prompt_asset WHERE prompt_id = \(promptID))"))
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }

    public func fetchDistinctSectors() async throws -> [String] {
        try await read { db in
            try Row
                .fetchAll(db, sql: "SELECT DISTINCT sector FROM prompts WHERE sector IS NOT NULL ORDER BY sector")
                .compactMap { $0["sector"] as? String }
        }
    }

    public func findSimilarPrompts(to draft: String, limit: Int = 5) async throws -> [String] {
        let stopwords: Set<String> = ["a", "an", "the", "and", "or", "of", "in", "on", "at",
                                       "to", "for", "with", "is", "are", "was", "be", "that",
                                       "this", "it", "as", "from", "by", "very", "so", "have"]
        let keywords = draft
            .lowercased()
            .components(separatedBy: .init(charactersIn: " .,;:!?\"'()[]{}"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 3 && !stopwords.contains($0) }

        guard !keywords.isEmpty else { return [] }

        var conditions: [String] = []
        var args: StatementArguments = []
        for kw in keywords.prefix(8) {
            conditions.append("body LIKE ?")
            _ = args.append(contentsOf: ["%\(kw)%"])
        }
        let capturedConditions = conditions
        let capturedArgs = args
        let capturedLimit = limit

        return try await read { db in
            let sql = "SELECT body FROM prompts WHERE \(capturedConditions.joined(separator: " OR ")) ORDER BY usage_count DESC LIMIT ?"
            var finalArgs = capturedArgs
            _ = finalArgs.append(contentsOf: [capturedLimit])
            return try Row.fetchAll(db, sql: sql, arguments: finalArgs)
                .compactMap { $0["body"] as? String }
        }
    }
}
