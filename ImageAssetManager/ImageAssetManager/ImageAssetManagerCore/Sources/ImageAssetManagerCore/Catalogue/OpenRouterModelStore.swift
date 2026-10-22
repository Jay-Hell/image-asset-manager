import Foundation

public enum OpenRouterRefreshResult: Sendable, Equatable {
    case updated(count: Int)
    /// Nothing changed; the message is also shown in Settings.
    case failed(String)
}

/// Holds OpenRouter's live image-model list (spec v0.3 §5.2), fetched at launch and every
/// 24 hours, cached beside the catalogue cache. Same rules as the catalogue: a failed
/// fetch never replaces a good cache and is never cached.
///
/// The host is compiled in. Prices learnt from `/endpoints` records or from real costs are
/// kept with the list, because the resolver needs them synchronously.
public final class OpenRouterModelStore: @unchecked Sendable {

    public static let apiBase = "https://openrouter.ai/api/v1"
    public static let listURL = URL(string: "\(apiBase)/images/models")!
    public static let refreshInterval: TimeInterval = 24 * 60 * 60
    public static let forcedRefreshWindow: TimeInterval = 60

    public static let shared = OpenRouterModelStore()

    private let lock = NSLock()
    private var current: OpenRouterModels
    private var lastFetch: Date?
    private var lastError: String?
    private var lastForcedRefresh: Date?
    private var loopTask: Task<Void, Never>?

