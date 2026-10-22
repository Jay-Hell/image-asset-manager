import Foundation

public enum CatalogueSource: String, Sendable, Equatable {
    case bundled
    case remote
    case override
}

public struct CatalogueStatus: Sendable, Equatable {
    public let revision: Int
    public let source: CatalogueSource
    public let lastFetch: Date?
    public let lastError: String?
}

public enum CatalogueRefreshResult: Sendable, Equatable {
    /// A higher revision was fetched, validated and adopted.
    case updated(revision: Int)
    /// 304: the server's copy is the one already cached.
    case notModified
    /// A valid file, but not newer than what is held.
    case notNewer(revision: Int)
    /// Nothing changed; the message is also shown in Settings.
    case failed(String)
}

/// Holds the live catalogue and decides which source wins (spec v0.1 §4.3, §4.4).
///
/// Precedence: a local override if one is loaded; otherwise whichever of the
/// remote cache and the bundled file has the higher `revision`. The remote
/// cache lives in Application Support, never in the synced library.
///
/// A failed fetch changes nothing and is never cached.
public final class CatalogueStore: @unchecked Sendable {

    /// Compiled in: a catalogue can never redirect where the app fetches it from.
    public static let remoteURL = URL(string:
        "https://raw.githubusercontent.com/Jay-Hell/image-asset-manager/catalogue/catalogue/v1/models.json")!

    public static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// A model-unavailable error forces at most one refresh in this window.
    public static let forcedRefreshWindow: TimeInterval = 60

    public static let shared = CatalogueStore(configuredProviders: CatalogueStore.providersWithKeys)

    /// Providers that have a key on this install. Reads the Keychain; tests inject their own.
    @Sendable public static func providersWithKeys() -> Set<String> {
        var found: Set<String> = []
        if (try? KeychainService.retrieve(service: NanaBananaProvider.keychainService, account: NanaBananaProvider.keychainAccount)) != nil {
            found.insert("nano_banana")
        }
        if OpenRouterProvider.hasKey() { found.insert(OpenRouterProvider.id) }
        return found
    }

    // MARK: - State

    private let lock = NSLock()
    private let bundled: Catalogue
    private var remote: Catalogue?
    private var override: Catalogue?
    private var etag: String?
    private var lastFetch: Date?
    private var lastError: String?
    private var lastForcedRefresh: Date?
    private var loopTask: Task<Void, Never>?

    private let directory: URL
    private let remoteURL: URL
    private let session: URLSession
    private let build: Int
    private let now: @Sendable () -> Date
    /// Nil means no key check (tests). Empty means a fresh install with no key at all, where
    /// nothing is usable whatever the file says, so the file is judged on its own terms.
    private let configuredProviders: (@Sendable () -> Set<String>)?

    private struct Meta: Codable {
        var etag: String?
        var lastFetch: Date?
    }

    // MARK: - Init

    public init(
        bundled: Catalogue? = nil,
        directory: URL? = nil,
        remoteURL: URL = CatalogueStore.remoteURL,
        session: URLSession = .shared,
        build: Int = CatalogueStore.runningBuild,
        now: @escaping @Sendable () -> Date = { Date() },
        configuredProviders: (@Sendable () -> Set<String>)? = nil
    ) {
        self.configuredProviders = configuredProviders
        self.bundled = bundled ?? Catalogue.bundledCopy(build: build)
        self.directory = directory ?? CatalogueStore.defaultDirectory()
        self.remoteURL = remoteURL
        self.session = session
        self.build = build
        self.now = now
        loadFromDisk()
    }

