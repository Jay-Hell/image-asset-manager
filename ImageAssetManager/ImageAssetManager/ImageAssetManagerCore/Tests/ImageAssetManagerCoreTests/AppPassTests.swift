import Testing
import Foundation
import GRDB
import CoreGraphics
import ImageIO
@testable import ImageAssetManagerCore

// Release 1.2 pass B: the logic behind the sidebar, the tag manager and the thumbnail grid.
// The views are thin; everything they decide is here.

private func makeDB() throws -> AppDatabase { try AppDatabase(path: ":memory:") }

private func addAsset(_ db: AppDatabase, _ id: String, hidden: Bool = false) async throws {
    try await db.insertAsset(Asset(
        id: id, filename: "\(id).png", fileHash: "hash-\(id)", providerID: "nano_banana", modelID: "m",
        createdAt: "2026-10-01T09:00:00Z", isHidden: hidden))
}

private func addProject(_ db: AppDatabase, _ name: String, client: String? = nil) async throws -> String {
    let project = Project(name: name, clientID: client, createdAt: "2026-10-01T09:00:00Z")
    try await db.insertProject(project)
    return project.id
}

private func tag(_ db: AppDatabase, _ name: String, on assets: [String]) async throws -> String {
    let tag = try await db.findOrCreateTag(name: name)
    for asset in assets { try await db.attachTag(tagID: tag.id, assetID: asset) }
    return tag.id
}

private func count(_ db: AppDatabase, _ sql: String) async throws -> Int {
    try await db.read { try Int.fetchOne($0, sql: sql) ?? -1 }
}

// MARK: - Tag manager

@Suite("Tag manager")
struct TagManagerTests {

    @Test func renamingToAnotherTagsNameInAnyCaseIsRefusedAndChangesNothing() async throws {
        let db = try makeDB()
        try await addAsset(db, "a1")
        let logo = try await tag(db, "Logo", on: ["a1"])
        let hero = try await tag(db, "hero", on: ["a1"])
        await #expect(throws: TagError.nameInUse("Logo")) { try await db.renameTag(id: hero, newName: "  LOGO ") }
        #expect(try await db.fetchTagRows().map(\.name) == ["hero", "Logo"])
        // The pair: a free name is accepted, and so is the tag's own name in another case.
        try await db.renameTag(id: hero, newName: "banner")
        try await db.renameTag(id: logo, newName: "LOGO")
        #expect(try await db.fetchTagRows().map(\.name) == ["banner", "LOGO"])
        #expect(try await count(db, "SELECT COUNT(*) FROM asset_tags") == 2)
    }

    @Test func aBlankOrUnknownRenameIsRefused() async throws {
        let db = try makeDB()
        let t = try await tag(db, "x", on: [])
        await #expect(throws: TagError.emptyName) { try await db.renameTag(id: t, newName: "   ") }
        await #expect(throws: TagError.notFound) { try await db.renameTag(id: "nope", newName: "y") }
    }

    /// Worked by hand: A is on a1, a2; B on a2, a3. Merging B into A leaves A on a1, a2, a3 (a2 once).
    @Test func mergingMovesTheLinksCollapsesDuplicatesAndKeepsEveryAsset() async throws {
        let db = try makeDB()
        for id in ["a1", "a2", "a3"] { try await addAsset(db, id) }
        let a = try await tag(db, "A", on: ["a1", "a2"])
        let b = try await tag(db, "B", on: ["a2", "a3"])
        let other = try await tag(db, "C", on: ["a1"])
        let folded = try await db.mergeTags(ids: [a, b], into: a)
        #expect(folded == 1)
        let rows = try await db.fetchTagRows()
        #expect(rows.map(\.name) == ["A", "C"])
        #expect(rows.first { $0.id == a }?.count == 3)
        #expect(rows.first { $0.id == other }?.count == 1)
        #expect(try await count(db, "SELECT COUNT(*) FROM assets") == 3)
        #expect(try await count(db, "SELECT COUNT(*) FROM asset_tags WHERE tag_id = '\(a)' AND asset_id = 'a2'") == 1)
    }

