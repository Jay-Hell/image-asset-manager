import Testing
import Foundation
import GRDB
@testable import ImageAssetManagerCore

// Release 1.2, R2-6: managing clients and projects, dropping images, Mac selection.

private func makeDB() throws -> AppDatabase { try AppDatabase(path: ":memory:") }

private func addAsset(_ db: AppDatabase, _ id: String) async throws {
    try await db.insertAsset(Asset(
        id: id, filename: "\(id).png", fileHash: "hash-\(id)", providerID: "nano_banana", modelID: "m",
        createdAt: "2026-10-01T09:00:00Z"))
}

private func addProject(_ db: AppDatabase, _ name: String, client: String? = nil) async throws -> String {
    let project = Project(name: name, clientID: client, createdAt: "2026-10-01T09:00:00Z")
    try await db.insertProject(project)
    return project.id
}

private func count(_ db: AppDatabase, _ sql: String) async throws -> Int {
    try await db.read { try Int.fetchOne($0, sql: sql) ?? -1 }
}

/// The asset's project IDs, primary first, then by ID.
private func links(_ db: AppDatabase, _ asset: String) async throws -> [String] {
    try await db.read {
        try String.fetchAll($0, sql: "SELECT project_id FROM asset_projects WHERE asset_id = ? ORDER BY is_primary DESC, project_id",
                            arguments: [asset])
    }
}

private func primary(_ db: AppDatabase, _ asset: String) async throws -> String? {
    try await db.read {
        try String.fetchOne($0, sql: "SELECT project_id FROM asset_projects WHERE asset_id = ? AND is_primary = 1", arguments: [asset])
    }
}

private func mirror(_ db: AppDatabase, _ asset: String) async throws -> String? {
    try await db.read { try String?.fetchOne($0, sql: "SELECT project_id FROM assets WHERE id = ?", arguments: [asset]) ?? nil }
}

@Suite("Manage clients and projects")
struct ManageTests {

    @Test func deletingAClientDetachesItsProjectsAndKeepsTheirImages() async throws {
        let db = try makeDB()
        let a = try await db.findOrCreateClient(name: "Acme")
        let b = try await db.findOrCreateClient(name: "Beta")
        let p1 = try await addProject(db, "One", client: a.id)
        let p2 = try await addProject(db, "Two", client: a.id)
        let p3 = try await addProject(db, "Three", client: b.id)
        try await addAsset(db, "a1")
        _ = try await db.fileAssets(assetIDs: ["a1"], projectID: p1, mode: .add, primary: false)

        let detached = try await db.deleteClient(id: a.id)
        #expect(detached == 2)
        #expect(try await db.fetchClients().map(\.name) == ["Beta"])
        let byID = Dictionary(uniqueKeysWithValues: try await db.fetchProjects().map { ($0.id, $0.clientID) })
        #expect(byID.count == 3)
        #expect(byID[p1] == .some(nil) && byID[p2] == .some(nil), "the deleted client's projects have no client")
        #expect(byID[p3] == .some(b.id), "another client's project is untouched")
        #expect(try await links(db, "a1") == [p1])
        #expect(try await count(db, "SELECT COUNT(*) FROM assets") == 1)
        // The sidebar puts the two under "No client".
        let groups = SidebarGrouping.groups(clients: try await db.fetchClients(), projects: try await db.fetchProjects())
        #expect(groups.map { $0.client?.name } == ["Beta", nil])
        #expect(groups[1].projects.map(\.name) == ["One", "Two"])

        // The pair: a client with no projects deletes and detaches nothing.
        let empty = try await db.findOrCreateClient(name: "Empty")
        #expect(try await db.deleteClient(id: empty.id) == 0)
        #expect(try await db.fetchClients().map(\.name) == ["Beta"])
        #expect(try await db.projectCount(clientID: b.id) == 1)
    }

