//
//  ImageAssetManagerTests.swift
//  ImageAssetManagerTests
//
//  Created by John Livingston on 17/04/2026.
//

import Testing
import Foundation
import ImageAssetManagerCore
@testable import ImageAssetManager

/// These tests run inside the app as their host. The host must never open the real library:
/// under XCTest `AppEnvironment.make()` opens a fresh library in the temporary directory.
@MainActor
struct ImageAssetManagerTests {

    @Test func theTestHostOpenedATemporaryLibraryNotTheRealOne() throws {
        #expect(AppEnvironment.isTestHost)
        let opened = try #require(AppEnvironment.openedLibraryURL, "the host app did not open a library")
        #expect(TestHostIsolation.isInsideTemporaryDirectory(opened), "host opened \(opened.path(percentEncoded: false))")
        #expect(opened.lastPathComponent.hasPrefix("ImageAssetManager-TestHost-"))
    }

    /// App Store Connect asks the export-compliance question on every upload unless the bundle says
    /// it uses only exempt encryption. The app uses Apple's own: HTTPS, the Keychain, CryptoKit hashing.
    @Test func theBundleDeclaresOnlyExemptEncryption() {
        let declared = Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption")
        #expect(declared as? Bool == false, "ITSAppUsesNonExemptEncryption is \(String(describing: declared))")
    }

