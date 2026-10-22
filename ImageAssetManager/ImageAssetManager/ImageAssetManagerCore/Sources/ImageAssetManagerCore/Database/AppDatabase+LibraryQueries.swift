import GRDB
import Foundation

// MARK: - Asset search
extension AppDatabase {
    /// Filter assets by any combination of projects (union), tag, variant family, and
    /// full-text search. `projectIDs == nil` means "no project filter"; an empty array
    /// filters to assets with zero project memberships.
    public func searchAssets(
        projectIDs: [String]? = nil,
        tagID: String? = nil,
        variantFamilyID: String? = nil,
        searchText: String? = nil,
        showHidden: Bool = false
    ) async throws -> [Asset] {
        try await read { db in
            var request = Asset.order(Column("created_at").desc)
            if !showHidden {
                request = request.filter(Column("is_hidden") == false)
            }
            if let pids = projectIDs {
                if pids.isEmpty {
                    request = request.filter(SQL("id NOT IN (SELECT asset_id FROM asset_projects)"))
                } else {
                    request = request.filter(SQL("id IN (SELECT asset_id FROM asset_projects WHERE project_id IN \(pids))"))
                }
            }
            if let tid = tagID {
                request = request.filter(SQL("id IN (SELECT asset_id FROM asset_tags WHERE tag_id = \(tid))"))
            }
            if let vid = variantFamilyID {
                request = request.filter(SQL("id IN (SELECT asset_id FROM variant_members WHERE variant_id = \(vid))"))
            }
            if let text = searchText, !text.isEmpty {
                let pattern = "%\(text)%"
                request = request.filter(SQL("prompt LIKE \(pattern) OR filename LIKE \(pattern)"))
            }
            return try request.fetchAll(db)
        }
    }

    public func fetchTagsWithCounts() async throws -> [(Tag, Int)] {
        try await read { db in
            let tags = try Tag.order(Column("name")).fetchAll(db)
            return try tags.map { tag in
                let count = try AssetTag.filter(Column("tag_id") == tag.id).fetchCount(db)
                return (tag, count)
            }
        }
    }

    /// Returns variant families with **more than one member**. Singleton families (one asset)
    /// exist as structural bookkeeping so every asset belongs to a family, but they add noise
    /// to the filmstrip and sidebar — callers only care about genuine groupings.
    public func fetchVariantFamilies(projectID: String? = nil) async throws -> [(Variant, [(VariantMember, Asset)])] {
        try await read { db in
            var variantReq = Variant.order(Column("created_at").desc)
            if let pid = projectID {
                variantReq = variantReq.filter(Column("project_id") == pid)
            }
            let variants = try variantReq.fetchAll(db)
            return try variants.compactMap { variant in
                let members = try VariantMember
                    .filter(Column("variant_id") == variant.id)
                    .order(Column("sequence"))
                    .fetchAll(db)
                guard members.count > 1 else { return nil }
                let pairs: [(VariantMember, Asset)] = try members.compactMap { member in
                    guard let asset = try Asset.fetchOne(db, key: member.assetID) else { return nil }
                    return (member, asset)
                }
                return pairs.count > 1 ? (variant, pairs) : nil
            }
        }
    }

    /// Asset IDs that belong to a variant family with **more than one member**.
    /// These are the assets the grid hands off to the filmstrip row; they should be
    /// excluded from the plain "standalone" grid. Singleton families (every asset has
    /// one of these after the v4 backfill) are ignored here by design.
    public func fetchVariantMemberAssetIDs() async throws -> Set<String> {
        try await read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT asset_id FROM variant_members
                WHERE variant_id IN (
                    SELECT variant_id FROM variant_members
                    GROUP BY variant_id
                    HAVING COUNT(*) > 1
                )
            """)
            return Set(rows.map { $0["asset_id"] as String })
        }
    }
}

// MARK: - Asset detail
extension AppDatabase {
    public func fetchTagsForAsset(assetID: String) async throws -> [Tag] {
        try await read { db in
            try Tag
                .filter(SQL("id IN (SELECT tag_id FROM asset_tags WHERE asset_id = \(assetID))"))
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    public func fetchReferencesForAsset(assetID: String) async throws -> [(AssetReference, Asset?)] {
        try await read { db in
            let refs = try AssetReference.filter(Column("asset_id") == assetID).fetchAll(db)
            return try refs.map { ref in
                var refAsset: Asset?
                if let entryID = ref.referenceEntryID,
                   let entry = try ReferenceEntry.fetchOne(db, key: entryID) {
                    refAsset = try Asset.fetchOne(db, key: entry.assetID)
                }
                return (ref, refAsset)
            }
        }
    }

    public func fetchVariantContext(assetID: String) async throws -> (Variant, [(VariantMember, Asset)])? {
        try await read { db in
            guard let membership = try VariantMember.filter(Column("asset_id") == assetID).fetchOne(db),
                  let variant = try Variant.fetchOne(db, key: membership.variantID)
            else { return nil }

            let members = try VariantMember
                .filter(Column("variant_id") == variant.id)
                .order(Column("sequence"))
                .fetchAll(db)
            let pairs: [(VariantMember, Asset)] = try members.compactMap { m in
                guard let a = try Asset.fetchOne(db, key: m.assetID) else { return nil }
                return (m, a)
            }
            return (variant, pairs)
        }
    }

    public func fetchUsageForAsset(assetID: String) async throws -> [AssetUsage] {
        try await read { db in
            try AssetUsage.filter(Column("asset_id") == assetID).fetchAll(db)
        }
    }
}

// MARK: - Mutations
extension AppDatabase {
    public func promoteVariantMember(memberID: String, in variantID: String) async throws {
        try await write { db in
            try db.execute(
                sql: "UPDATE variant_members SET is_selected = 0 WHERE variant_id = ?",
                arguments: [variantID]
            )
            try db.execute(
                sql: "UPDATE variant_members SET is_selected = 1 WHERE id = ?",
                arguments: [memberID]
            )
        }
    }

    public func markAssetUsed(assetID: String, usedIn: String) async throws {
        let usage = AssetUsage(
            assetID: assetID,
            usedIn: usedIn,
            usedAt: ISO8601DateFormatter().string(from: Date()),
            notedBy: "manual"
        )
        try await write { db in try usage.insert(db) }
    }

    public func setTagsForAsset(assetID: String, tagNames: [String]) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM asset_tags WHERE asset_id = ?", arguments: [assetID])
            for name in tagNames.map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
                let tag: Tag
                if let existing = try Tag.filter(Column("name") == name).fetchOne(db) {
                    tag = existing
                } else {
                    tag = Tag(name: name)
                    try tag.insert(db)
                }
                try db.execute(
                    sql: "INSERT OR IGNORE INTO asset_tags (asset_id, tag_id) VALUES (?, ?)",
                    arguments: [assetID, tag.id]
                )
            }
        }
    }

    public func deleteAsset(id: String) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM assets WHERE id = ?", arguments: [id])
        }
    }

    public func setHidden(assetIDs: [String], hidden: Bool) async throws {
        guard !assetIDs.isEmpty else { return }
        let capturedIDs = assetIDs
        let capturedHidden = hidden
        try await write { db in
            for id in capturedIDs {
                try db.execute(
                    sql: "UPDATE assets SET is_hidden = ? WHERE id = ?",
                    arguments: [capturedHidden, id]
                )
            }
        }
    }

    public func deleteAssets(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let capturedIDs = ids
        try await write { db in
            for id in capturedIDs {
                try db.execute(sql: "DELETE FROM assets WHERE id = ?", arguments: [id])
            }
        }
    }
}
