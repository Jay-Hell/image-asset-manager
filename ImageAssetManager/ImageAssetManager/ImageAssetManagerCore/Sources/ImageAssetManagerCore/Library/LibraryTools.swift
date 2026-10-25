import Foundation

/// The MCP's library tools, request to result (release 1.2 §2 items 1, 2, 3 and 5): `create_client`,
/// `create_project`, `list_projects`, `file_assets`, `import_asset` and `list_tags`. The app's HTTP
/// server only carries bytes to and from `call`, as for `GenerateTools`, so tests drive the real code.
///
/// `import_asset` never sees a path. The Node proxy reads the file (the sandboxed app cannot), checks
/// it, and sends the bytes as `data_base64` with `media_type`, `original_filename` and
/// `file_modified_at`; this side checks the bytes again before anything is stored.
public struct LibraryTools: Sendable {

    public static let toolNames: Set<String> = [
        "create_client", "create_project", "list_projects", "file_assets", "import_asset", "list_tags",
    ]

    /// The largest file `import_asset` stores, as the proxy caps it (25 MB).
    public static let maxImportBytes = 25 * 1024 * 1024

    private let database: AppDatabase
    private let libraryURL: URL
    private let now: @Sendable () -> Date
    /// The dollar-to-pound rate for `actual_cost_usd`: the one the app uses for OpenRouter's actual cost.
    private let fx: @Sendable () -> Decimal

    public init(database: AppDatabase, libraryURL: URL, now: @escaping @Sendable () -> Date = { Date() },
                fx: @escaping @Sendable () -> Decimal = { CatalogueStore.shared.snapshot().fx }) {
        self.database = database
        self.libraryURL = libraryURL
        self.now = now
        self.fx = fx
    }

    public func call(_ name: String, arguments: Data) async throws -> Data {
        let args = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        let result: Any
        switch name {
        case "create_client":  result = try await createClient(args)
        case "create_project": result = try await createProject(args)
        case "list_projects":  result = try await listProjects(args)
        case "file_assets":    result = try await fileAssets(args)
        case "import_asset":   result = try await importAsset(args)
        case "list_tags":      result = try await listTags(args)
        default:               throw MCPGenerateError.invalidParam("unknown tool '\(name)'")
        }
        return try JSONSerialization.data(withJSONObject: result)
    }

    // MARK: - tool: create_client

    private func createClient(_ args: [String: Any]) async throws -> [String: Any] {
        let name = try Self.requiredName(args["name"], field: "name")
        let (client, created) = try await database.createClient(name: name)
        return [
            "client": ["id": client.id, "name": client.name, "created_at": client.createdAt] as [String: Any],
            "created": created,
            "notes": created ? [] : ["A client named '\(client.name)' already exists; it is returned unchanged."],
        ]
    }

    // MARK: - tool: create_project

    private func createProject(_ args: [String: Any]) async throws -> [String: Any] {
        let name = try Self.requiredName(args["name"], field: "name")
        var client: Client?
        if let raw = Self.nonEmpty(args["client"]) {
            guard let found = try await database.findClient(idOrName: raw) else {
                let names = try await database.fetchClients().map(\.name)
                let list = names.isEmpty ? "there are no clients yet" : "existing clients: \(names.joined(separator: ", "))"
                throw MCPGenerateError.notFound("client '\(raw)' (\(list)). Use one of those, or create it first with create_client")
            }
            client = found
        }
        let (project, created) = try await database.createProject(
            name: name, clientID: client?.id, description: args["description"] as? String)
        var notes: [String] = []
        if !created {
            notes.append("A project named '\(project.name)' already exists; it is returned unchanged.")
        }
        let summary = try await database.fetchProjectSummaries().first { $0.id == project.id }
        return [
            "project": summary.map(Self.projectJSON) ?? ["id": project.id, "name": project.name],
            "created": created,
            "notes": notes,
        ]
    }

    // MARK: - tool: list_projects