    @Test func deletingAProjectKeepsItsImagesAndFixesThePrimary() async throws {
        let db = try makeDB()
        let apple = try await addProject(db, "Apple")
        let banana = try await addProject(db, "banana")
        let cherry = try await addProject(db, "Cherry")
        for id in ["a1", "a2", "a3"] { try await addAsset(db, id) }
        // a1: primary Cherry, also Banana and Apple. a2: Cherry only. a3: primary Banana, also Cherry.
        _ = try await db.fileAssets(assetIDs: ["a1"], projectID: cherry, mode: .move, primary: false)
        _ = try await db.fileAssets(assetIDs: ["a1"], projectID: banana, mode: .add, primary: false)
        _ = try await db.fileAssets(assetIDs: ["a1"], projectID: apple, mode: .add, primary: false)
        _ = try await db.fileAssets(assetIDs: ["a2"], projectID: cherry, mode: .move, primary: false)
        _ = try await db.fileAssets(assetIDs: ["a3"], projectID: banana, mode: .move, primary: false)
        _ = try await db.fileAssets(assetIDs: ["a3"], projectID: cherry, mode: .add, primary: false)
        #expect(try await primary(db, "a1") == cherry)
        #expect(try await mirror(db, "a1") == cherry)
        #expect(try await db.assetCount(projectID: cherry) == 3)

        try await db.deleteProject(id: cherry)

        #expect(try await count(db, "SELECT COUNT(*) FROM assets") == 3, "the images stay in the library")
        #expect(try await db.fetchProjects().map(\.name).sorted() == ["Apple", "banana"])
        // a1 loses its primary: the first of its others by name ignoring case is Apple.
        #expect(try await primary(db, "a1") == apple)
        #expect(try await mirror(db, "a1") == apple)
        #expect(try await links(db, "a1") == [apple, banana])
        // a2 had only Cherry: no project, shown under Unfiled.
        #expect(try await links(db, "a2").isEmpty)
        #expect(try await mirror(db, "a2") == nil)
        #expect(try await db.fetchSidebarCounts().unfiled == 1)
        #expect(try await db.searchAssets(projectIDs: []).map(\.id) == ["a2"])
        // The pair: a3's primary was not the deleted project, so it stays.
        #expect(try await primary(db, "a3") == banana)
        #expect(try await links(db, "a3") == [banana])
        #expect(try await mirror(db, "a3") == banana)
        // Every asset with a link has exactly one primary.
        #expect(try await count(db, "SELECT COUNT(*) FROM asset_projects WHERE is_primary = 1") == 2)
    }

    @Test func deletingAProjectDoesNotTakeItsVariantFamiliesWithIt() async throws {
        let db = try makeDB()
        let p1 = try await addProject(db, "One")
        let p2 = try await addProject(db, "Two")
        try await addAsset(db, "a1")
        try await addAsset(db, "a2")
        try await addAsset(db, "a3")
        for id in ["a1", "a2"] {
            _ = try await db.fileAssets(assetIDs: [id], projectID: p1, mode: .move, primary: false)
            _ = try await db.attachToVariantFamily(assetID: id, projectID: p1, familyName: "Heroes", prompt: nil, filename: "\(id).png")
        }
        // a2 is also in Two, so after the delete the family's members are Unfiled (a1) and Two (a2): split.
        _ = try await db.fileAssets(assetIDs: ["a2"], projectID: p2, mode: .add, primary: false)
        // The pair: a family filed under the surviving project must be untouched.
        _ = try await db.fileAssets(assetIDs: ["a3"], projectID: p2, mode: .move, primary: false)
        _ = try await db.attachToVariantFamily(assetID: "a3", projectID: p2, familyName: "Solo", prompt: nil, filename: "a3.png")
        let before = try await count(db, "SELECT COUNT(*) FROM variants")
        let membersBefore = try await count(db, "SELECT COUNT(*) FROM variant_members")

        try await db.deleteProject(id: p1)

        #expect(try await count(db, "SELECT COUNT(*) FROM variants") == before)
        #expect(try await count(db, "SELECT COUNT(*) FROM variant_members") == membersBefore)
        let families: [[String?]] = try await db.read {
            try Row.fetchAll($0, sql: "SELECT name, project_id FROM variants WHERE name IN ('Heroes','Solo') ORDER BY name")
                .map { [$0["name"] as String?, $0["project_id"] as String?] }
        }
        #expect(families == [["Heroes", nil], ["Solo", p2]])
    }

