import Testing
import Foundation
@testable import ImageAssetManagerCore

/// A remote whose answer the test controls, and whose requests it can count.
private final class FakeRemote: @unchecked Sendable {
    private let lock = NSLock()
    private var _status = 200
    private var _body = Data()
    private var _etag: String?
    private var _fail = false
    var stub: StubSession!

    init() {
        stub = StubSession { [unowned self] request in
            self.lock.lock(); defer { self.lock.unlock() }
            if self._fail { throw URLError(.notConnectedToInternet) }
            var headers: [String: String] = [:]
            if let etag = self._etag { headers["ETag"] = etag }
            if self._status == 200, request.headers["if-none-match"] == self._etag, self._etag != nil {
                return (304, Data(), headers)
            }
            return (self._status, self._body, headers)
        }
    }

    func serve(_ data: Data, etag: String? = nil, status: Int = 200) {
        lock.lock(); _body = data; _etag = etag; _status = status; _fail = false; lock.unlock()
    }
    func failNetwork() { lock.lock(); _fail = true; lock.unlock() }
    var requests: [SentRequest] { stub.requests }
}

private func revisionData(_ revision: Int, mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
    try RepoCatalogue.json { root in
        root["revision"] = revision
        mutate(&root)
    }
}

private struct Rig {
    let remote = FakeRemote()
    let directory = makeTempDirectory()
    let clock = TestClock()
    let store: CatalogueStore

    init(bundledRevision: Int = 1, prepare: (URL) throws -> Void = { _ in }) throws {
        try prepare(directory)
        let bundled = try Catalogue.parse(try revisionData(bundledRevision))
        store = CatalogueStore(
            bundled: bundled,
            directory: directory,
            remoteURL: URL(string: "https://example.test/models.json")!,
            session: remote.stub.session,
            build: 0,
            now: { [clock] in clock.now }
        )
    }

    var cacheFile: URL { directory.appending(path: "remote.json") }
}

@Suite("CatalogueStore")
struct CatalogueStoreTests {

    // MARK: - T3: revision ordering

    @Test func t3_aHigherRemoteRevisionIsAdopted() async throws {
        let rig = try Rig()
        #expect(rig.store.status().source == .bundled)

        rig.remote.serve(try revisionData(2))
        let result = await rig.store.refresh()

        #expect(result == .updated(revision: 2))
        #expect(rig.store.status().revision == 2)
        #expect(rig.store.status().source == .remote)
        #expect(rig.store.status().lastFetch == rig.clock.now)
        #expect(FileManager.default.fileExists(atPath: rig.cacheFile.path))
    }

    @Test func t3_aLowerOrEqualRemoteRevisionIsIgnored() async throws {
        let rig = try Rig(bundledRevision: 5)
        for revision in [4, 5] {
            rig.remote.serve(try revisionData(revision))
            let result = await rig.store.refresh()
            #expect(result == .notNewer(revision: revision))
        }
        #expect(rig.store.status().revision == 5)
        #expect(rig.store.status().source == .bundled)
        #expect(!FileManager.default.fileExists(atPath: rig.cacheFile.path))
    }

    @Test func t3_aCacheBelowTheBundledRevisionIsIgnoredAtLaunch() async throws {
        // An old cache left by a previous version must not override a newer bundled file.
        let rig = try Rig(bundledRevision: 5) { dir in
            try revisionData(3).write(to: dir.appending(path: "remote.json"))
        }
        #expect(rig.store.status().revision == 5)
        #expect(rig.store.status().source == .bundled)
    }

    @Test func t3_aCacheAboveTheBundledRevisionIsUsedAtLaunch() async throws {
        let rig = try Rig(bundledRevision: 1) { dir in
            try revisionData(7).write(to: dir.appending(path: "remote.json"))
        }
        #expect(rig.store.status().revision == 7)
        #expect(rig.store.status().source == .remote)
    }

    // MARK: - T4: a failed fetch changes nothing