    /// `CFBundleVersion` as a whole number; 0 where there is none (tests).
    public static var runningBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    /// Application Support, in its own folder: the library's fallback location is
    /// `Application Support/ImageAssetManager`, and the cache must never sit in a library.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "ImageAssetManagerCatalogue", directoryHint: .isDirectory)
    }

    private var remoteFile: URL { directory.appending(path: "remote.json") }
    private var metaFile: URL { directory.appending(path: "meta.json") }
    private var overrideFile: URL { directory.appending(path: "override.json") }

    private func loadFromDisk() {
        if let data = try? Data(contentsOf: remoteFile), let parsed = try? Catalogue.parse(data, build: build) {
            remote = parsed
            if let metaData = try? Data(contentsOf: metaFile) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let meta = try? decoder.decode(Meta.self, from: metaData) {
                    etag = meta.etag
                    lastFetch = meta.lastFetch
                }
            }
        }
        if let data = try? Data(contentsOf: overrideFile), let parsed = try? Catalogue.parse(data, build: build) {
            override = parsed
        }
    }

    // MARK: - Reading

    private func resolveCurrent() -> (Catalogue, CatalogueSource) {
        if let override { return (override, .override) }
        if let remote, remote.revision > bundled.revision { return (remote, .remote) }
        return (bundled, .bundled)
    }

    /// The catalogue in force right now.
    public func snapshot() -> Catalogue {
        lock.lock(); defer { lock.unlock() }
        return resolveCurrent().0
    }

    public func status() -> CatalogueStatus {
        lock.lock(); defer { lock.unlock() }
        let (cat, source) = resolveCurrent()
        return CatalogueStatus(revision: cat.revision, source: source, lastFetch: lastFetch, lastError: lastError)
    }

    /// Refinement settings: the live catalogue's, or the bundled one if the live
    /// file dropped or could not use its refinement entry.
    public func refinement() -> Catalogue.Refinement? {
        let cat = snapshot()
        return cat.refinement ?? bundled.refinement
    }

    /// Display name for a model ID stored on an asset, including retired models.
    public func displayName(forModelID id: String) -> String {
        snapshot().displayName(forModelID: id) ?? id
    }

    /// A project default pointing at a retired model resolves to its replacement.
    public func liveModelID(for id: String) -> String {
        snapshot().replacement(for: id) ?? id
    }

    // MARK: - Override

    /// Validate a file chosen by the user and make it the active catalogue until cleared.
    /// Nothing is changed if it does not validate.
    public func loadOverride(_ data: Data) throws {
        let parsed = try Catalogue.parse(data, build: build)
        try checkUsable(parsed)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: overrideFile, options: .atomic)
        lock.lock(); override = parsed; lock.unlock()
    }

    public func clearOverride() {
        try? FileManager.default.removeItem(at: overrideFile)
        lock.lock(); override = nil; lock.unlock()
    }

    // MARK: - Refresh

    /// Fetch the remote catalogue (conditional on the ETag). Never throws; the
    /// outcome is returned and, on failure, kept for Settings.
    @discardableResult
    public func refresh() async -> CatalogueRefreshResult {
        var request = URLRequest(url: remoteURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let sendETag = locked { remote != nil ? etag : nil }
        if let sendETag { request.setValue(sendETag, forHTTPHeaderField: "If-None-Match") }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return fail("No HTTP response") }
            switch http.statusCode {
            case 304:
                locked { lastFetch = now(); lastError = nil }
                persistMeta()
                return .notModified
            case 200:
                return adopt(data, etag: http.value(forHTTPHeaderField: "ETag"))
            default:
                return fail("Catalogue server answered HTTP \(http.statusCode)")
            }
        } catch {
            return fail(error.localizedDescription)
        }
    }

    /// For a 404 on a model: one forced refresh, at most once a minute. Returns nil
    /// when the window has not elapsed and no fetch was made.
    @discardableResult
    public func refreshAfterModelUnavailable() async -> CatalogueRefreshResult? {
        let allowed: Bool = locked {
            if let last = lastForcedRefresh, now().timeIntervalSince(last) < Self.forcedRefreshWindow {
                return false
            }
            lastForcedRefresh = now()
            return true
        }
        guard allowed else { return nil }
        return await refresh()
    }

    private func checkUsable(_ catalogue: Catalogue) throws {
        guard let keys = configuredProviders?(), !keys.isEmpty else { return }
        try catalogue.requireUsable(withKeysFor: keys)
    }

    /// A key was added or removed in Settings: fetch the catalogue now, outside the 24 h cadence
    /// and the forced-refresh window, since the set of usable files has just changed.
    @discardableResult
    public func refreshAfterKeyChange() async -> CatalogueRefreshResult {
        await refresh()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func fail(_ message: String) -> CatalogueRefreshResult {
        lock.lock(); lastError = message; lock.unlock()
        return .failed(message)
    }

    private func adopt(_ data: Data, etag newETag: String?) -> CatalogueRefreshResult {
        let parsed: Catalogue
        do {
            parsed = try Catalogue.parse(data, build: build)
            try checkUsable(parsed)
        } catch {
            return fail("Fetched catalogue rejected: \(error.localizedDescription)")
        }
        lock.lock()
        let held = max(bundled.revision, remote?.revision ?? 0)
        lock.unlock()
        guard parsed.revision > held else {
            lock.lock(); lastFetch = now(); lastError = nil; lock.unlock()
            return .notNewer(revision: parsed.revision)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: remoteFile, options: .atomic)
        } catch {
            return fail("Could not cache the catalogue: \(error.localizedDescription)")
        }
        lock.lock()
        remote = parsed
        etag = newETag
        lastFetch = now()
        lastError = nil
        lock.unlock()
        persistMeta()
        return .updated(revision: parsed.revision)
    }

    private func persistMeta() {
        lock.lock()
        let meta = Meta(etag: etag, lastFetch: lastFetch)
        let hasRemote = remote != nil
        lock.unlock()
        guard hasRemote else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(meta) {
            try? data.write(to: metaFile, options: .atomic)
        }
    }

    // MARK: - Timer

    /// Refresh now, then every 24 hours while the app runs. Idempotent.
    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
            }
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        loopTask?.cancel()
        loopTask = nil
    }
}

/// A key was added or removed in Settings: the providers this install can use have changed, so
/// fetch the catalogue and the OpenRouter list now rather than at the next scheduled time.
public enum ProviderKeyChange {
    public static func refresh(catalogue: CatalogueStore = .shared, live: OpenRouterModelStore = .shared) async {
        await catalogue.refreshAfterKeyChange()
        await live.refresh()
    }
}

extension Catalogue {
    /// The catalogue shipped inside the app. A failure here is a build defect, not
    /// a runtime condition: a test parses the same file.
    public static func bundledCopy(build: Int = 0) -> Catalogue {
        guard let url = Bundle.module.url(forResource: "models", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalogue = try? Catalogue.parse(data, build: build) else {
            fatalError("Bundled catalogue models.json is missing or invalid")
        }
        return catalogue
    }
}