    @Test func aDropAddsOrMovesAndTheFamilyFollows() async throws {
        let db = try makeDB()
        let p1 = try await addProject(db, "One")
        let p2 = try await addProject(db, "Two")
        let p3 = try await addProject(db, "Three")
        for id in ["a1", "a2", "a3", "a4"] { try await addAsset(db, id) }
        for id in ["a1", "a2"] {
            _ = try await db.fileAssets(assetIDs: [id], projectID: p1, mode: .move, primary: false)
            _ = try await db.fileAssets(assetIDs: [id], projectID: p2, mode: .add, primary: false)
        }
        // Plain drop (add): a2 keeps One (primary) and Two, and gains Three.
        _ = try await db.fileAssets(assetIDs: ["a2"], projectID: p3, mode: .add, primary: false)
        #expect(Set(try await links(db, "a2")) == [p1, p2, p3])
        #expect(try await primary(db, "a2") == p1)
        // Option drop (move): a1 leaves One and Two and is in Three alone, as its primary.
        _ = try await db.fileAssets(assetIDs: ["a1"], projectID: p3, mode: .move, primary: false)
        #expect(try await links(db, "a1") == [p3])
        #expect(try await primary(db, "a1") == p3)
        #expect(try await mirror(db, "a1") == p3)

        // The family rule: a3 and a4 share a family in One. Moving one splits it (no project);
        // moving the other after it brings it back under Two.
        for id in ["a3", "a4"] {
            _ = try await db.fileAssets(assetIDs: [id], projectID: p1, mode: .move, primary: false)
            _ = try await db.attachToVariantFamily(assetID: id, projectID: p1, familyName: "Heroes", prompt: nil, filename: "\(id).png")
        }
        func familyProject() async throws -> String? {
            try await db.read { try String?.fetchOne($0, sql: "SELECT project_id FROM variants WHERE name = 'Heroes'") ?? nil }
        }
        #expect(try await familyProject() == p1)
        _ = try await db.fileAssets(assetIDs: ["a3"], projectID: p2, mode: .move, primary: false)
        #expect(try await familyProject() == nil)
        _ = try await db.fileAssets(assetIDs: ["a4"], projectID: p2, mode: .move, primary: false)
        #expect(try await familyProject() == p2)
    }

    @Test func aRenameThatClashesIsRefusedInAnyCaseAndNothingChanges() async throws {
        let db = try makeDB()
        let a = try await db.findOrCreateClient(name: "Écran")
        let b = try await db.findOrCreateClient(name: "Beta")
        let p1 = try await addProject(db, "Écran labs")
        let p2 = try await addProject(db, "Other")
        await #expect(throws: ClientError.nameInUse) { try await db.renameClient(id: b.id, newName: " écran ") }
        await #expect(throws: ProjectError.nameInUse) { try await db.renameProject(id: p2, newName: "ÉCRAN LABS") }
        #expect(try await db.fetchClients().map(\.name).sorted() == ["Beta", "Écran"])
        #expect(try await db.fetchProjects().map(\.name).sorted() == ["Other", "Écran labs"])
        // The text is the one creating gives, naming the holder of the name as it is stored.
        await #expect(throws: NameClashError(message: NameClash.client("Écran"))) {
            try await db.renameClientReportingClash(id: b.id, newName: "ÉCRAN")
        }
        await #expect(throws: NameClashError(message: NameClash.project("Écran labs"))) {
            try await db.renameProjectReportingClash(id: p2, newName: "écran LABS")
        }
        // The pair: a free name and the project's own name in another case are accepted.
        try await db.renameClient(id: b.id, newName: "Gamma")
        try await db.renameProject(id: p1, newName: "ÉCRAN LABS")
        #expect(try await db.fetchClients().map(\.name).sorted() == ["Gamma", "Écran"])
        #expect(try await db.fetchProjects().map(\.name).sorted() == ["Other", "ÉCRAN LABS"])
        _ = a
    }

    @Test func movingAProjectToAClientOrToNoClientChangesOnlyItsClient() async throws {
        let db = try makeDB()
        let a = try await db.findOrCreateClient(name: "Acme")
        let b = try await db.findOrCreateClient(name: "Beta")
        let p = try await addProject(db, "One", client: a.id)
        try await db.setProjectClient(projectID: p, clientID: b.id)
        #expect(try await db.fetchProjects().first?.clientID == b.id)
        #expect(try await db.projectCount(clientID: a.id) == 0)
        #expect(try await db.projectCount(clientID: b.id) == 1)
        try await db.setProjectClient(projectID: p, clientID: nil)
        #expect(try await db.fetchProjects().first?.clientID == nil)
        #expect(try await db.fetchProjects().first?.name == "One")
    }
}