    private func listProjects(_ args: [String: Any]) async throws -> [[String: Any]] {
        try await database.fetchProjectSummaries().map(Self.projectJSON)
    }

    // MARK: - tool: file_assets

    private func fileAssets(_ args: [String: Any]) async throws -> [String: Any] {
        guard let ids = args["asset_ids"] as? [String], !ids.isEmpty else {
            throw MCPGenerateError.invalidParam("asset_ids must be a non-empty array of asset IDs")
        }
        guard let rawProject = Self.nonEmpty(args["project"]) else {
            throw MCPGenerateError.invalidParam("project is required (a project name or UUID)")
        }
        guard let project = try await database.findProject(idOrName: rawProject) else {
            throw try await database.unknownProjectError(rawProject)
        }
        let modeName = (args["mode"] as? String)?.lowercased() ?? FilingMode.add.rawValue
        guard let mode = FilingMode(rawValue: modeName) else {
            throw MCPGenerateError.invalidParam("mode '\(modeName)' is not add or move")
        }
        let primary = (args["primary"] as? Bool) ?? false

        let (filed, unknown) = try await database.fileAssets(
            assetIDs: ids, projectID: project.id, mode: mode, primary: primary)
        var results: [[String: Any]] = []
        for id in filed {
            results.append([
                "asset_id": id,
                "status": "filed",
                "projects": try await database.fetchProjectNamesForAsset(assetID: id),
            ])
        }
        for id in unknown {
            results.append(["asset_id": id, "status": "unknown", "error": "Not found: asset '\(id)'"])
        }
        if !filed.isEmpty { try await exportIndex() }
        var notes: [String] = []
        if !unknown.isEmpty { notes.append("\(unknown.count) of the IDs given match no asset and were not filed.") }
        if mode == .move { notes.append("move replaces each asset's projects, so '\(project.name)' is now its primary.") }
        return [
            "project": ["id": project.id, "name": project.name] as [String: Any],
            "mode": mode.rawValue,
            "primary": mode == .move || primary,
            "filed": filed.count,
            "unknown": unknown,
            "results": results,
            "notes": notes,
        ]
    }

    // MARK: - tool: import_asset