    @Test func mergingIntoATagOutsideTheSelectionIsRefusedAndChangesNothing() async throws {
        let db = try makeDB()
        try await addAsset(db, "a1")
        let a = try await tag(db, "A", on: ["a1"])
        let b = try await tag(db, "B", on: ["a1"])
        let c = try await tag(db, "C", on: [])
        await #expect(throws: TagError.targetNotSelected) { try await db.mergeTags(ids: [a, b], into: c) }
        #expect(try await db.fetchTagRows().count == 3)
    }

    @Test func deletingATagRemovesItsLinksAndNeverTheAssets() async throws {
        let db = try makeDB()
        for id in ["a1", "a2"] { try await addAsset(db, id) }
        let doomed = try await tag(db, "doomed", on: ["a1", "a2"])
        let kept = try await tag(db, "kept", on: ["a1"])
        try await db.deleteTag(id: doomed)
        #expect(try await count(db, "SELECT COUNT(*) FROM assets") == 2)
        #expect(try await count(db, "SELECT COUNT(*) FROM asset_tags WHERE tag_id = '\(doomed)'") == 0)
        #expect(try await count(db, "SELECT COUNT(*) FROM tags WHERE id = '\(doomed)'") == 0)
        // The pair: the other tag and its link stand.
        #expect(try await db.fetchTagRows().map(\.id) == [kept])
        #expect(try await db.fetchTagRows().first?.count == 1)
    }

    @Test func theListShowsEveryTagWithItsCountIncludingUnused() async throws {
        let db = try makeDB()
        for id in ["a1", "a2"] { try await addAsset(db, id) }
        _ = try await tag(db, "used", on: ["a1", "a2"])
        _ = try await tag(db, "Unused", on: [])
        let rows = try await db.fetchTagRows()
        #expect(rows.map(\.name) == ["Unused", "used"])
        #expect(rows.map(\.count) == [0, 2])
    }
}

// MARK: - Sidebar

@Suite("Sidebar counts, Unfiled and grouping")
struct SidebarTests {

    /// Worked by hand. Assets a1..a5; a5 is hidden. P1 (client C1): a1, a2. P2 (C1): a2, a3.
    /// P3 (no client): a4, a5. Unfiled: none visible... so a6 is added, unfiled.
    /// Visible: C1 holds a1, a2, a3 = 3 (a2 once); P1 2; P2 2; P3 1 (a5 hidden); unfiled 1; all 5.
    /// Hidden shown: P3 2, all 6.
    @Test func countsAreDistinctPerClientAndLeaveHiddenAssetsOutUnlessAsked() async throws {
        let db = try makeDB()
        for id in ["a1", "a2", "a3", "a4", "a6"] { try await addAsset(db, id) }
        try await addAsset(db, "a5", hidden: true)
        let client = try await db.createClient(name: "C1").client
        let p1 = try await addProject(db, "P1", client: client.id)
        let p2 = try await addProject(db, "P2", client: client.id)
        let p3 = try await addProject(db, "P3")
        _ = try await db.fileAssets(assetIDs: ["a1", "a2"], projectID: p1, mode: .add, primary: false)
        _ = try await db.fileAssets(assetIDs: ["a2", "a3"], projectID: p2, mode: .add, primary: false)
        _ = try await db.fileAssets(assetIDs: ["a4", "a5"], projectID: p3, mode: .add, primary: false)

        let visible = try await db.fetchSidebarCounts()
        #expect(visible.projects[p1] == 2)
        #expect(visible.projects[p2] == 2)
        #expect(visible.projects[p3] == 1)
        #expect(visible.clients[client.id] == 3)
        #expect(visible.unfiled == 1)
        #expect(visible.all == 5)

        let everything = try await db.fetchSidebarCounts(showHidden: true)
        #expect(everything.projects[p3] == 2)
        #expect(everything.all == 6)
        #expect(everything.clients[client.id] == 3)
    }

