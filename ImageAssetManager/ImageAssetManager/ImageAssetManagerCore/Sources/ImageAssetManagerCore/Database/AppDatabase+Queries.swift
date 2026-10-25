import GRDB
import Foundation

public enum ClientError: Error, Equatable {
    case nameInUse
    case hasAssignedProjects
    case notFound
}

// MARK: - Clients
extension AppDatabase {
    public func fetchClients() async throws -> [Client] {
        try await read { db in try Client.order(Column("name")).fetchAll(db) }
    }

    /// Case-insensitive find-or-create. Names are trimmed on write.
    @discardableResult
    public func findOrCreateClient(name: String) async throws -> Client {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ClientError.nameInUse }
        return try await write { db in
            if let existing = try Client
                .filter(SQL("LOWER(name) = LOWER(\(trimmed))"))
                .fetchOne(db) {
                return existing
            }
            let client = Client(name: trimmed, createdAt: iso8601Now())
            try client.insert(db)
            return client
        }
    }

    /// Rename a client. Throws `.nameInUse` if another client already has this name
    /// (case-insensitive). No-op when the new name matches the current one.
    public func renameClient(id: String, newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ClientError.nameInUse }
        try await write { db in
            guard let current = try Client.fetchOne(db, key: id) else {
                throw ClientError.notFound
            }
            if current.name.caseInsensitiveCompare(trimmed) == .orderedSame {
                if current.name != trimmed {
                    try db.execute(sql: "UPDATE clients SET name = ? WHERE id = ?", arguments: [trimmed, id])
                }
                return
            }
            let collision = try Client
                .filter(SQL("LOWER(name) = LOWER(\(trimmed))"))
                .filter(Column("id") != id)
                .fetchCount(db)
            if collision > 0 { throw ClientError.nameInUse }
            try db.execute(sql: "UPDATE clients SET name = ? WHERE id = ?", arguments: [trimmed, id])
        }
    }

    /// Delete a client. Rejects with `.hasAssignedProjects` when any project still
    /// references this client — caller must reassign those projects first.
    public func deleteClient(id: String) async throws {
        try await write { db in
            let count = try Project.filter(Column("client_id") == id).fetchCount(db)
            if count > 0 { throw ClientError.hasAssignedProjects }
            try db.execute(sql: "DELETE FROM clients WHERE id = ?", arguments: [id])
        }
    }
}

// MARK: - Projects
extension AppDatabase {
    public func fetchProjects() async throws -> [Project] {
        try await read { db in try Project.fetchAll(db) }
    }

    public func insertProject(_ project: Project) async throws {
        try await write { db in try project.insert(db) }
    }

    public func renameProject(id: String, newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        try await write { db in
            try db.execute(sql: "UPDATE projects SET name = ? WHERE id = ?", arguments: [trimmed, id])
        }
    }

    /// Assign or clear a project's client. Passing nil detaches the client.
    public func setProjectClient(projectID: String, clientID: String?) async throws {
        try await write { db in
            try db.execute(
                sql: "UPDATE projects SET client_id = ? WHERE id = ?",
                arguments: [clientID, projectID]
            )
        }
    }

    public func deleteProject(id: String) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [id])
        }
    }
}

// MARK: - Asset <-> Projects
extension AppDatabase {
    /// All projects an asset belongs to, sorted by name.
    public func fetchProjectsForAsset(assetID: String) async throws -> [Project] {
        try await read { db in
            try Project.fetchAll(db, sql: """
                SELECT p.* FROM projects p
                JOIN asset_projects ap ON ap.project_id = p.id
                WHERE ap.asset_id = ?
                ORDER BY p.name
            """, arguments: [assetID])
        }
    }

    public func fetchProjectIDsForAsset(assetID: String) async throws -> [String] {
        try await read { db in
            try String.fetchAll(
                db,
                sql: "SELECT project_id FROM asset_projects WHERE asset_id = ?",
                arguments: [assetID]
            )
        }
    }

