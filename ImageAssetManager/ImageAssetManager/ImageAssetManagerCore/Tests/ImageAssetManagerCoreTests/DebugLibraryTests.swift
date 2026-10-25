#if DEBUG
import Testing
import Foundation
@testable import ImageAssetManagerCore

// R2-2 fix cycle 1, item 3: the debug-only IAM_LIBRARY override. Every refusal here is a live
// library the override must never open. No test sets DebugLibrary.current: each makes its own
// Session, so the process's real stores are never pointed anywhere.

@Suite("Debug library override")
struct DebugLibraryTests {

    /// A live library (folder with a library.db) and a separate copy beside it, in a fresh temp folder.
    private struct Rig {
        let root: URL, live: URL, copy: URL
        init() throws {
            root = makeTempDirectory()
            live = root.appending(path: "Live", directoryHint: .isDirectory)
            copy = root.appending(path: "Live-copy", directoryHint: .isDirectory)
            for folder in [live, copy] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try Data("live".utf8).write(to: live.appending(path: "library.db"))
            try Data("copy".utf8).write(to: copy.appending(path: "library.db"))
        }
        var protected: [DebugLibrary.Protected] { [.location(what: "the live iCloud library", url: live)] }
        func path(_ url: URL) -> String { url.path(percentEncoded: false) }
    }

    private func overlapRefused(_ thrown: Error?) -> Bool {
        if case .overlapsLive = thrown as? DebugLibrary.Refusal { return true }
        return false
    }

    // MARK: - Reading the request

    @Test func theFolderIsReadFromTheEnvironmentOrEitherArgumentForm() throws {
        #expect(try DebugLibrary.requested(environment: [:], arguments: ["/app"]) == nil)
        #expect(try DebugLibrary.requested(environment: ["IAM_LIBRARY": "/d/lib"], arguments: ["/app"]) == "/d/lib")
        #expect(try DebugLibrary.requested(environment: [:], arguments: ["/app", "IAM_LIBRARY=/d/lib"]) == "/d/lib")
        #expect(try DebugLibrary.requested(environment: [:], arguments: ["/app", "-IAM_LIBRARY", "/d/lib"]) == "/d/lib")
        // The same folder given twice is one request.
        #expect(try DebugLibrary.requested(environment: ["IAM_LIBRARY": "/d/lib"], arguments: ["IAM_LIBRARY=/d/lib"]) == "/d/lib")
        // A lookalike name is not the variable.
        #expect(try DebugLibrary.requested(environment: ["IAM_LIBRARY_X": "/d"], arguments: ["IAM_LIBRARYX=/d"]) == nil)
    }