    @Test func t4_aFailedFetchLeavesTheCacheFileUntouched() async throws {
        let rig = try Rig()
        rig.remote.serve(try revisionData(2))
        await rig.store.refresh()
        let before = try Data(contentsOf: rig.cacheFile)
        let modified = try FileManager.default.attributesOfItem(atPath: rig.cacheFile.path)[.modificationDate] as? Date

        // Each failure mode in turn: server error, 404, network down, invalid file, a file
        // that is valid JSON but a schema this build does not know, and one over the size bound.
        let failures: [() throws -> Void] = [
            { rig.remote.serve(Data(), status: 500) },
            { rig.remote.serve(Data(), status: 404) },
            { rig.remote.failNetwork() },
            { rig.remote.serve(Data("{ nope".utf8)) },
            { rig.remote.serve(try revisionData(9) { $0["schemaVersion"] = 2 }) },
            { rig.remote.serve(Data(count: Catalogue.maxFileBytes + 1)) },
        ]
        for fail in failures {
            try fail()
            let result = await rig.store.refresh()
            guard case .failed = result else {
                Issue.record("expected a failure, got \(result)")
                continue
            }
            #expect(rig.store.status().lastError != nil)
            #expect(rig.store.status().revision == 2)
            #expect(try Data(contentsOf: rig.cacheFile) == before)
        }
        let modifiedAfter = try FileManager.default.attributesOfItem(atPath: rig.cacheFile.path)[.modificationDate] as? Date
        #expect(modifiedAfter == modified)

        // The pair: a good fetch afterwards clears the error and does change the cache.
        rig.remote.serve(try revisionData(3))
        #expect(await rig.store.refresh() == .updated(revision: 3))
        #expect(rig.store.status().lastError == nil)
        #expect(try Data(contentsOf: rig.cacheFile) != before)
    }

    @Test func t4_aFailureWithNoCacheDoesNotCreateOne() async throws {
        let rig = try Rig()
        rig.remote.serve(Data(), status: 503)
        await rig.store.refresh()
        #expect(!FileManager.default.fileExists(atPath: rig.cacheFile.path))
        #expect(rig.store.status().source == .bundled)
    }

    // MARK: - ETag, timers, forced refresh

    @Test func theSecondFetchIsConditionalOnTheETag() async throws {
        let rig = try Rig()
        rig.remote.serve(try revisionData(2), etag: "\"abc\"")
        await rig.store.refresh()
        #expect(rig.remote.requests[0].headers["if-none-match"] == nil)

        let again = await rig.store.refresh()
        #expect(again == .notModified)
        #expect(rig.remote.requests[1].headers["if-none-match"] == "\"abc\"")
        #expect(rig.store.status().revision == 2)
    }