    /// Replace the asset's set of projects. The first entry in `projectIDs` is the primary
    /// (also mirrored onto `assets.project_id` for the transitional query surface).
    public func setProjectsForAsset(assetID: String, projectIDs: [String]) async throws {
        let captured = projectIDs
        try await write { db in
            try db.execute(sql: "DELETE FROM asset_projects WHERE asset_id = ?", arguments: [assetID])
            for (index, pid) in captured.enumerated() {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO asset_projects (asset_id, project_id, is_primary) VALUES (?, ?, ?)",
                    arguments: [assetID, pid, index == 0]
                )
            }
            try db.execute(
                sql: "UPDATE assets SET project_id = ? WHERE id = ?",
                arguments: [captured.first, assetID]
            )
        }
    }

    public func addAssetToProject(assetID: String, projectID: String) async throws {
        try await write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO asset_projects (asset_id, project_id, is_primary) VALUES (?, ?, 0)",
                arguments: [assetID, projectID]
            )
            let hasPrimary = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM asset_projects WHERE asset_id = ? AND is_primary = 1)",
                arguments: [assetID]
            ) ?? false
            if !hasPrimary {
                try db.execute(
                    sql: "UPDATE asset_projects SET is_primary = 1 WHERE asset_id = ? AND project_id = ?",
                    arguments: [assetID, projectID]
                )
                try db.execute(
                    sql: "UPDATE assets SET project_id = ? WHERE id = ?",
                    arguments: [projectID, assetID]
                )
            }
        }
    }

    /// Bulk-add a single project to many assets in one write transaction.
    /// Uses INSERT OR IGNORE so existing memberships are preserved; promotes this project
    /// to primary only for assets that had no primary yet.
    public func bulkAddAssetsToProject(assetIDs: [String], projectID: String) async throws {
        guard !assetIDs.isEmpty else { return }
        let captured = assetIDs
        let pid = projectID
        try await write { db in
            for aid in captured {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO asset_projects (asset_id, project_id, is_primary) VALUES (?, ?, 0)",
                    arguments: [aid, pid]
                )
                let hasPrimary = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM asset_projects WHERE asset_id = ? AND is_primary = 1)",
                    arguments: [aid]
                ) ?? false
                if !hasPrimary {
                    try db.execute(
                        sql: "UPDATE asset_projects SET is_primary = 1 WHERE asset_id = ? AND project_id = ?",
                        arguments: [aid, pid]
                    )
                    try db.execute(
                        sql: "UPDATE assets SET project_id = ? WHERE id = ?",
                        arguments: [pid, aid]
                    )
                }
            }
        }
    }

    /// Bulk-attach a tag (find-or-created by name) to every asset in one write transaction.
    /// Existing tag memberships are preserved (INSERT OR IGNORE).
    public func bulkAddTagToAssets(assetIDs: [String], tagName: String) async throws {
        let trimmed = tagName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !assetIDs.isEmpty else { return }
        let captured = assetIDs
        try await write { db in
            let tag: Tag
            if let existing = try Tag.filter(Column("name") == trimmed).fetchOne(db) {
                tag = existing
            } else {
                tag = Tag(name: trimmed)
                try tag.insert(db)
            }
            for aid in captured {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO asset_tags (asset_id, tag_id) VALUES (?, ?)",
                    arguments: [aid, tag.id]
                )
            }
        }
    }

    /// Bulk-remove every tag from the given assets in one write transaction.
    public func bulkClearTagsForAssets(assetIDs: [String]) async throws {
        guard !assetIDs.isEmpty else { return }
        let captured = assetIDs
        try await write { db in
            let ph = captured.map { _ in "?" }.joined(separator: ", ")
            var args: StatementArguments = []
            for id in captured { args += [id] }
            try db.execute(sql: "DELETE FROM asset_tags WHERE asset_id IN (\(ph))", arguments: args)
        }
    }

    /// Bulk-remove every project membership from the given assets in one write transaction,
    /// and null out the transitional assets.project_id mirror.
    public func bulkClearAssetProjects(assetIDs: [String]) async throws {
        guard !assetIDs.isEmpty else { return }
        let captured = assetIDs
        try await write { db in
            let ph = captured.map { _ in "?" }.joined(separator: ", ")
            var args: StatementArguments = []
            for id in captured { args += [id] }
            try db.execute(sql: "DELETE FROM asset_projects WHERE asset_id IN (\(ph))", arguments: args)
            try db.execute(sql: "UPDATE assets SET project_id = NULL WHERE id IN (\(ph))", arguments: args)
        }
    }

    public func removeAssetFromProject(assetID: String, projectID: String) async throws {
        try await write { db in
            try db.execute(
                sql: "DELETE FROM asset_projects WHERE asset_id = ? AND project_id = ?",
                arguments: [assetID, projectID]
            )
            // If we removed the primary, promote another row if any remain.
            let nextPrimary = try String.fetchOne(
                db,
                sql: "SELECT project_id FROM asset_projects WHERE asset_id = ? ORDER BY project_id LIMIT 1",
                arguments: [assetID]
            )
            if let nextPrimary {
                try db.execute(
                    sql: "UPDATE asset_projects SET is_primary = 1 WHERE asset_id = ? AND project_id = ?",
                    arguments: [assetID, nextPrimary]
                )
            }
            try db.execute(
                sql: "UPDATE assets SET project_id = ? WHERE id = ?",
                arguments: [nextPrimary, assetID]
            )
        }
    }
}