    /// R2-2 P2. Worked by hand: one visible asset, so All is 1; hidden, 0; unhidden, 1 again;
    /// hidden from the inspector, 0. Each step's count must agree with the grid without a reload.
    @Test func hidingAndUnhidingRefreshTheSidebarCountsAsWellAsTheGrid() async throws {
        let library = FileManager.default.temporaryDirectory.appending(path: "IAM-HideTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: library.appending(path: "assets"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: library) }
        let db = try AppDatabase(path: ":memory:")
        try await db.insertAsset(Asset(
            id: "a1", filename: "a1.png", fileHash: "h1", providerID: "nano_banana", modelID: "m",
            createdAt: "2026-10-01T09:00:00Z"))
        let model = LibraryViewModel(database: db, libraryURL: library)
        await model.loadSidebarData()
        await model.loadAssets()
        #expect(model.counts.all == 1 && model.assets.map(\.id) == ["a1"])

        try await model.setHidden(["a1"], hidden: true)
        #expect(model.counts.all == 0)
        #expect(model.assets.isEmpty)
        // The unhide path returned before any reload.
        try await model.setHidden(["a1"], hidden: false)
        #expect(model.counts.all == 1)
        #expect(model.assets.map(\.id) == ["a1"])
        try await model.toggleHidden(assetID: "a1")
        #expect(model.counts.all == 0)
    }

    /// Changing an asset's projects from the inspector moves it out of Unfiled and into the project's
    /// count at once. Worked by hand: one unfiled asset, so Unfiled 1 and the project 0; filed, 0 and 1;
    /// detached again, 1 and 0.
    @Test func changingAnAssetsProjectsFromTheInspectorRefreshesTheSidebarCounts() async throws {
        let library = FileManager.default.temporaryDirectory.appending(path: "IAM-ProjectsTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: library.appending(path: "assets"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: library) }
        let db = try AppDatabase(path: ":memory:")
        try await db.insertAsset(Asset(
            id: "a1", filename: "a1.png", fileHash: "h1", providerID: "nano_banana", modelID: "m",
            createdAt: "2026-10-01T09:00:00Z"))
        let project = try await db.createProject(name: "Labs", clientID: nil, description: nil).project
        let model = LibraryViewModel(database: db, libraryURL: library)
        await model.loadSidebarData()
        #expect(model.counts.unfiled == 1 && (model.counts.projects[project.id] ?? 0) == 0)

        try await model.setAssetProjects(assetID: "a1", projectIDs: [project.id])
        #expect(model.counts.unfiled == 0)
        #expect(model.counts.projects[project.id] == 1)

        // The pair: detaching puts it back in Unfiled.
        try await model.setAssetProjects(assetID: "a1", projectIDs: [])
        #expect(model.counts.unfiled == 1 && (model.counts.projects[project.id] ?? 0) == 0)
    }

    private func manageRig() async throws -> (db: AppDatabase, model: LibraryViewModel, library: URL) {
        let library = FileManager.default.temporaryDirectory.appending(path: "IAM-ManageTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: library.appending(path: "assets"), withIntermediateDirectories: true)
        let db = try AppDatabase(path: ":memory:")
        try await db.insertAsset(Asset(
            id: "a1", filename: "a1.png", fileHash: "h1", providerID: "nano_banana", modelID: "m",
            createdAt: "2026-10-01T09:00:00Z"))
        return (db, LibraryViewModel(database: db, libraryURL: library), library)
    }

    /// R2-6. A rename and a client change reach the sidebar (order, groups, counts) with no reload by the
    /// caller. Worked by hand: "beta" renamed "Aardvark" sorts before "Alpha"; Alpha moved to client Zed
    /// puts Alpha under Zed (count 1, its one image) and leaves Aardvark under No client; Zed renamed "Acme".
    @Test func renamingAndMovingRefreshTheSidebarGroupsAndCounts() async throws {
        let (db, model, library) = try await manageRig()
        defer { try? FileManager.default.removeItem(at: library) }
        let zed = try await db.createClient(name: "Zed").client
        let alpha = try await db.createProject(name: "Alpha", clientID: nil, description: nil).project
        let beta = try await db.createProject(name: "beta", clientID: nil, description: nil).project
        _ = try await db.fileAssets(assetIDs: ["a1"], projectID: alpha.id, mode: .add, primary: false)
        await model.loadSidebarData()
        #expect(model.sidebarGroups.map { $0.client?.name } == ["Zed", nil])
        #expect(model.sidebarGroups[1].projects.map(\.name) == ["Alpha", "beta"])

        try await model.renameProject(id: beta.id, to: "Aardvark")
        #expect(model.sidebarGroups[1].projects.map(\.name) == ["Aardvark", "Alpha"])

        try await model.moveProject(id: alpha.id, toClient: zed.id)
        #expect(model.sidebarGroups.map { $0.client?.name } == ["Zed", nil])
        #expect(model.sidebarGroups[0].projects.map(\.name) == ["Alpha"])
        #expect(model.sidebarGroups[1].projects.map(\.name) == ["Aardvark"])
        #expect(model.counts.clients[zed.id] == 1)

        try await model.renameClient(id: zed.id, to: "Acme")
        #expect(model.sidebarGroups[0].client?.name == "Acme")

        // The pair: a clash is refused with the creating text and changes nothing.
        await #expect(throws: NameClashError(message: NameClash.project("Alpha"))) {
            try await model.renameProject(id: beta.id, to: "ALPHA")
        }
        #expect(model.sidebarGroups[1].projects.map(\.name) == ["Aardvark"])
    }

    /// R2-6. Deleting the client or project being viewed falls back to All Assets and reloads the grid;
    /// the image stays and shows under Unfiled. Worked by hand: one image, filed in Alpha (client Acme).
    @Test func deletingTheViewedClientOrProjectFallsBackToAllAssets() async throws {
        let (db, model, library) = try await manageRig()
        defer { try? FileManager.default.removeItem(at: library) }
        let acme = try await db.createClient(name: "Acme").client
        let alpha = try await db.createProject(name: "Alpha", clientID: acme.id, description: nil).project
        _ = try await db.fileAssets(assetIDs: ["a1"], projectID: alpha.id, mode: .add, primary: false)
        await model.loadSidebarData()

        model.sourceSelection = .client(acme.id)
        await model.loadAssets()
        #expect(model.assets.map(\.id) == ["a1"])
        let detached = try await model.deleteClient(id: acme.id)
        #expect(detached == 1)
        #expect(model.sourceSelection == .allAssets)
        #expect(model.clients.isEmpty && model.projects.map(\.name) == ["Alpha"] && model.projects[0].clientID == nil)
        #expect(model.assets.map(\.id) == ["a1"])

        model.sourceSelection = .project(alpha.id)
        await model.loadAssets()
        try await model.deleteProject(id: alpha.id)
        #expect(model.sourceSelection == .allAssets)
        #expect(model.projects.isEmpty)
        #expect(model.counts.unfiled == 1 && model.counts.all == 1)
        #expect(model.assets.map(\.id) == ["a1"])

        // The pair: deleting something other than the viewed source leaves the view alone.
        let beta = try await db.createProject(name: "Beta", clientID: nil, description: nil).project
        let gamma = try await db.createProject(name: "Gamma", clientID: nil, description: nil).project
        await model.loadSidebarData()
        model.sourceSelection = .project(beta.id)
        try await model.deleteProject(id: gamma.id)
        #expect(model.sourceSelection == .project(beta.id))
    }

    /// R2-6. A drop adds (other projects kept) or, with the option key, also leaves the project being
    /// viewed and only that one, and the counts follow. Worked by hand: a1 in One. Add to Two: One 1,
    /// Two 1. Viewing One, option-drop on Three: One 0, Two 1 (kept), Three 1. Viewing All Assets,
    /// option-drop on Four is a plain add: Two 1, Three 1, Four 1.
    @Test func droppingImagesOnAProjectAddsAndOptionLeavesOnlyTheViewedProject() async throws {
        let (db, model, library) = try await manageRig()
        defer { try? FileManager.default.removeItem(at: library) }
        let one = try await db.createProject(name: "One", clientID: nil, description: nil).project
        let two = try await db.createProject(name: "Two", clientID: nil, description: nil).project
        let three = try await db.createProject(name: "Three", clientID: nil, description: nil).project
        let four = try await db.createProject(name: "Four", clientID: nil, description: nil).project
        _ = try await db.fileAssets(assetIDs: ["a1"], projectID: one.id, mode: .add, primary: false)
        await model.loadSidebarData()

        try await model.dropImages(["a1"], onto: two.id, move: false)
        #expect(model.counts.projects[one.id] == 1 && model.counts.projects[two.id] == 1)
        model.sourceSelection = .project(one.id)
        try await model.dropImages(["a1"], onto: three.id, move: true)
        #expect((model.counts.projects[one.id] ?? 0) == 0)
        #expect(model.counts.projects[two.id] == 1, "its other project stays")
        #expect(model.counts.projects[three.id] == 1)
        // The pair: the view is not a project, so the option key changes nothing.
        model.sourceSelection = .allAssets
        try await model.dropImages(["a1"], onto: four.id, move: true)
        #expect(model.counts.projects[two.id] == 1 && model.counts.projects[three.id] == 1 && model.counts.projects[four.id] == 1)
    }

    private func addAsset(_ db: AppDatabase, _ id: String, filename: String) async throws {
        try await db.insertAsset(Asset(
            id: id, filename: filename, fileHash: "h\(id)", providerID: "nano_banana", modelID: "m",
            createdAt: "2026-10-01T09:00:00Z"))
    }

    /// R2-6 P2-2. A reload drops selected images that are no longer in the grid, and the inspector
    /// follows. Worked by hand: a1 "a1.png", a2 "b2.png", a3 "a3.png", all in One, all selected.
    /// Search "b2" keeps a2 (the inspector shows it); search "zz" leaves nothing. Hiding a1 and a3
    /// behind the model's back leaves a2. Moving a2 to Two while viewing One leaves a1 and a3.
    @Test func aReloadDropsSelectedImagesThatLeftTheGridAndTheInspectorFollows() async throws {
        let (db, model, library) = try await manageRig()
        defer { try? FileManager.default.removeItem(at: library) }
        try await addAsset(db, "a2", filename: "b2.png")
        try await addAsset(db, "a3", filename: "a3.png")
        let one = try await db.createProject(name: "One", clientID: nil, description: nil).project
        let two = try await db.createProject(name: "Two", clientID: nil, description: nil).project
        _ = try await db.fileAssets(assetIDs: ["a1", "a2", "a3"], projectID: one.id, mode: .add, primary: false)
        await model.loadSidebarData()
        model.sourceSelection = .project(one.id)

        func selectEverything() async {
            await model.loadAssets()
            await model.selectAll(order: model.displayedOrder)
            #expect(model.selectedAssetIDs == ["a1", "a2", "a3"] && model.inspectorDetail == nil)
        }

        // Search.
        await selectEverything()
        model.searchText = "b2"
        await model.loadAssets()
        #expect(model.selectedAssetIDs == ["a2"])
        #expect(model.inspectorDetail?.asset.id == "a2" && model.selectedAssetID == "a2")
        model.searchText = "zz"
        await model.loadAssets()
        #expect(model.selectedAssetIDs.isEmpty && model.inspectorDetail == nil && model.selectedAssetID == nil)
        model.searchText = ""

        // Hide.
        await selectEverything()
        try await db.setHidden(assetIDs: ["a1", "a3"], hidden: true)
        await model.loadAssets()
        #expect(model.selectedAssetIDs == ["a2"] && model.inspectorDetail?.asset.id == "a2")
        try await db.setHidden(assetIDs: ["a1", "a3"], hidden: false)

        // A move out of the viewed project.
        await selectEverything()
        _ = try await db.moveAssets(assetIDs: ["a2"], from: one.id, to: two.id)
        await model.loadAssets()
        #expect(model.selectedAssetIDs == ["a1", "a3"] && model.inspectorDetail == nil)
    }

    /// R2-6 P2-3. A write made through the database, not the view model (as an MCP tool call or another
    /// window does), reaches the sidebar. Worked by hand: a1 filed into Alpha is 1 in Alpha's count;
    /// a client and a project made the same way appear in the groups.
    @Test func aWriteMadeThroughTheDatabaseRefreshesTheSidebarWithoutTheViewModel() async throws {
        let (db, model, library) = try await manageRig()
        defer { try? FileManager.default.removeItem(at: library) }
        let alpha = try await db.createProject(name: "Alpha", clientID: nil, description: nil).project
        await model.loadSidebarData()
        #expect((model.counts.projects[alpha.id] ?? 0) == 0 && model.clients.isEmpty)
        let watching = Task { await model.observeLibraryChanges() }
        defer { watching.cancel() }
        func settles(_ done: () -> Bool) async -> Bool {
            for _ in 0..<100 {
                if done() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }
        try await Task.sleep(for: .milliseconds(300))   // the observation starts on its own task

        _ = try await db.fileAssets(assetIDs: ["a1"], projectID: alpha.id, mode: .add, primary: false)
        #expect(await settles { model.counts.projects[alpha.id] == 1 }, "a filing")
        let client = try await db.createClient(name: "Zed").client
        #expect(await settles { model.clients.map(\.name) == ["Zed"] }, "a client")
        _ = try await db.createProject(name: "Beta", clientID: client.id, description: nil)
        #expect(await settles { model.sidebarGroups.first?.projects.map(\.name) == ["Beta"] }, "a project")
        try await db.deleteProject(id: alpha.id)
        #expect(await settles { model.projects.map(\.name) == ["Beta"] && model.counts.unfiled == 1 }, "a delete")
    }

    /// R2-6 P3-1 and P3-3. The on-screen order is each filmstrip's members then the standalone grid, and
    /// selecting through `selectAsset` (whatever calls it) puts the same image in the Mac selection.
    /// Worked by hand: a1 and a2 are one family (a2 first in the filmstrip), a3 stands alone.
    @Test func theDisplayedOrderIncludesFilmstripMembersAndSelectAssetKeepsTheSelectionInStep() async throws {
        let (db, model, library) = try await manageRig()
        defer { try? FileManager.default.removeItem(at: library) }
        try await addAsset(db, "a2", filename: "b2.png")
        try await addAsset(db, "a3", filename: "a3.png")
        for id in ["a2", "a1"] {
            _ = try await db.attachToVariantFamily(assetID: id, projectID: nil, familyName: "Heroes", prompt: nil, filename: "\(id).png")
        }
        await model.loadSidebarData()
        await model.loadAssets()
        #expect(model.displayedOrder == ["a2", "a1", "a3"])
        await model.selectAll(order: model.displayedOrder)
        #expect(model.selectedAssetIDs == ["a1", "a2", "a3"])

        await model.selectAsset("a3")
        #expect(model.selectedAssetIDs == ["a3"] && model.inspectorDetail?.asset.id == "a3")
        // The pair: a click that already left exactly this image selected keeps its anchor.
        await model.click("a1", .plain, order: model.displayedOrder)
        await model.click("a3", .command, order: model.displayedOrder)
        await model.click("a1", .command, order: model.displayedOrder)
        #expect(model.selection.anchor == "a1" && model.selectedAssetIDs == ["a3"])
    }

    /// R2-6. The Mac click rules drive the selection and the inspector: one image shows in the inspector,
    /// two or more show none, and clearing empties both.
    @Test func macClicksSelectAndTheInspectorFollows() async throws {
        let (db, model, library) = try await manageRig()
        defer { try? FileManager.default.removeItem(at: library) }
        for id in ["a2", "a3"] {
            try await db.insertAsset(Asset(
                id: id, filename: "\(id).png", fileHash: "h\(id)", providerID: "nano_banana", modelID: "m",
                createdAt: "2026-10-01T09:00:00Z"))
        }
        let order = ["a1", "a2", "a3"]
        await model.click("a2", .plain, order: order)
        #expect(model.selectedAssetIDs == ["a2"] && model.inspectorDetail?.asset.id == "a2")
        await model.click("a3", .shift, order: order)
        #expect(model.selectedAssetIDs == ["a2", "a3"] && model.inspectorDetail == nil)
        await model.click("a1", .command, order: order)
        #expect(model.selectedAssetIDs == ["a1", "a2", "a3"])
        await model.click("a2", .command, order: order)
        #expect(model.selectedAssetIDs == ["a1", "a3"])
        await model.clearSelection()
        #expect(model.selectedAssetIDs.isEmpty && model.inspectorDetail == nil)
    }
}
