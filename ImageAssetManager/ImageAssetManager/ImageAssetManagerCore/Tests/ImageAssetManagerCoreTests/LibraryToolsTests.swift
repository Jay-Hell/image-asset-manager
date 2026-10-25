import Testing
import Foundation
import GRDB
@testable import ImageAssetManagerCore

// Release 1.2 pass A: the library tools over MCP, driven through `LibraryTools.call` (the call site
// the app's server uses). Assertions are on the JSON returned and on the rows written.

/// The fixed "now" of every import here: 2026-10-25T08:00:00Z. Worked by hand: 2026-01-01 is
/// 1,767,225,600; to 25 October is 297 days (25,660,800 s); plus 8 hours (28,800 s).
private let importTime = Date(timeIntervalSince1970: 1_792_915_200)

private struct LibraryRig {
    let db: AppDatabase
    let dir: URL
    let tools: LibraryTools

    init(fx: Decimal = 0.79) throws {
        db = try AppDatabase(path: ":memory:")
        dir = makeTempDirectory()
        tools = LibraryTools(database: db, libraryURL: dir, now: { importTime }, fx: { fx })
    }

    func call(_ name: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let result = try await tools.call(name, arguments: try JSONSerialization.data(withJSONObject: arguments))
        return try #require(try JSONSerialization.jsonObject(with: result) as? [String: Any])
    }

    func callList(_ name: String) async throws -> [[String: Any]] {
        let result = try await tools.call(name, arguments: Data("{}".utf8))
        return try #require(try JSONSerialization.jsonObject(with: result) as? [[String: Any]])
    }