    @Test func theUnfiledQueryAndTheUnfiledCountAgreeAndFollowFiling() async throws {
        let db = try makeDB()
        for id in ["a1", "a2", "a3"] { try await addAsset(db, id) }
        let p = try await addProject(db, "P")
        #expect(Set(try await db.searchAssets(projectIDs: []).map(\.id)) == ["a1", "a2", "a3"])
        #expect(try await db.fetchSidebarCounts().unfiled == 3)
        _ = try await db.fileAssets(assetIDs: ["a2"], projectID: p, mode: .move, primary: true)
        #expect(Set(try await db.searchAssets(projectIDs: []).map(\.id)) == ["a1", "a3"])
        #expect(try await db.fetchSidebarCounts().unfiled == 2)
        // Filed means in the project's own list, not in Unfiled.
        #expect(try await db.searchAssets(projectIDs: [p]).map(\.id) == ["a2"])
    }

    /// Worked by hand. u1 is unfiled. C0 has no projects. C1 has P1 (a1, and a5 hidden).
    /// C2 has P2a (a2) and P2b (a2, a3). Loose (no client) has a4.
    /// Grids: C0 none; C1 a1 (a1, a5 with hidden shown); C2 a2, a3 (a2 once). Counts agree: C0 0, C1 1, C2 2.
    @Test func aClientsGridHoldsItsProjectsAssetsAndAClientWithNoneShowsNone() async throws {
        let db = try makeDB()
        for id in ["u1", "a1", "a2", "a3", "a4"] { try await addAsset(db, id) }
        try await addAsset(db, "a5", hidden: true)
        let c0 = try await db.createClient(name: "C0").client.id
        let c1 = try await db.createClient(name: "C1").client.id
        let c2 = try await db.createClient(name: "C2").client.id
        let p1 = try await addProject(db, "P1", client: c1)
        let p2a = try await addProject(db, "P2a", client: c2)
        let p2b = try await addProject(db, "P2b", client: c2)
        let loose = try await addProject(db, "Loose")
        _ = try await db.fileAssets(assetIDs: ["a1", "a5"], projectID: p1, mode: .add, primary: false)
        _ = try await db.fileAssets(assetIDs: ["a2"], projectID: p2a, mode: .add, primary: false)
        _ = try await db.fileAssets(assetIDs: ["a2", "a3"], projectID: p2b, mode: .add, primary: false)
        _ = try await db.fileAssets(assetIDs: ["a4"], projectID: loose, mode: .add, primary: false)

        func grid(_ client: String, showHidden: Bool = false) async throws -> [String] {
            try await db.searchAssets(clientID: client, showHidden: showHidden).map(\.id).sorted()
        }
        // Zero projects: an empty grid, never the unfiled u1.
        #expect(try await grid(c0) == [])
        // The pairs: one project, and two projects sharing an asset.
        #expect(try await grid(c1) == ["a1"])
        #expect(try await grid(c1, showHidden: true) == ["a1", "a5"])
        #expect(try await grid(c2) == ["a2", "a3"])
        let counts = try await db.fetchSidebarCounts()
        #expect((counts.clients[c0] ?? 0) == 0)
        #expect(counts.clients[c1] == 1)
        #expect(counts.clients[c2] == 2)
    }

