import Foundation
@testable import ImageAssetManagerCore

/// The repo's published catalogue file, read from the checkout: `catalogue/v1/models.json`
/// at the repo root. This is the file the `catalogue` branch will serve.
enum RepoCatalogue {
    /// <root>/ImageAssetManager/ImageAssetManager/ImageAssetManagerCore/Tests/ImageAssetManagerCoreTests/<this file>
    static let rootURL: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()

    static let fileURL = rootURL.appending(path: "catalogue/v1/models.json")

    static func data() throws -> Data { try Data(contentsOf: fileURL) }

    static func parsed() throws -> Catalogue { try Catalogue.parse(try data()) }

    /// The repo file as a mutable JSON tree, re-serialised after `mutate`.
    static func json(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var root = try JSONSerialization.jsonObject(with: try data()) as! [String: Any]
        mutate(&root)
        return try JSONSerialization.data(withJSONObject: root)
    }

    static func parsed(_ mutate: (inout [String: Any]) -> Void) throws -> Catalogue {
        try Catalogue.parse(try json(mutate))
    }
}

/// Tiny helpers for editing the JSON tree in tests.
func modelList(_ root: [String: Any], provider: String = "nano_banana") -> [[String: Any]] {
    ((root["models"] as! [String: Any])[provider] as! [[String: Any]])
}

func setModelList(_ root: inout [String: Any], _ list: [[String: Any]], provider: String = "nano_banana") {
    var models = root["models"] as! [String: Any]
    models[provider] = list
    root["models"] = models
}

func tierRoutes(_ root: [String: Any], media: String = "image", tier: String) -> [[String: Any]] {
    let m = (root["media"] as! [String: Any])[media] as! [String: Any]
    return ((m["tiers"] as! [String: Any])[tier] as! [[String: Any]])
}

func setTierRoutes(_ root: inout [String: Any], media: String = "image", tier: String, _ routes: [[String: Any]]) {
    var mediaDict = root["media"] as! [String: Any]
    var section = mediaDict[media] as! [String: Any]
    var tiers = section["tiers"] as! [String: Any]
    tiers[tier] = routes
    section["tiers"] = tiers
    mediaDict[media] = section
    root["media"] = mediaDict
}

/// A fresh temporary directory for a store's cache.
func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "iam-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A mutable clock the store can be handed.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}

/// 1×1 PNG, base64-encoded for fake provider responses.
let tinyPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

func geminiSuccessBody(extraParts: [[String: Any]] = [], top: [String: Any] = [:]) -> Data {
    var parts = extraParts
    parts.append(["inlineData": ["mimeType": "image/png", "data": tinyPNGBase64]])
    var payload: [String: Any] = ["candidates": [["content": ["parts": parts]]]]
    for (k, v) in top { payload[k] = v }
    return try! JSONSerialization.data(withJSONObject: payload)
}