    @Test func theFetchGoesToTheCompiledRemoteURL() {
        // The URL named in the brief, typed out rather than read back from the constant.
        #expect(CatalogueStore.remoteURL.absoluteString ==
            "https://raw.githubusercontent.com/Jay-Hell/image-asset-manager/catalogue/catalogue/v1/models.json")
    }

    @Test func aRefreshSendsAGetToTheStoresRemoteURL() async throws {
        let rig = try Rig()
        rig.remote.serve(try revisionData(1))
        await rig.store.refresh()
        #expect(rig.remote.requests.count == 1)
        #expect(rig.remote.requests[0].method == "GET")
        #expect(rig.remote.requests[0].url.absoluteString == "https://example.test/models.json")
    }

    @Test func refreshRunsAtLaunchAndTheIntervalIsTwentyFourHours() async throws {
        #expect(CatalogueStore.refreshInterval == 24 * 60 * 60)

        let rig = try Rig()
        rig.remote.serve(try revisionData(2))
        rig.store.start()
        defer { rig.store.stop() }
        var waited = 0
        while rig.store.status().revision != 2 && waited < 200 {
            try await Task.sleep(for: .milliseconds(25))
            waited += 1
        }
        #expect(rig.store.status().revision == 2)
        #expect(rig.remote.requests.count == 1)   // the loop is now asleep for 24 hours
    }

    @Test func aModelUnavailableErrorForcesOneRefreshAMinuteAtMost() async throws {
        let rig = try Rig()
        rig.remote.serve(try revisionData(2))

        let first = await rig.store.refreshAfterModelUnavailable()
        #expect(first == .updated(revision: 2))
        #expect(rig.remote.requests.count == 1)

        // Within the window: no second fetch.
        rig.clock.advance(59)
        #expect(await rig.store.refreshAfterModelUnavailable() == nil)
        #expect(rig.remote.requests.count == 1)

        // The pair: once the minute has passed, it fetches again.
        rig.clock.advance(2)
        #expect(await rig.store.refreshAfterModelUnavailable() != nil)
        #expect(rig.remote.requests.count == 2)
    }

    // MARK: - Override

    @Test func aLocalOverrideWinsAndShowsAsOverride() throws {
        let rig = try Rig(bundledRevision: 9)
        // Lower revision than the bundled one: an override ignores revision.
        try rig.store.loadOverride(try revisionData(2))
        #expect(rig.store.status().source == .override)
        #expect(rig.store.status().revision == 2)

        rig.store.clearOverride()
        #expect(rig.store.status().source == .bundled)
        #expect(rig.store.status().revision == 9)
    }

    @Test func anInvalidOverrideChangesNothing() throws {
        let rig = try Rig()
        #expect(throws: Catalogue.ParseError.self) {
            try rig.store.loadOverride(Data("{}".utf8))
        }
        #expect(rig.store.status().source == .bundled)
        #expect(!FileManager.default.fileExists(atPath: rig.directory.appending(path: "override.json").path))
    }

    @Test func anOverrideSurvivesARelaunchAndOutranksTheRemote() async throws {
        let rig = try Rig()
        try rig.store.loadOverride(try revisionData(4))

        let relaunched = CatalogueStore(
            bundled: try Catalogue.parse(try revisionData(1)), directory: rig.directory,
            remoteURL: URL(string: "https://example.test/models.json")!, session: rig.remote.stub.session, build: 0
        )
        #expect(relaunched.status().source == .override)

        rig.remote.serve(try revisionData(8))
        await relaunched.refresh()
        #expect(relaunched.status().source == .override)   // the remote is cached underneath, not in force
        #expect(relaunched.status().revision == 4)
        relaunched.clearOverride()
        #expect(relaunched.status().source == .remote)
        #expect(relaunched.status().revision == 8)
    }

    // MARK: - Where the cache lives

    @Test func theDefaultCacheIsInApplicationSupportOutsideTheLibraryFolder() {
        let dir = CatalogueStore.defaultDirectory()
        #expect(dir.path.contains("Application Support"))
        // The library's own fallback is Application Support/ImageAssetManager; never share it.
        #expect(dir.lastPathComponent == "ImageAssetManagerCatalogue")
    }

    // MARK: - Accessors the UI and assets rely on

    @Test func retiredModelsKeepTheirNamesAndProjectDefaultsMove() throws {
        let rig = try Rig()
        #expect(rig.store.displayName(forModelID: "imagen-4.0-ultra-generate-001") == "Pro — Final (Imagen 4)")
        #expect(rig.store.displayName(forModelID: "unknown-id-here") == "unknown-id-here")
        #expect(rig.store.liveModelID(for: "imagen-4.0-ultra-generate-001") == "gemini-3-pro-image")
        #expect(rig.store.liveModelID(for: "gemini-3-pro-image") == "gemini-3-pro-image")
    }

    @Test func refinementFallsBackToTheBundledEntryWhenTheLiveFileHasNone() async throws {
        let rig = try Rig()
        rig.remote.serve(try revisionData(2) { $0["refinement"] = ["api": "anthropic.future", "model": "claude-x-aa"] })
        await rig.store.refresh()
        #expect(rig.store.snapshot().refinement == nil)
        #expect(rig.store.refinement()?.model == "claude-sonnet-5-5")
    }
}