// MARK: - Assets
extension AppDatabase {
    public func fetchAsset(id: String) async throws -> Asset? {
        try await read { db in try Asset.fetchOne(db, key: id) }
    }

    public func insertAsset(_ asset: Asset) async throws {
        try await write { db in try asset.insert(db) }
    }
}

// MARK: - References
extension AppDatabase {
    public func fetchActiveReferenceEntries(projectID: String) async throws -> [ReferenceEntry] {
        try await read { db in
            guard let set = try ReferenceSet
                .filter(Column("project_id") == projectID)
                .filter(Column("is_active") == true)
                .fetchOne(db)
            else { return [] }
            return try ReferenceEntry
                .filter(Column("reference_set_id") == set.id)
                .fetchAll(db)
        }
    }

    public func insertAssetReference(_ ref: AssetReference) async throws {
        try await write { db in try ref.insert(db) }
    }
}

// MARK: - Tags
extension AppDatabase {
    @discardableResult
    public func findOrCreateTag(name: String) async throws -> Tag {
        try await write { db in
            if let existing = try Tag.filter(Column("name") == name).fetchOne(db) {
                return existing
            }
            let tag = Tag(name: name)
            try tag.insert(db)
            return tag
        }
    }

    public func attachTag(tagID: String, assetID: String) async throws {
        try await write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO asset_tags (asset_id, tag_id) VALUES (?, ?)",
                arguments: [assetID, tagID]
            )
        }
    }
}

// MARK: - Spend
extension AppDatabase {
    public func insertSpendLog(_ log: SpendLog) async throws {
        try await write { db in try log.insert(db) }
    }

    /// A charge for an image the library refused to store. Counted in every spend total.
    public func insertRefusedSpend(id: String = UUID().uuidString, providerID: String, modelID: String?, estimatedCost: Double?, actualCost: Double?, reason: String, timestamp: String) async throws {
        try await write { db in
            try db.execute(
                sql: "INSERT INTO refused_spend (id, provider_id, model_id, estimated_cost, actual_cost, reason, timestamp) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: [id, providerID, modelID, estimatedCost, actualCost, reason, timestamp]
            )
        }
    }

    /// Say why a charge is still not an asset (its row stays one charge, counted once).
    public func updateRefusedSpendReason(id: String, reason: String) async throws {
        try await write { db in
            try db.execute(sql: "UPDATE refused_spend SET reason = ? WHERE id = ?", arguments: [reason, id])
        }
    }