    @Test func groupsAreByClientThenProjectIgnoringCaseWithTheClientlessGroupLast() {
        let tfwm = Client(id: "c-t", name: "TfWM", createdAt: "x")
        let ionic = Client(id: "c-i", name: "ionic", createdAt: "x")
        let empty = Client(id: "c-e", name: "Zeta", createdAt: "x")
        func project(_ id: String, _ name: String, _ client: String?) -> Project {
            Project(id: id, name: name, clientID: client, createdAt: "x")
        }
        let groups = SidebarGrouping.groups(
            clients: [tfwm, empty, ionic],
            projects: [project("p1", "Swift Go", "c-t"), project("p2", "alpha", "c-t"), project("p3", "Labs", "c-i"),
                       project("p4", "Loose", nil), project("p5", "Orphan", "gone")])
        #expect(groups.map { $0.client?.name } == ["ionic", "TfWM", "Zeta", nil])
        #expect(groups.map { $0.projects.map(\.name) } == [["Labs"], ["alpha", "Swift Go"], [], ["Loose", "Orphan"]])
        // The pair: with nothing clientless there is no clientless group.
        let tidy = SidebarGrouping.groups(clients: [tfwm], projects: [project("p1", "A", "c-t")])
        #expect(tidy.count == 1 && tidy[0].client?.name == "TfWM")
    }

    @Test func theClashMessagesNameTheExistingRecord() {
        #expect(NameClash.client("TfWM") == "A client named \u{201C}TfWM\u{201D} already exists.")
        #expect(NameClash.project("Labs") == "A project named \u{201C}Labs\u{201D} already exists.")
    }
}

// MARK: - R2-1 leftovers

@Suite("findProject ambiguity and mergeProjects family rule")
struct R21LeftoverTests {

    @Test func aNameMatchingTwoProjectsThatDifferOnlyInCaseIsRefusedNamingBoth() async throws {
        let db = try makeDB()
        let older = try await addProject(db, "Labs")
        let newer = Project(name: "labs", createdAt: "2026-10-02T09:00:00Z")
        try await db.insertProject(newer)
        do {
            _ = try await db.findProject(idOrName: "LABS")
            Issue.record("an ambiguous name should be refused")
        } catch let error as ProjectError {
            let text = error.localizedDescription
            #expect(text.contains("'Labs' (\(older))") && text.contains("'labs' (\(newer.id))"))
            #expect(text.contains("differ only in case"))
        }
        // The pairs: an exact name still resolves, an ID resolves, and a lone case difference resolves.
        #expect(try await db.findProject(idOrName: "labs")?.id == newer.id)
        #expect(try await db.findProject(idOrName: older)?.id == older)
        _ = try await addProject(db, "Solo")
        #expect(try await db.findProject(idOrName: "SOLO")?.name == "Solo")
    }

    /// a and b share a family; b is in P1, a is in nothing, so the family is under no project.
    /// Merging P1 into a gives a the primary P1: every member now agrees, so the family follows.
    @Test func mergeProjectsFilesTheVariantFamilyWhereItsMembersAre() async throws {
        let db = try makeDB()
        try await addAsset(db, "a"); try await addAsset(db, "b")
        let p1 = try await addProject(db, "P1")
        for id in ["a", "b"] {
            _ = try await db.attachToVariantFamily(
                assetID: id, projectID: nil, familyName: "Heroes", prompt: nil, filename: "\(id).png")
        }
        _ = try await db.fileAssets(assetIDs: ["b"], projectID: p1, mode: .move, primary: true)
        func familyProject() async throws -> String? {
            try await db.read { try String.fetchOne($0, sql: """
                SELECT v.project_id FROM variants v JOIN variant_members m ON m.variant_id = v.id WHERE m.asset_id = 'a'
                """) }
        }
        #expect(try await familyProject() == nil)
        try await db.mergeProjects(assetID: "a", projectIDs: [p1])
        #expect(try await familyProject() == p1)
        // The pair: merging a second project (not the primary) leaves the family where it is.
        let p2 = try await addProject(db, "P2")
        try await db.mergeProjects(assetID: "a", projectIDs: [p2])
        #expect(try await familyProject() == p1)
    }
}

// MARK: - Thumbnails

@Suite("Thumbnail cache")
struct ThumbnailCacheTests {