    private let directory: URL
    private let listURL: URL
    private let apiBase: String
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        directory: URL? = nil,
        apiBase: String = OpenRouterModelStore.apiBase,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory ?? CatalogueStore.defaultDirectory()
        self.apiBase = apiBase
        self.listURL = URL(string: "\(apiBase)/images/models")!
        self.session = session
        self.now = now
        var loaded = OpenRouterModels.empty
        let prices = Self.readPrices(self.directory.appending(path: "openrouter-prices.json"))
        if let data = try? Data(contentsOf: self.directory.appending(path: "openrouter-models.json")),
           let parsed = try? OpenRouterModels.parse(data, prices: prices) {
            loaded = parsed
        }
        current = loaded
        // Prices outlive the list: a model that drops off and returns keeps what was learnt.
        if loaded.isEmpty { current = OpenRouterModels(models: [], prices: prices) }
    }

    private var listFile: URL { directory.appending(path: "openrouter-models.json") }
    private var priceFile: URL { directory.appending(path: "openrouter-prices.json") }

    private static func readPrices(_ url: URL) -> [String: OpenRouterPrice] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: OpenRouterPrice].self, from: data) else { return [:] }
        // A file written before prices were keyed by size holds bare model IDs: those are model-level.
        return Dictionary(decoded.map { ($0.key.contains("|") ? $0.key : OpenRouterPrice.key(model: $0.key, size: nil), $0.value) },
                          uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Reading

    public func snapshot() -> OpenRouterModels {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func status() -> (count: Int, lastFetch: Date?, lastError: String?) {
        lock.lock(); defer { lock.unlock() }
        return (current.models.count, lastFetch, lastError)
    }

    // MARK: - Refresh

    @discardableResult
    public func refresh() async -> OpenRouterRefreshResult {
        var request = URLRequest(url: listURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return fail("No HTTP response") }
            guard http.statusCode == 200 else { return fail("OpenRouter answered HTTP \(http.statusCode)") }
            let prices = locked { current.prices }
            let parsed: OpenRouterModels
            do { parsed = try OpenRouterModels.parse(data, prices: prices) }
            catch { return fail("OpenRouter model list rejected: \(error.localizedDescription)") }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: listFile, options: .atomic)
            } catch {
                return fail("Could not cache the OpenRouter model list: \(error.localizedDescription)")
            }
            locked { current = parsed; lastFetch = now(); lastError = nil }
            return .updated(count: parsed.models.count)
        } catch {
            return fail(error.localizedDescription)
        }
    }

    /// For a 404 on a model: one forced refresh, at most once a minute. Nil when the window has not elapsed.
    @discardableResult
    public func refreshAfterModelUnavailable() async -> OpenRouterRefreshResult? {
        let allowed: Bool = locked {
            if let last = lastForcedRefresh, now().timeIntervalSince(last) < Self.forcedRefreshWindow { return false }
            lastForcedRefresh = now()
            return true
        }
        guard allowed else { return nil }
        return await refresh()
    }

    // MARK: - Prices

    /// Fetch `/images/models/{id}/endpoints` and keep a per-image price if the record has one.
    /// The path is built here from a checked ID, never taken from the list's own `endpoints` field.
    @discardableResult
    public func loadPrice(for modelID: String) async -> OpenRouterPrice? {
        guard Catalogue.isValidModelID(modelID, allowSlash: true),
              let url = URL(string: "\(apiBase)/images/models/\(modelID)/endpoints") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let usd = OpenRouterModels.perImageUSD(fromEndpoints: data) else { return nil }
        // An observed cost is better evidence than a listing: do not overwrite it.
        if let held = snapshot().prices[OpenRouterPrice.key(model: modelID, size: nil)],
           held.source == EstimateSource.observedCost.rawValue { return held }
        let price = OpenRouterPrice(usdPerImage: usd, source: EstimateSource.endpointPricing.rawValue)
        setPrice(price, for: modelID, size: nil)
        return price
    }

    /// The first real `usage.cost` for a model at a size replaces an unknown price; later ones
    /// update it. It is kept for that size only, and never below `OpenRouterPrice.minimumUSDPerImage`.
    public func recordObservedCost(usd: Decimal, for modelID: String, size: String? = nil) {
        guard usd > 0 else { return }
        setPrice(OpenRouterPrice(usdPerImage: usd, source: EstimateSource.observedCost.rawValue), for: modelID, size: size)
    }

    private func setPrice(_ price: OpenRouterPrice, for modelID: String, size: String?) {
        let prices: [String: OpenRouterPrice] = locked {
            var p = current.prices
            p[OpenRouterPrice.key(model: modelID, size: size)] = price
            current = OpenRouterModels(models: current.models, prices: p)
            return p
        }
        if let data = try? JSONEncoder().encode(prices) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: priceFile, options: .atomic)
        }
    }

    // MARK: - Timer

    /// After a failed fetch with no list held: retry after 1 min, 5 min, 30 min, then the 24 h cadence.
    public static let retryDelays: [TimeInterval] = [60, 5 * 60, 30 * 60]

    /// The wait before the next scheduled fetch. `failures` counts consecutive failed fetches.
    /// With a list held (or after a success) the cadence is the 24 h interval.
    public static func delay(afterFailures failures: Int, hasList: Bool) -> TimeInterval {
        guard !hasList, failures > 0, failures <= retryDelays.count else { return refreshInterval }
        return retryDelays[failures - 1]
    }

    public func start() { start(sleep: { try? await Task.sleep(for: .seconds($0)) }) }

    /// `sleep` is injectable so a test can run the schedule without waiting.
    func start(sleep: @escaping @Sendable (TimeInterval) async -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                if case .failed = await self.refresh() { failures += 1 } else { failures = 0 }
                let wait = Self.delay(afterFailures: failures, hasList: !self.snapshot().isEmpty)
                await sleep(wait)
            }
        }
    }

    /// A request needs an OpenRouter route and no list is cached: fetch now rather than wait for
    /// the schedule. Rate-limited to one a minute, like the 404 refresh. Nil when a list is held
    /// or the window has not elapsed.
    @discardableResult
    public func refreshIfNotLoaded() async -> OpenRouterRefreshResult? {
        guard snapshot().isEmpty else { return nil }
        return await refreshAfterModelUnavailable()
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        loopTask?.cancel()
        loopTask = nil
    }

    // MARK: - Helpers

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func fail(_ message: String) -> OpenRouterRefreshResult {
        locked { lastError = message }
        return .failed(message)
    }
}