    /// Keep a paid image: the asset and its `spend_log` row go in, and the generation-time
    /// `refused_spend` row ("not kept") with the same charge ID goes out, in one transaction. The charge
    /// ID is the spend row's ID, so a second call finds it and writes nothing. Returns false for that.
    @discardableResult
    public func keepCharge(chargeID: String, asset: Asset, spend: SpendLog) async throws -> Bool {
        try await write { db in
            if try SpendLog.fetchOne(db, key: chargeID) != nil { return false }
            try asset.insert(db)
            try spend.insert(db)
            try db.execute(sql: "DELETE FROM refused_spend WHERE id = ?", arguments: [chargeID])
            return true
        }
    }
}

// MARK: - Prompts
extension AppDatabase {
    public func fetchPrompts() async throws -> [Prompt] {
        try await read { db in
            try Prompt.order(Column("usage_count").desc).fetchAll(db)
        }
    }

    public func insertPrompt(_ prompt: Prompt) async throws {
        try await write { db in try prompt.insert(db) }
    }

    public func insertPromptAsset(_ pa: PromptAsset) async throws {
        try await write { db in try pa.insert(db) }
    }
}

public enum VariantFamilyError: Error, Equatable {
    case emptyName
}

// MARK: - Variants
extension AppDatabase {
    public func findOrCreateVariant(name: String, projectID: String?) async throws -> Variant {
        try await write { db in
            var query = Variant.filter(Column("name") == name)
            if let pid = projectID {
                query = query.filter(Column("project_id") == pid)
            } else {
                query = query.filter(Column("project_id") == nil)
            }
            if let existing = try query.fetchOne(db) {
                return existing
            }
            let variant = Variant(name: name, projectID: projectID, createdAt: iso8601Now())
            try variant.insert(db)
            return variant
        }
    }

    public func variantMemberCount(variantID: String) async throws -> Int {
        try await read { db in
            try VariantMember.filter(Column("variant_id") == variantID).fetchCount(db)
        }
    }

    /// Return distinct variant family names across every project (including orphan families).
    /// Used by the inspector's family picker so an asset can be moved into any family.
    public func fetchAllVariantFamilyNames() async throws -> [String] {
        try await read { db in
            let names = try Variant.select(Column("name"), as: String.self).fetchAll(db)
            var seen: Set<String> = []
            return names.filter { seen.insert($0).inserted }.sorted()
        }
    }

    /// Return distinct variant family names scoped to a project (or orphan families when nil).
    /// Used by the Generation panel's family-name picker.
    public func fetchVariantFamilyNames(projectID: String?) async throws -> [String] {
        try await read { db in
            var query = Variant.select(Column("name"), as: String.self)
            if let pid = projectID {
                query = query.filter(Column("project_id") == pid)
            } else {
                query = query.filter(Column("project_id") == nil)
            }
            let names = try query.fetchAll(db)
            var seen: Set<String> = []
            return names.filter { seen.insert($0).inserted }.sorted()
        }
    }

    public func insertVariantMember(_ member: VariantMember) async throws {
        try await write { db in try member.insert(db) }
    }

    /// Move an asset to a different variant family (or rename its family by using a new name).
    /// Detaches the asset from its current family, attaches it to the named family (creating it
    /// if needed), and deletes the old family if it becomes empty — preserving the invariant
    /// that every family has at least one member.
    @discardableResult
    public func moveAssetToVariantFamily(
        assetID: String,
        newFamilyName: String,
        projectID: String?
    ) async throws -> Variant {
        let trimmed = newFamilyName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw VariantFamilyError.emptyName
        }