    private func writePNG(_ url: URL, width: Int, height: Int) throws {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func theKeyIsPerAssetAndHashAndCannotNameAPath() {
        let base = ThumbnailCache.key(assetID: "A1", fileHash: "h1")
        #expect(base == "A1-h1-512.png")
        #expect(ThumbnailCache.key(assetID: "A1", fileHash: "h2") != base)
        #expect(ThumbnailCache.key(assetID: "A2", fileHash: "h1") != base)
        #expect(ThumbnailCache.key(assetID: "A1", fileHash: "h1") == base)
        let hostile = ThumbnailCache.key(assetID: "../../etc/x", fileHash: "h/1")
        #expect(hostile == "etcx-h1-512.png")
    }

    @Test func aRasterIsShrunkCachedAndServedFromTheCacheAfterTheSourceGoes() async throws {
        let work = makeTempDirectory(), library = makeTempDirectory()
        let source = library.appending(path: "big.png")
        try writePNG(source, width: 1024, height: 512)
        let cache = ThumbnailCache(directory: work.appending(path: "Thumbs"))
        let first = try #require(await cache.thumbnail(assetID: "a1", fileHash: "h1", source: source))
        #expect(first.width == 512 && first.height == 256)   // 1024x512 scaled to a 512 longest side
        let cached = cache.cacheURL(assetID: "a1", fileHash: "h1")
        #expect(FileManager.default.fileExists(atPath: cached.path(percentEncoded: false)))
        // Not in the library folder.
        #expect(!cached.path(percentEncoded: false).hasPrefix(library.path(percentEncoded: false)))
        // Served from the cache: the source is gone.
        try FileManager.default.removeItem(at: source)
        let second = try #require(await cache.thumbnail(assetID: "a1", fileHash: "h1", source: source))
        #expect(second.width == 512)
        // The pair: a different hash is a miss, so with the source gone it draws nothing.
        #expect(await cache.thumbnail(assetID: "a1", fileHash: "h2", source: source) == nil)
    }

    @Test func aNewHashReplacesTheOldEntryForThatAssetOnly() async throws {
        let work = makeTempDirectory()
        let source = work.appending(path: "s.png")
        try writePNG(source, width: 64, height: 64)
        let cache = ThumbnailCache(directory: work.appending(path: "Thumbs"))
        _ = await cache.thumbnail(assetID: "a1", fileHash: "old", source: source)
        _ = await cache.thumbnail(assetID: "a2", fileHash: "keep", source: source)
        _ = await cache.thumbnail(assetID: "a1", fileHash: "new", source: source)
        let names = try FileManager.default.contentsOfDirectory(atPath: work.appending(path: "Thumbs").path(percentEncoded: false)).sorted()
        #expect(names == ["a1-new-512.png", "a2-keep-512.png"])
    }

    @Test func anSVGThumbnailComesFromTheSanitisedPreview() async throws {
        let work = makeTempDirectory()
        let source = work.appending(path: "v.svg")
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect width="200" height="100" fill="red"/>\
            <script>alert(1)</script></svg>
            """
        try Data(svg.utf8).write(to: source)
        let cache = ThumbnailCache(directory: work.appending(path: "Thumbs"))
        let image = try #require(await cache.thumbnail(assetID: "v1", fileHash: "h", source: source))
        #expect(image.width > 0 && image.height > 0)
        #expect(FileManager.default.fileExists(atPath: cache.cacheURL(assetID: "v1", fileHash: "h").path(percentEncoded: false)))
    }

    @Test func bytesThatDrawNothingCacheNothing() async throws {
        let work = makeTempDirectory()
        let source = work.appending(path: "x.png")
        try Data("not an image".utf8).write(to: source)
        let cache = ThumbnailCache(directory: work.appending(path: "Thumbs"))
        #expect(await cache.thumbnail(assetID: "x1", fileHash: "h", source: source) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.cacheURL(assetID: "x1", fileHash: "h").path(percentEncoded: false)))
    }
}