    /// The error a call is refused with; records an issue if it is not refused.
    func refusal(_ name: String, _ arguments: [String: Any]) async -> String {
        do {
            _ = try await call(name, arguments)
            Issue.record("\(name) should have been refused")
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    func count(_ sql: String) async throws -> Int {
        try await db.read { db in try Int.fetchOne(db, sql: sql) ?? -1 }
    }

    func assetFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "assets").path(percentEncoded: false))) ?? []).sorted()
    }

    /// (project name, is_primary) for an asset, by name, and its `assets.project_id`'s name.
    func links(_ assetID: String) async throws -> (rows: [String], mirror: String?) {
        try await db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.name, ap.is_primary FROM asset_projects ap JOIN projects p ON p.id = ap.project_id
                WHERE ap.asset_id = ? ORDER BY p.name
                """, arguments: [assetID]).map { row -> String in
                let name: String = row["name"]
                let primary: Bool = row["is_primary"]
                return primary ? "\(name)*" : name
            }
            let mirror = try String.fetchOne(db, sql: """
                SELECT p.name FROM assets a JOIN projects p ON p.id = a.project_id WHERE a.id = ?
                """, arguments: [assetID])
            return (rows, mirror)
        }
    }

    /// An asset row, written directly, for the filing and listing tests.
    func insertAsset(_ id: String, createdAt: String = "2026-10-01T09:00:00Z", importedAt: String? = nil) async throws {
        try await db.insertAsset(Asset(
            id: id, filename: "\(id).png", fileHash: "hash-\(id)", providerID: "nano_banana", modelID: "m",
            createdAt: createdAt, importedAt: importedAt))
    }

    func projectID(_ name: String) async throws -> String {
        try #require(try await db.findProject(idOrName: name)).id
    }
}

private func dict(_ any: Any?) -> [String: Any] { (any as? [String: Any]) ?? [:] }

/// A PNG signature and then `tail`, so each image has its own SHA-256.
private func png(_ tail: [UInt8] = [1, 2, 3]) -> Data {
    Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + tail)
}

// MARK: - Clients and projects

@Suite("create_client, create_project, list_projects")
struct ProjectToolTests {

    @Test func aClientNamedTwiceInAnyCaseIsOneClientAndTheClashSaysSo() async throws {
        let rig = try LibraryRig()
        let first = try await rig.call("create_client", ["name": "TfWM"])
        let again = try await rig.call("create_client", ["name": "  tfwm "])
        #expect(first["created"] as? Bool == true)
        #expect(again["created"] as? Bool == false)
        #expect(dict(again["client"])["id"] as? String == dict(first["client"])["id"] as? String)
        #expect(dict(again["client"])["name"] as? String == "TfWM")
        #expect(try await rig.count("SELECT COUNT(*) FROM clients") == 1)
        // The pair: a different name is a second client.
        let other = try await rig.call("create_client", ["name": "Ionic"])
        #expect(other["created"] as? Bool == true)
        #expect(try await rig.count("SELECT COUNT(*) FROM clients") == 2)
    }

    @Test func aProjectNameClashReturnsTheExistingProjectUnchangedAndWritesNoSecond() async throws {
        let rig = try LibraryRig()
        _ = try await rig.call("create_client", ["name": "Ionic"])
        let first = try await rig.call("create_project", ["name": "Labs", "client": "ionic", "description": "Ionic Labs pages"])
        let clash = try await rig.call("create_project", ["name": "LABS", "description": "something else"])
        #expect(first["created"] as? Bool == true)
        #expect(clash["created"] as? Bool == false)
        let project = dict(clash["project"])
        #expect(project["id"] as? String == dict(first["project"])["id"] as? String)
        #expect(project["name"] as? String == "Labs")
        #expect(project["description"] as? String == "Ionic Labs pages")
        #expect(dict(project["client"])["name"] as? String == "Ionic")
        #expect(try await rig.count("SELECT COUNT(*) FROM projects") == 1)
        // The pair: another name is another project.
        let second = try await rig.call("create_project", ["name": "Labs hero"])
        #expect(second["created"] as? Bool == true)
        #expect(try await rig.count("SELECT COUNT(*) FROM projects") == 2)
    }

    /// Settings renames through `renameProject`: it must not make "labs" beside "Labs" either.
    @Test func renamingAProjectToAnotherProjectsNameInAnyCaseIsRefusedAndChangesNothing() async throws {
        let rig = try LibraryRig()
        let labs = try await rig.db.createProject(name: "Labs", clientID: nil, description: nil).project
        let hero = try await rig.db.createProject(name: "Hero", clientID: nil, description: nil).project
        await #expect(throws: ProjectError.nameInUse) {
            try await rig.db.renameProject(id: hero.id, newName: " labs ")
        }
        #expect(try await rig.db.fetchProjects().map(\.name).sorted() == ["Hero", "Labs"])
        // The pair: a project may change the case of its own name, or take a name no other has.
        try await rig.db.renameProject(id: labs.id, newName: "LABS")
        try await rig.db.renameProject(id: hero.id, newName: "Hero images")
        #expect(try await rig.db.fetchProjects().map(\.name).sorted() == ["Hero images", "LABS"])
    }

    @Test func anUnknownClientIsRefusedWithTheClientsThereAreAndNoProjectIsWritten() async throws {
        let rig = try LibraryRig()
        _ = try await rig.call("create_client", ["name": "Ionic"])
        let message = await rig.refusal("create_project", ["name": "Labs", "client": "Ionik"])
        #expect(message.contains("client 'Ionik'"))
        #expect(message.contains("existing clients: Ionic"))
        #expect(message.contains("create_client"))
        #expect(try await rig.count("SELECT COUNT(*) FROM projects") == 0)
        #expect(try await rig.count("SELECT COUNT(*) FROM clients") == 1)
    }

    @Test func listProjectsGivesEachProjectsClientAssetCountAndLastUsedDate() async throws {
        let rig = try LibraryRig()
        _ = try await rig.call("create_client", ["name": "TfWM"])
        _ = try await rig.call("create_project", ["name": "ELEMENTS", "client": "TfWM"])
        _ = try await rig.call("create_project", ["name": "Home improvement"])
        try await rig.insertAsset("a1", createdAt: "2026-09-24T10:00:00Z")
        // Made in August, imported in October: last used is the import.
        try await rig.insertAsset("a2", createdAt: "2026-08-06T10:00:00Z", importedAt: "2026-10-20T10:00:00Z")
        try await rig.insertAsset("a3", createdAt: "2026-10-23T10:00:00Z")
        let elements = try await rig.projectID("ELEMENTS")
        _ = try await rig.db.fileAssets(assetIDs: ["a1", "a2"], projectID: elements, mode: .add, primary: false)

        let projects = try await rig.callList("list_projects")
        #expect(projects.map { $0["name"] as? String } == ["ELEMENTS", "Home improvement"])
        let first = projects[0], second = projects[1]
        #expect(dict(first["client"])["name"] as? String == "TfWM")
        #expect(first["asset_count"] as? Int == 2)
        #expect(first["last_used_at"] as? String == "2026-10-20T10:00:00Z")
        #expect(second["client"] is NSNull)
        #expect(second["asset_count"] as? Int == 0)
        #expect(second["last_used_at"] is NSNull)
    }

    @Test func generateRefusesAnUnknownProjectListingTheProjectsAndSendsNothing() async throws {
        let rig = try await ToolsRig.make()
        _ = try await rig.db.createProject(name: "Labs", clientID: nil, description: nil)
        _ = try await rig.db.createProject(name: "ELEMENTS", clientID: nil, description: nil)
        do {
            _ = try await rig.call("generate", ["prompt": "p", "quality": "standard", "project": "Lab"])
            Issue.record("an unknown project should be refused")
        } catch {
            #expect(error.localizedDescription.contains("project 'Lab'"))
            #expect(error.localizedDescription.contains("existing projects: ELEMENTS, Labs"))
            #expect(error.localizedDescription.contains("create_project"))
        }
        #expect(rig.google.requests.isEmpty && rig.openRouter.requests.isEmpty)
        // The pair: the same name in another case is the project, and the image is filed to it.
        let result = try await rig.call("generate", ["prompt": "p", "quality": "standard", "project": "labs"])
        let id = try #require((result["generated"] as? [[String: Any]])?.first?["asset_id"] as? String)
        #expect(try await rig.db.fetchProjectNamesForAsset(assetID: id) == ["Labs"])
    }
}

// MARK: - file_assets

@Suite("file_assets")
struct FileAssetsToolTests {

    /// a1 in P1 (primary) and P2; P3 exists and holds nothing.
    private func filedRig() async throws -> LibraryRig {
        let rig = try LibraryRig()
        for name in ["P1", "P2", "P3"] { _ = try await rig.call("create_project", ["name": name]) }
        try await rig.insertAsset("a1")
        try await rig.db.setProjectsForAsset(assetID: "a1", projectIDs: [try await rig.projectID("P1"), try await rig.projectID("P2")])
        return rig
    }

    @Test func moveReplacesEveryProjectAndTheNewOneIsThePrimaryOnBothSides() async throws {
        let rig = try await filedRig()
        let result = try await rig.call("file_assets", ["asset_ids": ["a1"], "project": "P3", "mode": "move"])
        #expect(result["filed"] as? Int == 1)
        let links = try await rig.links("a1")
        #expect(links.rows == ["P3*"])
        #expect(links.mirror == "P3")
        #expect(dict((result["results"] as? [Any])?.first)["projects"] as? [String] == ["P3"])
    }

    @Test func addKeepsTheOtherProjectsAndThePrimary() async throws {
        let rig = try await filedRig()
        _ = try await rig.call("file_assets", ["asset_ids": ["a1"], "project": "P3"])
        let links = try await rig.links("a1")
        #expect(links.rows == ["P1*", "P2", "P3"])
        #expect(links.mirror == "P1")
    }

    @Test func addWithPrimaryMovesThePrimaryAndTheMirrorFollows() async throws {
        let rig = try await filedRig()
        _ = try await rig.call("file_assets", ["asset_ids": ["a1"], "project": "P3", "mode": "add", "primary": true])
        let links = try await rig.links("a1")
        #expect(links.rows == ["P1", "P2", "P3*"])
        #expect(links.mirror == "P3")
    }

    @Test func anUnknownIDIsReportedForThatIDAndTheRestAreFiled() async throws {
        let rig = try await filedRig()
        try await rig.insertAsset("a2")
        let result = try await rig.call("file_assets", ["asset_ids": ["a1", "no-such-asset", "a2"], "project": "P3"])
        #expect(result["filed"] as? Int == 2)
        #expect(result["unknown"] as? [String] == ["no-such-asset"])
        let statuses = ((result["results"] as? [[String: Any]]) ?? []).map { "\($0["asset_id"] ?? ""):\($0["status"] ?? "")" }
        #expect(statuses == ["a1:filed", "a2:filed", "no-such-asset:unknown"])
        #expect(try await rig.count("SELECT COUNT(*) FROM asset_projects WHERE asset_id = 'no-such-asset'") == 0)
        #expect(try await rig.links("a2").rows == ["P3*"])     // an asset with no primary gets this one
        // Every ID unknown is still an answer that names them, not a silent nothing.
        let none = try await rig.call("file_assets", ["asset_ids": ["x", "y"], "project": "P3"])
        #expect(none["filed"] as? Int == 0)
        #expect(none["unknown"] as? [String] == ["x", "y"])
    }

    @Test func anUnknownProjectIsRefusedWithTheListAndNothingChanges() async throws {
        let rig = try await filedRig()
        let message = await rig.refusal("file_assets", ["asset_ids": ["a1"], "project": "P4", "mode": "move"])
        #expect(message.contains("existing projects: P1, P2, P3"))
        #expect(try await rig.links("a1").rows == ["P1*", "P2"])
    }

    /// The name of the project an asset's family is filed under, or nil for none.
    private func familyProject(_ rig: LibraryRig, of assetID: String) async throws -> String? {
        try await rig.db.read { db in
            try String.fetchOne(db, sql: """
                SELECT p.name FROM variant_members m JOIN variants v ON v.id = m.variant_id
                JOIN projects p ON p.id = v.project_id WHERE m.asset_id = ?
                """, arguments: [assetID])
        }
    }

    /// The rule: a family is filed under a project only while every member's primary is that project.
    /// When its members' primaries differ (or one has none), the family is filed under no project:
    /// shown in the unfiltered library, under neither project.
    @Test func aFamilyFollowsItsAssetsWhenEveryMemberSharesThePrimaryAndIsUnfiledWhenTheyDiffer() async throws {
        let rig = try LibraryRig()
        for name in ["P1", "P3"] { _ = try await rig.call("create_project", ["name": name]) }
        let p1 = try await rig.projectID("P1"), p3 = try await rig.projectID("P3")
        let a = try #require(try await rig.call("import_asset", [
            "data_base64": png([1]).base64EncodedString(), "media_type": "image/png", "original_filename": "a.png",
            "variant_family": "Heroes", "project": "P1"])["asset_id"] as? String)
        let b = try #require(try await rig.call("import_asset", [
            "data_base64": png([2]).base64EncodedString(), "media_type": "image/png", "original_filename": "b.png",
            "variant_family": "Heroes", "project": "P1"])["asset_id"] as? String)
        #expect(try await rig.db.fetchVariantFamilies(projectID: p1).count == 1)

        // Both moved: the family goes with them.
        _ = try await rig.call("file_assets", ["asset_ids": [a, b], "project": "P3", "mode": "move"])
        #expect(try await rig.db.fetchVariantFamilies(projectID: p3).count == 1)
        #expect(try await rig.db.fetchVariantFamilies(projectID: p1).isEmpty)
        #expect(try await familyProject(rig, of: a) == "P3")
        // A later generate there with the same family name joins it rather than starting a second.
        let family = try await rig.db.findOrCreateVariant(name: "Heroes", projectID: p3)
        #expect(try await rig.count("SELECT COUNT(*) FROM variants") == 1)
        #expect(try await rig.db.variantMemberCount(variantID: family.id) == 2)

        // One moved back: the members disagree, so the family is under neither project.
        _ = try await rig.call("file_assets", ["asset_ids": [a], "project": "P1", "mode": "move"])
        #expect(try await familyProject(rig, of: a) == nil)
        #expect(try await rig.db.fetchVariantFamilies(projectID: p1).isEmpty)
        #expect(try await rig.db.fetchVariantFamilies(projectID: p3).isEmpty)
        #expect(try await rig.db.fetchVariantFamilies().count == 1)

        // `add` without `primary` leaves every primary, so the family stays as it is.
        _ = try await rig.call("file_assets", ["asset_ids": [b], "project": "P1"])
        #expect(try await familyProject(rig, of: b) == nil)
        // `add` with `primary` makes them agree again: the family follows.
        _ = try await rig.call("file_assets", ["asset_ids": [b], "project": "P1", "primary": true])
        #expect(try await familyProject(rig, of: b) == "P1")
        #expect(try await rig.db.fetchVariantFamilies(projectID: p1).count == 1)
    }
}

// MARK: - import_asset

@Suite("import_asset")
struct ImportAssetToolTests {

    private func args(_ data: Data, _ extra: [String: Any] = [:]) -> [String: Any] {
        var args: [String: Any] = [
            "data_base64": data.base64EncodedString(),
            "media_type": "image/png",
            "original_filename": "labs-hero.png",
            "file_modified_at": "2026-10-23T18:40:12.345Z",
        ]
        for (key, value) in extra { args[key] = value }
        return args
    }

    @Test func anImportStoresTheBytesWithItsLineageAndAKnownCostAsExternalSpend() async throws {
        let rig = try LibraryRig()
        _ = try await rig.call("create_project", ["name": "Labs"])
        let bytes = png([9, 9, 9])
        let result = try await rig.call("import_asset", args(bytes, [
            "prompt": "a glass lab at dusk", "provider": "openrouter", "model": "vendor/some-model",
            "actual_cost_gbp": 0.04, "project": "Labs", "tags": ["hero"], "variant_family": "Labs heroes",
        ]))
        let id = try #require(result["asset_id"] as? String)
        #expect(result["duplicate"] as? Bool == false)
        #expect(result["media_type"] as? String == "image/png")
        #expect(result["projects"] as? [String] == ["Labs"])
        #expect(result["tags"] as? [String] == ["hero"])
        #expect(result["spend_recorded"] as? Bool == true)

        let asset = try #require(try await rig.db.fetchAsset(id: id))
        #expect(asset.mediaType == "image/png")
        #expect(asset.fileHash == bytes.sha256)
        #expect(asset.prompt == "a glass lab at dusk")
        #expect(asset.providerID == "openrouter")
        #expect(asset.modelID == "vendor/some-model")
        #expect(asset.actualCost == 0.04)
        // Q3: made when the file was last written (to the second); imported now.
        #expect(asset.createdAt == "2026-10-23T18:40:12Z")
        #expect(asset.importedAt == "2026-10-25T08:00:00Z")
        #expect(try Data(contentsOf: rig.dir.appending(path: "assets").appending(path: asset.filename)) == bytes)
        #expect(try await rig.links(id).rows == ["Labs*"])
        let family = try await rig.db.read { db in
            try String.fetchOne(db, sql: "SELECT v.name FROM variant_members m JOIN variants v ON v.id = m.variant_id WHERE m.asset_id = ?", arguments: [id])
        }
        #expect(family == "Labs heroes")
        // Q2: one spend row, marked external, at the cost given, dated when the image was made.
        let spend = try await rig.db.read { db in try SpendLog.fetchAll(db) }
        #expect(spend.count == 1)
        #expect(spend.first?.assetID == id)
        #expect(spend.first?.actualCost == 0.04)
        #expect(spend.first?.estimatedCost == 0.04)
        #expect(spend.first?.source == "external")
        #expect(spend.first?.timestamp == "2026-10-23T18:40:12Z")
        // index.json carries it, so the offline fallback sees it too.
        let index = try String(contentsOf: rig.dir.appending(path: "index.json"), encoding: .utf8)
        #expect(index.contains(id))
    }

    @Test func aCostInDollarsIsConvertedAtTheAppsRateAndRecordedAsExternalSpend() async throws {
        // Worked by hand: $0.04 at 0.5 is £0.02 (a rate the catalogue could set), not £0.0316 at 0.79.
        let rig = try LibraryRig(fx: 0.5)
        let result = try await rig.call("import_asset", args(png([6, 1]), ["actual_cost_usd": 0.04]))
        let id = try #require(result["asset_id"] as? String)
        #expect(result["spend_recorded"] as? Bool == true)
        let asset = try #require(try await rig.db.fetchAsset(id: id))
        #expect(asset.actualCost == 0.02)
        #expect(asset.estimatedCost == 0.02)
        let spend = try await rig.db.read { db in try SpendLog.fetchAll(db) }
        #expect(spend.count == 1)
        #expect(spend.first?.actualCost == 0.02)
        #expect(spend.first?.source == "external")
        // The pair: the same dollars at the fallback rate give a different sum.
        let other = try LibraryRig(fx: 0.79)
        let second = try await other.call("import_asset", args(png([6, 2]), ["actual_cost_usd": 0.04]))
        let secondID = try #require(second["asset_id"] as? String)
        #expect(try await other.db.fetchAsset(id: secondID)?.actualCost == 0.0316)
    }

    @Test func poundsAndDollarsTogetherAreRefusedAndNothingIsStored() async throws {
        let rig = try LibraryRig()
        let message = await rig.refusal("import_asset", args(png([6, 3]), ["actual_cost_gbp": 0.05, "actual_cost_usd": 0.04]))
        #expect(message.contains("not both"))
        #expect(await rig.refusal("import_asset", args(png([6, 4]), ["actual_cost_usd": -1])).contains("actual_cost_usd"))
        #expect(try await rig.count("SELECT COUNT(*) FROM assets") == 0)
        #expect(rig.assetFiles().isEmpty)
    }

    @Test func theCallersCreatedAtWinsOverTheFilesDateAndWithNeitherItIsTheImportTime() async throws {
        let rig = try LibraryRig()
        let given = try await rig.call("import_asset", args(png([1]), ["created_at": "2026-09-24T12:00:00Z"]))
        #expect(given["created_at"] as? String == "2026-09-24T12:00:00Z")
        #expect(given["imported_at"] as? String == "2026-10-25T08:00:00Z")
        var bare = args(png([2]))
        bare["file_modified_at"] = nil
        let neither = try await rig.call("import_asset", bare)
        #expect(neither["created_at"] as? String == "2026-10-25T08:00:00Z")
        let message = await rig.refusal("import_asset", args(png([3]), ["created_at": "last Tuesday"]))
        #expect(message.contains("created_at 'last Tuesday'"))
    }

    @Test func anUnknownCostIsNullNeverZeroAndWritesNoSpend() async throws {
        let rig = try LibraryRig()
        let result = try await rig.call("import_asset", args(png()))
        let id = try #require(result["asset_id"] as? String)
        let asset = try #require(try await rig.db.fetchAsset(id: id))
        #expect(asset.actualCost == nil)
        #expect(asset.estimatedCost == nil)
        #expect(result["actual_cost_gbp"] is NSNull)
        #expect(result["spend_recorded"] as? Bool == false)
        #expect(try await rig.count("SELECT COUNT(*) FROM spend_log") == 0)
        #expect(try await rig.count("SELECT COUNT(*) FROM assets WHERE actual_cost = 0 OR estimated_cost = 0") == 0)
    }

    @Test func externalSpendCanBeLeftOutOfGetSpendAndTheDashboardTotals() async throws {
        let rig = try LibraryRig()
        _ = try await rig.call("import_asset", args(png([4]), ["actual_cost_gbp": 0.25]))
        // And one charge of the app's own, as generation writes it (no source).
        try await rig.insertAsset("own", createdAt: "2026-10-24T10:00:00Z")
        try await rig.db.insertSpendLog(SpendLog(assetID: "own", providerID: "nano_banana", estimatedCost: 0.03, actualCost: nil, timestamp: "2026-10-24T10:00:00Z"))

        let all = try await rig.db.mcpGetSpend(project: nil, dateFrom: nil, dateTo: nil)
        let own = try await rig.db.mcpGetSpend(project: nil, dateFrom: nil, dateTo: nil, includeExternal: false)
        // Worked by hand: 0.25 + 0.03 = 0.28 over two; without the import 0.03 over one.
        #expect(all.generationCount == 2)
        #expect(abs(all.totalEstimated - 0.28) < 1e-9)
        #expect(own.generationCount == 1)
        #expect(abs(own.totalEstimated - 0.03) < 1e-9)
        let dashboard = try await rig.db.fetchSpendSummary(since: "2000-01-01", until: "2100-01-01", includeExternal: false)
        #expect(dashboard.generationCount == 1)
        let byProvider = try await rig.db.fetchSpendByProvider(since: "2000-01-01", until: "2100-01-01", includeExternal: false)
        #expect(byProvider.map(\.providerID) == ["nano_banana"])
        let daily = try await rig.db.fetchDailySpend(since: "2000-01-01", until: "2100-01-01", granularity: .day)
        #expect(abs(daily.reduce(0) { $0 + $1.estimated } - 0.28) < 1e-9)
    }

    @Test func aDuplicateIsNotStoredAgainAndItsProjectsAndTagsAreMerged() async throws {
        let rig = try LibraryRig()
        _ = try await rig.call("create_project", ["name": "Labs"])
        _ = try await rig.call("create_project", ["name": "Ionic Test"])
        let bytes = png([7, 7])
        let first = try await rig.call("import_asset", args(bytes, ["project": "Labs", "tags": ["hero"]]))
        let second = try await rig.call("import_asset", args(bytes, [
            "project": "Ionic Test", "tags": ["film"], "actual_cost_gbp": 0.04, "prompt": "another prompt",
        ]))
        let id = try #require(first["asset_id"] as? String)
        #expect(second["asset_id"] as? String == id)
        #expect(second["duplicate"] as? Bool == true)
        #expect(second["spend_recorded"] as? Bool == false)
        #expect(try await rig.count("SELECT COUNT(*) FROM assets") == 1)
        #expect(rig.assetFiles().count == 1)
        #expect(try await rig.count("SELECT COUNT(*) FROM spend_log") == 0)
        #expect(try await rig.links(id).rows == ["Ionic Test", "Labs*"])     // merged; the first stays primary
        #expect(second["tags"] as? [String] == ["film", "hero"])
        #expect(try await rig.db.fetchAsset(id: id)?.prompt == nil)         // the existing record is not rewritten
        // The pair: one byte different is a new asset.
        let other = try await rig.call("import_asset", args(png([7, 8])))
        #expect(other["duplicate"] as? Bool == false)
        #expect(try await rig.count("SELECT COUNT(*) FROM assets") == 2)
    }

    @Test func aRetryAfterAFailedFollowUpWriteAttachesTheMissingVariantFamily() async throws {
        let rig = try LibraryRig()
        let bytes = png([5, 5])
        let first = try await rig.call("import_asset", args(bytes, ["variant_family": "Labs heroes"]))
        let id = try #require(first["asset_id"] as? String)
        // The state a failed follow-up write leaves: the asset stored, its family never attached.
        try await rig.db.write { db in
            try db.execute(sql: "DELETE FROM variant_members WHERE asset_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM variants")
        }
        #expect(try await rig.db.isInVariantFamily(assetID: id) == false)

        let retry = try await rig.call("import_asset", args(bytes, ["variant_family": "Labs heroes"]))
        #expect(retry["duplicate"] as? Bool == true)
        let families = try await rig.db.read { db in
            try String.fetchAll(db, sql: "SELECT v.name FROM variant_members m JOIN variants v ON v.id = m.variant_id WHERE m.asset_id = ?", arguments: [id])
        }
        #expect(families == ["Labs heroes"])

        // The pair: a duplicate that has its family is not given a second one, whatever name is sent.
        _ = try await rig.call("import_asset", args(bytes, ["variant_family": "Something else"]))
        #expect(try await rig.count("SELECT COUNT(*) FROM variant_members") == 1)
        #expect(try await rig.count("SELECT COUNT(*) FROM variants") == 1)
    }

    @Test func bytesThatAreNotWhatTheyAreLabelledAreRefusedAndNothingIsWritten() async throws {
        let rig = try LibraryRig()
        var labelled = args(png())
        labelled["media_type"] = "image/svg+xml"
        let message = await rig.refusal("import_asset", labelled)
        #expect(message.contains("labelled 'image/svg+xml' but its contents are 'image/png'"))
        var text = args(Data("just some text".utf8))
        text["media_type"] = "image/png"
        _ = await rig.refusal("import_asset", text)
        #expect(try await rig.count("SELECT COUNT(*) FROM assets") == 0)
        #expect(rig.assetFiles().isEmpty)
    }

    @Test func aFileOverTwentyFiveMegabytesIsRefusedAndOneAtTheLimitIsStored() async throws {
        let rig = try LibraryRig()
        let limit = 25 * 1024 * 1024            // 26,214,400 bytes
        let over = png([UInt8](repeating: 0, count: limit + 1 - 8))
        let message = await rig.refusal("import_asset", args(over))
        #expect(message.contains("26214401 bytes, over the 26214400-byte import limit"))
        #expect(rig.assetFiles().isEmpty)
        let at = png([UInt8](repeating: 0, count: limit - 8))
        let stored = try await rig.call("import_asset", args(at))
        #expect(stored["duplicate"] as? Bool == false)
        #expect(rig.assetFiles().count == 1)
    }

    @Test func anUnknownProjectIsRefusedBeforeAnythingIsStored() async throws {
        let rig = try LibraryRig()
        _ = try await rig.call("create_project", ["name": "Labs"])
        let message = await rig.refusal("import_asset", args(png(), ["projects": ["Labs", "Lab"]]))
        #expect(message.contains("project 'Lab'"))
        #expect(message.contains("existing projects: Labs"))
        #expect(try await rig.count("SELECT COUNT(*) FROM assets") == 0)
        #expect(rig.assetFiles().isEmpty)
    }
}

// MARK: - list_tags

@Suite("list_tags")
struct ListTagsToolTests {
    @Test func everyTagWithItsCountMostUsedFirst() async throws {
        let rig = try LibraryRig()
        for id in ["a1", "a2", "a3"] { try await rig.insertAsset(id) }
        try await rig.db.bulkAddTagToAssets(assetIDs: ["a1", "a2", "a3"], tagName: "tfwm-elements")
        try await rig.db.bulkAddTagToAssets(assetIDs: ["a2"], tagName: "film")
        _ = try await rig.db.findOrCreateTag(name: "unused")
        let result = try await rig.call("list_tags")
        let tags = ((result["tags"] as? [[String: Any]]) ?? []).map { "\($0["name"] ?? ""):\($0["count"] ?? "")" }
        #expect(tags == ["tfwm-elements:3", "film:1", "unused:0"])
    }
}