        return try await write { db in
            let oldMembership = try VariantMember.filter(Column("asset_id") == assetID).fetchOne(db)
            let oldVariantID = oldMembership?.variantID

            var query = Variant.filter(Column("name") == trimmed)
            if let pid = projectID {
                query = query.filter(Column("project_id") == pid)
            } else {
                query = query.filter(Column("project_id") == nil)
            }
            let variant: Variant
            if let existing = try query.fetchOne(db) {
                variant = existing
            } else {
                let created = Variant(name: trimmed, projectID: projectID, createdAt: iso8601Now())
                try created.insert(db)
                variant = created
            }

            if oldVariantID == variant.id {
                return variant
            }

            if let member = oldMembership {
                try db.execute(sql: "DELETE FROM variant_members WHERE id = ?", arguments: [member.id])
            }

            let seq = try VariantMember.filter(Column("variant_id") == variant.id).fetchCount(db)
            let newMember = VariantMember(
                variantID: variant.id,
                assetID: assetID,
                sequence: seq + 1,
                isSelected: seq == 0
            )
            try newMember.insert(db)

            if let oldID = oldVariantID,
               try VariantMember.filter(Column("variant_id") == oldID).fetchCount(db) == 0 {
                try db.execute(sql: "DELETE FROM variants WHERE id = ?", arguments: [oldID])
            }

            return variant
        }
    }

    /// Attach an asset to a variant family. If `familyName` is nil or empty, a default name is
    /// derived from the asset's prompt (preferred) or filename. Creates a new family if needed,
    /// otherwise appends the asset to the existing family scoped to the same project.
    @discardableResult
    public func attachToVariantFamily(
        assetID: String,
        projectID: String?,
        familyName: String?,
        prompt: String?,
        filename: String
    ) async throws -> Variant {
        let trimmed = familyName?.trimmingCharacters(in: .whitespaces) ?? ""
        let resolvedName = trimmed.isEmpty
            ? defaultVariantFamilyName(prompt: prompt, filename: filename)
            : trimmed
        let variant = try await findOrCreateVariant(name: resolvedName, projectID: projectID)
        let seq = try await variantMemberCount(variantID: variant.id)
        try await insertVariantMember(
            VariantMember(variantID: variant.id, assetID: assetID, sequence: seq + 1, isSelected: seq == 0)
        )
        return variant
    }
}

// MARK: - Clients and projects by name (MCP create_client / create_project / list_projects)

/// How `file_assets` treats an asset's other projects.
public enum FilingMode: String, Sendable, CaseIterable {
    /// Keep them; add this one.
    case add
    /// Replace them all with this one, which becomes the primary.
    case move
}

/// A project as `list_projects` reports it.
public struct ProjectSummary: Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String?
    public let clientID: String?
    public let clientName: String?
    public let assetCount: Int
    /// The latest date an asset in the project was made or imported; nil for an empty project.
    public let lastUsedAt: String?
    public let createdAt: String
}