@Suite("Grid selection")
struct GridSelectionTests {
    private let order = ["a", "b", "c", "d", "e"]

    @Test func aRangeRunsFromTheAnchorToTheTargetInGridOrderEitherWay() {
        #expect(GridSelection.range(order: order, anchor: "b", to: "d") == ["b", "c", "d"])
        #expect(GridSelection.range(order: order, anchor: "d", to: "b") == ["b", "c", "d"], "reversed gives the same, in grid order")
        #expect(GridSelection.range(order: order, anchor: "c", to: "c") == ["c"])
        // No anchor, or one that is not in the grid: just the target. A target not in the grid: nothing.
        #expect(GridSelection.range(order: order, anchor: nil, to: "d") == ["d"])
        #expect(GridSelection.range(order: order, anchor: "zz", to: "d") == ["d"])
        #expect(GridSelection.range(order: order, anchor: "b", to: "zz").isEmpty)
    }

    @Test func clicksSelectToggleAndExtendTheMacWay() {
        var s = GridSelection()
        s.click("c", .plain, order: order)
        #expect(s.selected == ["c"] && s.anchor == "c")
        s.click("e", .shift, order: order)
        #expect(s.selected == ["c", "d", "e"] && s.anchor == "c", "shift keeps the anchor")
        s.click("a", .shift, order: order)
        #expect(s.selected == ["a", "b", "c"], "a second shift-click replaces the range, from the same anchor")
        s.click("b", .command, order: order)
        #expect(s.selected == ["a", "c"] && s.anchor == "b", "command removes one and moves the anchor")
        s.click("e", .command, order: order)
        #expect(s.selected == ["a", "c", "e"])
        s.click("d", .shift, order: order)
        #expect(s.selected == ["d", "e"], "range from the anchor e to d")
        // A plain click on one of several drops the rest.
        s.click("a", .plain, order: order)
        #expect(s.selected == ["a"])
    }

    @Test func aMenuOrDragActsOnTheWholeSelectionOnlyWhenTheImageIsInIt() {
        var s = GridSelection()
        s.click("b", .plain, order: order)
        s.click("d", .shift, order: order)
        #expect(s.actedOn("c") == ["b", "c", "d"])
        #expect(s.actedOn("a") == ["a"], "an unselected image acts alone")
    }

    @Test func selectAllTakesTheViewAndClearEmptiesIt() {
        var s = GridSelection()
        s.selectAll(order: order)
        #expect(s.selected == Set(order))
        s.clear()
        #expect(s.selected.isEmpty && s.anchor == nil)
        // The view changed under the selection: ⌘A is over the new view only.
        s.selectAll(order: ["x", "y"])
        #expect(s.selected == ["x", "y"])
    }
}