    @Test func setButEmptyOrTwoDifferentFoldersIsRefusedNeverIgnored() {
        #expect(throws: DebugLibrary.Refusal.empty) { try DebugLibrary.requested(environment: ["IAM_LIBRARY": ""], arguments: []) }
        #expect(throws: DebugLibrary.Refusal.empty) { try DebugLibrary.requested(environment: [:], arguments: ["IAM_LIBRARY=  "]) }
        #expect(throws: DebugLibrary.Refusal.empty) { try DebugLibrary.requested(environment: [:], arguments: ["/app", "-IAM_LIBRARY"]) }
        #expect(throws: DebugLibrary.Refusal.conflicting("/a", "/b")) {
            try DebugLibrary.requested(environment: ["IAM_LIBRARY": "/a"], arguments: ["-IAM_LIBRARY", "/b"])
        }
    }

    // MARK: - Refusing the live library

    @Test func theLiveLibraryItselfIsRefusedAndASeparateCopyIsOpened() throws {
        let rig = try Rig()
        do {
            _ = try DebugLibrary.resolve(rig.path(rig.live), protected: rig.protected)
            Issue.record("the live library was accepted")
        } catch {
            #expect(overlapRefused(error), "\(error)")
        }
        // The pair: the copy beside it (a name that starts the same) is accepted, resolved.
        let opened = try DebugLibrary.resolve(rig.path(rig.copy), protected: rig.protected)
        #expect(opened.path(percentEncoded: false).hasSuffix("/Live-copy/"))
        #expect(opened.path(percentEncoded: false).hasPrefix("/private/"))   // the temp folder's /var resolved
    }

    @Test func aFolderInsideOrAroundTheLiveLibraryIsRefused() throws {
        let rig = try Rig()
        let inside = rig.live.appending(path: "assets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        for folder in [inside, rig.root] {
            #expect(throws: DebugLibrary.Refusal.self) { try DebugLibrary.resolve(rig.path(folder), protected: rig.protected) }
            #expect(overlapRefused(Result { try DebugLibrary.resolve(rig.path(folder), protected: rig.protected) }.failure))
        }
    }

    @Test func aLinkOrAnotherSpellingOfTheLiveLibraryIsRefused() throws {
        let rig = try Rig()
        let link = rig.root.appending(path: "Innocent")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: rig.live)
        let dotted = rig.path(rig.copy) + "/../Live"
        let upper = rig.path(rig.root) + "/LIVE"   // the temp volume ignores case, as APFS does by default
        for spelling in [rig.path(link), dotted, upper] {
            #expect(overlapRefused(Result { try DebugLibrary.resolve(spelling, protected: rig.protected) }.failure), "\(spelling)")
        }
    }

    @Test func aCopyWhoseLibraryDBIsTheLiveFileIsRefused() throws {
        let rig = try Rig()
        let linked = rig.root.appending(path: "Linked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: rig.live.appending(path: "library.db"), to: linked.appending(path: "library.db"))
        #expect(throws: DebugLibrary.Refusal.sameDatabaseFile(live: DebugLibrary.canonicalPath(rig.live), what: "the live iCloud library")) {
            try DebugLibrary.resolve(rig.path(linked), protected: rig.protected)
        }
    }

    @Test func aSavedLocationThatCannotBeReadRefusesTheOverride() throws {
        let rig = try Rig()
        #expect(throws: DebugLibrary.Refusal.unreadable(what: "the saved library location")) {
            try DebugLibrary.resolve(rig.path(rig.copy), protected: [.unreadable(what: "the saved library location")])
        }
        // The pair: a saved location elsewhere does not stand in the copy's way.
        let elsewhere = rig.root.appending(path: "Elsewhere")
        #expect(try DebugLibrary.resolve(rig.path(rig.copy), protected: [.location(what: "saved", url: elsewhere)])
            .lastPathComponent == "Live-copy")
    }

    @Test func aRelativeMissingOrFilePathIsRefused() throws {
        let rig = try Rig()
        #expect(throws: DebugLibrary.Refusal.notAbsolute("Live-copy")) { try DebugLibrary.resolve("Live-copy", protected: []) }
        let missing = rig.path(rig.root) + "/Nope"
        #expect(throws: DebugLibrary.Refusal.notAFolder(missing)) { try DebugLibrary.resolve(missing, protected: []) }
        let file = rig.path(rig.copy) + "/library.db"
        #expect(throws: DebugLibrary.Refusal.notAFolder(file)) { try DebugLibrary.resolve(file, protected: []) }
    }

    @Test func overlapIsByWholeComponentsIgnoringCaseAndNormalisation() {
        #expect(DebugLibrary.overlaps("/a/lib", "/a/lib"))
        #expect(DebugLibrary.overlaps("/a/lib/assets", "/a/lib"))
        #expect(DebugLibrary.overlaps("/a", "/a/lib"))
        #expect(DebugLibrary.overlaps("/A/Lib", "/a/lib"))
        #expect(DebugLibrary.overlaps("/a/\u{00C9}cran", "/a/E\u{0301}cran"))   // É precomposed and decomposed
        // The pairs.
        #expect(!DebugLibrary.overlaps("/a/lib-copy", "/a/lib"))
        #expect(!DebugLibrary.overlaps("/b/lib", "/a/lib"))
    }

    // MARK: - With the override active

    @Test func theCachesFollowTheOverrideLibraryAndOnlyWhenItIsActive() {
        let library = URL(fileURLWithPath: "/d/Copy", isDirectory: true)
        let session = DebugLibrary.Session()
        // Inactive: the container's own folders, as before.
        #expect(CatalogueStore.defaultDirectory(debug: session) == CatalogueStore.defaultDirectory())
        #expect(CatalogueStore.defaultDirectory(debug: session).lastPathComponent == "ImageAssetManagerCatalogue")
        #expect(ThumbnailCache.sharedDirectory(debug: session) == ThumbnailCache.shared.directory)
        session.activate(library)
        #expect(CatalogueStore.defaultDirectory(debug: session).path(percentEncoded: false) == "/d/Copy/DebugCaches/Catalogue/")
        #expect(ThumbnailCache.sharedDirectory(debug: session).path(percentEncoded: false) == "/d/Copy/DebugCaches/Thumbnails/")
        // The first library stands for the process.
        session.activate(URL(fileURLWithPath: "/elsewhere"))
        #expect(session.library == library)
    }

    @Test func theTitleAndTheICloudPathAreTheOnesTheBriefNames() {
        #expect(DebugLibrary.windowTitle(for: URL(fileURLWithPath: "/d/Copy")) == "DEBUG LIBRARY: /d/Copy")
        #expect(DebugLibrary.iCloudContainer(home: URL(fileURLWithPath: "/Users/j", isDirectory: true)).path(percentEncoded: false)
            == "/Users/j/Library/Mobile Documents/iCloud~Ionic~ImageAssetManager/")
    }
}

private extension Result where Failure == Error {
    var failure: Error? { if case .failure(let error) = self { return error } else { return nil } }
}
#endif