extension AppDatabase {
    /// Find a client by name in any case, or make it. Says which, so a clash is reported, not hidden.
    public func createClient(name: String) async throws -> (client: Client, created: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ClientError.nameInUse }
        return try await write { db in
            if let existing = try Self.clientNamed(trimmed, db) { return (existing, false) }
            let client = Client(name: trimmed, createdAt: iso8601Now())
            try client.insert(db)
            return (client, true)
        }
    }

    /// A client by UUID, else by name in any case.
    public func findClient(idOrName: String) async throws -> Client? {
        let trimmed = idOrName.trimmingCharacters(in: .whitespaces)
        return try await read { db in
            if let byID = try Client.fetchOne(db, key: trimmed) { return byID }
            return try Self.clientNamed(trimmed, db)
        }
    }

    /// Find a project by name in any case, or make it with this client and description. An
    /// existing project comes back as it is: a clash never changes it and never duplicates it.
    public func createProject(name: String, clientID: String?, description: String?) async throws -> (project: Project, created: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let about = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await write { db in
            if let existing = try Project
                .filter(SQL("LOWER(name) = LOWER(\(trimmed))"))
                .order(Column("created_at"), Column("id"))
                .fetchOne(db) {
                return (existing, false)
            }
            let project = Project(
                name: trimmed, clientID: clientID,
                description: (about?.isEmpty ?? true) ? nil : about, createdAt: iso8601Now())
            try project.insert(db)
            return (project, true)
        }
    }

    /// Every project with its client, how many assets it holds, and when it was last used.
    public func fetchProjectSummaries() async throws -> [ProjectSummary] {
        try await read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, p.name, p.description, p.client_id, p.created_at, c.name AS client,
                       (SELECT COUNT(*) FROM asset_projects ap WHERE ap.project_id = p.id) AS asset_count,
                       (SELECT MAX(MAX(a.created_at, COALESCE(a.imported_at, a.created_at)))
                          FROM asset_projects ap JOIN assets a ON a.id = ap.asset_id
                         WHERE ap.project_id = p.id) AS last_used_at
                FROM projects p
                LEFT JOIN clients c ON c.id = p.client_id
                ORDER BY p.name COLLATE NOCASE, p.id
                """).map { row in
                ProjectSummary(
                    id: row["id"], name: row["name"], description: row["description"],
                    clientID: row["client_id"], clientName: row["client"],
                    assetCount: row["asset_count"], lastUsedAt: row["last_used_at"], createdAt: row["created_at"])
            }
        }
    }

    /// File assets to a project in one transaction. `move` replaces each asset's projects with this
    /// one (its primary). `add` keeps them; `primary` makes this one the primary, and an asset with
    /// no primary gets this one either way. `assets.project_id` always ends equal to the primary.
    /// Returns the IDs filed and the IDs that match no asset, in the order given.
    public func fileAssets(
        assetIDs: [String], projectID: String, mode: FilingMode, primary: Bool
    ) async throws -> (filed: [String], unknown: [String]) {
        var seen: Set<String> = []
        let ids = assetIDs.filter { seen.insert($0).inserted }
        return try await write { db in
            var filed: [String] = [], unknown: [String] = []
            for id in ids {
                guard try Asset.exists(db, key: id) else { unknown.append(id); continue }
                switch mode {
                case .move:
                    try db.execute(sql: "DELETE FROM asset_projects WHERE asset_id = ?", arguments: [id])
                    try db.execute(
                        sql: "INSERT INTO asset_projects (asset_id, project_id, is_primary) VALUES (?, ?, 1)",
                        arguments: [id, projectID])
                case .add:
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO asset_projects (asset_id, project_id, is_primary) VALUES (?, ?, 0)",
                        arguments: [id, projectID])
                    let hasPrimary = try Bool.fetchOne(
                        db, sql: "SELECT EXISTS(SELECT 1 FROM asset_projects WHERE asset_id = ? AND is_primary = 1)",
                        arguments: [id]) ?? false
                    if primary || !hasPrimary {
                        try db.execute(
                            sql: "UPDATE asset_projects SET is_primary = (project_id = ?) WHERE asset_id = ?",
                            arguments: [projectID, id])
                    }
                }
                try Self.mirrorPrimaryProject(assetID: id, db)
                filed.append(id)
            }
            return (filed, unknown)
        }
    }

    /// Add projects to an asset, keeping its own; the first becomes the primary only if it has none.
    public func mergeProjects(assetID: String, projectIDs: [String]) async throws {
        guard !projectIDs.isEmpty else { return }
        let captured = projectIDs
        try await write { db in
            for pid in captured {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO asset_projects (asset_id, project_id, is_primary) VALUES (?, ?, 0)",
                    arguments: [assetID, pid])
            }
            let hasPrimary = try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM asset_projects WHERE asset_id = ? AND is_primary = 1)",
                arguments: [assetID]) ?? false
            if !hasPrimary, let first = captured.first {
                try db.execute(
                    sql: "UPDATE asset_projects SET is_primary = 1 WHERE asset_id = ? AND project_id = ?",
                    arguments: [assetID, first])
            }
            try Self.mirrorPrimaryProject(assetID: assetID, db)
        }
    }

    /// An asset's project names, primary first.
    public func fetchProjectNamesForAsset(assetID: String) async throws -> [String] {
        try await read { db in
            try String.fetchAll(db, sql: """
                SELECT p.name FROM asset_projects ap JOIN projects p ON p.id = ap.project_id
                WHERE ap.asset_id = ? ORDER BY ap.is_primary DESC, p.name COLLATE NOCASE
                """, arguments: [assetID])
        }
    }

    /// `assets.project_id` set to the asset's primary project (or NULL when it has none).
    static func mirrorPrimaryProject(assetID: String, _ db: Database) throws {
        try db.execute(sql: """
            UPDATE assets SET project_id =
                (SELECT project_id FROM asset_projects WHERE asset_id = ? AND is_primary = 1 LIMIT 1)
            WHERE id = ?
            """, arguments: [assetID, assetID])
    }

    static func clientNamed(_ name: String, _ db: Database) throws -> Client? {
        try Client
            .filter(SQL("LOWER(name) = LOWER(\(name))"))
            .order(Column("created_at"), Column("id"))
            .fetchOne(db)
    }
}

// MARK: - Tags with counts (MCP list_tags)
extension AppDatabase {
    /// Every tag and how many assets carry it, most used first.
    public func fetchTagCounts() async throws -> [(name: String, count: Int)] {
        try await read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.name, COUNT(at.asset_id) AS count
                FROM tags t LEFT JOIN asset_tags at ON at.tag_id = t.id
                GROUP BY t.id
                ORDER BY count DESC, t.name COLLATE NOCASE
                """).map { (name: $0["name"], count: $0["count"]) }
        }
    }

    public func fetchTagNamesForAsset(assetID: String) async throws -> [String] {
        try await read { db in
            try String.fetchAll(db, sql: """
                SELECT t.name FROM asset_tags at JOIN tags t ON t.id = at.tag_id
                WHERE at.asset_id = ? ORDER BY t.name COLLATE NOCASE
                """, arguments: [assetID])
        }
    }
}