    private func importAsset(_ args: [String: Any]) async throws -> [String: Any] {
        // --- 1. The bytes, as the proxy read them -------------------------------------
        guard let encoded = args["data_base64"] as? String, let data = Data(base64Encoded: encoded) else {
            throw MCPGenerateError.invalidParam("data_base64 is missing or not base64 (the proxy reads the file and sends it)")
        }
        guard !data.isEmpty else { throw MCPGenerateError.invalidParam("the file is empty") }
        guard data.count <= Self.maxImportBytes else {
            throw MCPGenerateError.invalidParam("the file is \(data.count) bytes, over the \(Self.maxImportBytes)-byte import limit")
        }
        guard let mimeType = Self.nonEmpty(args["media_type"]) else {
            throw MCPGenerateError.invalidParam("media_type is required")
        }
        let originalName = Self.nonEmpty(args["original_filename"])

        // --- 2. Everything else is checked before anything is written ---------------------
        let importedAt = Self.iso(now())
        let createdAt: String
        if let raw = Self.nonEmpty(args["created_at"]) {
            guard let date = Self.parseDate(raw) else {
                throw MCPGenerateError.invalidParam("created_at '\(raw)' is not an ISO 8601 date")
            }
            createdAt = Self.iso(date)
        } else if let raw = Self.nonEmpty(args["file_modified_at"]), let date = Self.parseDate(raw) {
            createdAt = Self.iso(date)
        } else {
            createdAt = importedAt
        }
        var cost: Double?
        if let rawCost = args["actual_cost_gbp"], !(rawCost is NSNull) {
            guard let number = rawCost as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw MCPGenerateError.invalidParam("actual_cost_gbp must be a number of pounds, zero or more")
            }
            cost = number.doubleValue
        }
        if let rawUSD = args["actual_cost_usd"], !(rawUSD is NSNull) {
            guard cost == nil else {
                throw MCPGenerateError.invalidParam("give actual_cost_gbp or actual_cost_usd, not both")
            }
            guard let number = rawUSD as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw MCPGenerateError.invalidParam("actual_cost_usd must be a number of dollars, zero or more")
            }
            cost = NSDecimalNumber(decimal: Catalogue.decimal(number.doubleValue) * fx()).doubleValue
        }
        var projects: [Project] = []
        var rawProjects: [String] = []
        if let one = Self.nonEmpty(args["project"]) { rawProjects.append(one) }
        rawProjects += ((args["projects"] as? [String]) ?? []).filter { !$0.isEmpty }
        for raw in rawProjects {
            guard let project = try await database.findProject(idOrName: raw) else {
                throw try await database.unknownProjectError(raw)
            }
            if !projects.contains(where: { $0.id == project.id }) { projects.append(project) }
        }
        let tags = ((args["tags"] as? [String]) ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let prompt = Self.nonEmpty(args["prompt"])
        let provider = Self.nonEmpty(args["provider"]) ?? "imported"
        let model = Self.nonEmpty(args["model"]) ?? "imported"
        let family = Self.nonEmpty(args["variant_family"])

        // --- 3. A duplicate is not stored again: its projects and tags are merged ----------
        let hash = data.sha256
        if let existing = try await database.findAsset(fileHash: hash) {
            return try await mergeDuplicate(existing, projects: projects, tags: tags,
                                            family: family, filename: originalName, notes: [])
        }

        // --- 4. Stored by what the bytes are (pass C), then the rows ---------------------
        let stored: StoredAssetFile
        do {
            stored = try AssetStore.store(data, mimeType: mimeType, libraryURL: libraryURL)
        } catch let refusal as AssetStoreError {
            throw MCPGenerateError.invalidParam(refusal.localizedDescription)
        }
        let asset = Asset(
            id: stored.assetID, filename: stored.filename, fileHash: stored.fileHash,
            projectID: projects.first?.id, providerID: provider, modelID: model, prompt: prompt,
            width: stored.width, height: stored.height,
            estimatedCost: cost, actualCost: cost,
            createdAt: createdAt, importedAt: importedAt, mediaType: stored.mediaType.rawValue)
        // A known cost is spend made outside the app (Q2): marked external, dated when it was made.
        // An unknown one is no spend row at all, and NULL on the asset, never £0.
        let spend = cost.map {
            SpendLog(assetID: stored.assetID, providerID: provider, estimatedCost: $0, actualCost: $0,
                     timestamp: createdAt, source: SpendLog.externalSource)
        }
        let raced: String?
        do {
            raced = try await database.insertImportedAsset(asset, spend: spend)
        } catch {
            try? FileManager.default.removeItem(at: stored.fileURL)
            throw error
        }
        if let raced, let existing = try await database.fetchAsset(id: raced) {
            // The same bytes arrived by another call between the check and the insert.
            try? FileManager.default.removeItem(at: stored.fileURL)
            return try await mergeDuplicate(existing, projects: projects, tags: tags,
                                            family: family, filename: originalName, notes: [])
        }

        if !projects.isEmpty {
            try await database.setProjectsForAsset(assetID: asset.id, projectIDs: projects.map(\.id))
        }
        for name in tags {
            let tag = try await database.findOrCreateTag(name: name)
            try await database.attachTag(tagID: tag.id, assetID: asset.id)
        }
        try await database.attachToVariantFamily(
            assetID: asset.id, projectID: projects.first?.id, familyName: family, prompt: prompt,
            filename: originalName ?? stored.filename)
        try await exportIndex()

        var notes: [String] = []
        if cost == nil { notes.append("No cost given: recorded as unknown, not as £0, and not counted in spend.") }
        return try await response(for: asset.id, duplicate: false, spendRecorded: spend != nil, notes: notes)
    }

    private func mergeDuplicate(
        _ existing: Asset, projects: [Project], tags: [String], family: String?, filename: String?, notes: [String]
    ) async throws -> [String: Any] {
        try await database.mergeProjects(assetID: existing.id, projectIDs: projects.map(\.id))
        for name in tags {
            let tag = try await database.findOrCreateTag(name: name)
            try await database.attachTag(tagID: tag.id, assetID: existing.id)
        }
        // A retry after the first import's follow-up writes failed: the asset was stored but never
        // joined a family. Attach it now, as Keep does, so every asset has one.
        if try await !database.isInVariantFamily(assetID: existing.id) {
            let primary = try await database.fetchAsset(id: existing.id)?.projectID
            try await database.attachToVariantFamily(
                assetID: existing.id, projectID: primary, familyName: family, prompt: existing.prompt,
                filename: filename ?? existing.filename)
        }
        try await exportIndex()
        let note = "These bytes are already in the library (same SHA-256): nothing was stored again, no spend was recorded, and the projects and tags given were added to the existing asset."
        return try await response(for: existing.id, duplicate: true, spendRecorded: false, notes: notes + [note])
    }

    private func response(for assetID: String, duplicate: Bool, spendRecorded: Bool, notes: [String]) async throws -> [String: Any] {
        guard let asset = try await database.fetchAsset(id: assetID) else {
            throw MCPGenerateError.notFound("asset '\(assetID)'")
        }
        return [
            "asset_id": asset.id,
            "duplicate": duplicate,
            "file_path": libraryURL.appending(path: "assets").appending(path: asset.filename).path(percentEncoded: false),
            "media_type": asset.effectiveMediaType?.rawValue as Any? ?? NSNull(),
            "created_at": asset.createdAt,
            "imported_at": asset.importedAt as Any? ?? NSNull(),
            "actual_cost_gbp": asset.actualCost as Any? ?? NSNull(),
            "spend_recorded": spendRecorded,
            "projects": try await database.fetchProjectNamesForAsset(assetID: asset.id),
            "tags": try await database.fetchTagNamesForAsset(assetID: asset.id),
            "notes": notes,
        ]
    }

    // MARK: - tool: list_tags

    private func listTags(_ args: [String: Any]) async throws -> [String: Any] {
        let tags = try await database.fetchTagCounts()
        return [
            "tags": tags.map { ["name": $0.name, "count": $0.count] as [String: Any] },
            "notes": ["Reuse these tags where they fit rather than making near-duplicates."],
        ]
    }

    // MARK: - Helpers

    private func exportIndex() async throws {
        try await IndexExporter.export(
            from: database, to: libraryURL.appending(path: "index.json"),
            assetsBaseURL: libraryURL.appending(path: "assets"))
    }

    private static func projectJSON(_ p: ProjectSummary) -> [String: Any] {
        let client: Any = p.clientID.map { ["id": $0, "name": p.clientName ?? ""] as [String: Any] } ?? NSNull()
        return [
            "id": p.id,
            "name": p.name,
            "description": p.description as Any? ?? NSNull(),
            "client": client,
            "asset_count": p.assetCount,
            "last_used_at": p.lastUsedAt as Any? ?? NSNull(),
            "created_at": p.createdAt,
        ]
    }

    private static func requiredName(_ any: Any?, field: String) throws -> String {
        guard let name = nonEmpty(any) else { throw MCPGenerateError.invalidParam("\(field) is required") }
        guard name.count <= 120 else { throw MCPGenerateError.invalidParam("\(field) is over 120 characters") }
        return name
    }

    private static func nonEmpty(_ any: Any?) -> String? {
        guard let text = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// ISO 8601 with or without fractional seconds, or a bare date.
    static func parseDate(_ raw: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: raw) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: raw)
    }

    /// The form every other date in the library takes.
    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
