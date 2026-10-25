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
}