// MARK: - Imported assets (MCP import_asset)
extension AppDatabase {
    /// The asset already holding these bytes, by SHA-256, if any (the oldest, should there be two).
    public func findAsset(fileHash: String) async throws -> Asset? {
        try await read { db in
            try Asset.filter(Column("file_hash") == fileHash).order(Column("created_at"), Column("id")).fetchOne(db)
        }
    }

    /// Insert an imported asset and its spend row together, unless an asset with the same hash got
    /// there first: then nothing is written and that asset's ID comes back.
    public func insertImportedAsset(_ asset: Asset, spend: SpendLog?) async throws -> String? {
        try await write { db in
            if let existing = try Asset.filter(Column("file_hash") == asset.fileHash)
                .order(Column("created_at"), Column("id")).fetchOne(db) {
                return existing.id
            }
            try asset.insert(db)
            try spend?.insert(db)
            return nil
        }
    }
}

// MARK: - Follow-up writes a second Keep can repeat
extension AppDatabase {
    /// The asset's lineage rows, written all together and only if it has none yet, so a Keep that
    /// is repeated after a failure neither loses nor doubles them.
    public func insertAssetReferencesIfNone(assetID: String, references: [AssetReference]) async throws {
        guard !references.isEmpty else { return }
        let captured = references
        try await write { db in
            let existing = try AssetReference.filter(Column("asset_id") == assetID).fetchCount(db)
            guard existing == 0 else { return }
            for ref in captured { try ref.insert(db) }
        }
    }

    /// Whether the asset is a member of any variant family yet.
    public func isInVariantFamily(assetID: String) async throws -> Bool {
        try await read { db in
            try VariantMember.filter(Column("asset_id") == assetID).fetchCount(db) > 0
        }
    }
}

// MARK: - Helpers
private func iso8601Now() -> String {
    ISO8601DateFormatter().string(from: Date())
}
