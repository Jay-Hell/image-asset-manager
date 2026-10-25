import Foundation

/// Owns the app's one MCP server: made and started the first time a window asks, and never again
/// in the same process, however many windows open (Cmd-N, or the Dock after the last one closed).
/// A second server would mint a second token and race the first for the port, and the MCP would be
/// lost until a relaunch (R2-1 finding 4). Generic so a Core test can drive it without the app.
@MainActor
public final class MCPServerOwner<Server: AnyObject & Sendable> {
    /// The server, once a window has asked for it.
    public private(set) var server: Server?

    public init() {}

    /// Makes and starts the server if there is none; otherwise does nothing. Returns whether this
    /// call started it. The server is held before `start` is awaited, so a window that asks while
    /// the first start is still binding finds it and starts nothing.
    @discardableResult
    public func startOnce(make: () -> Server, start: @Sendable (Server) async -> Void) async -> Bool {
        guard server == nil else { return false }
        let made = make()
        server = made
        await start(made)
        return true
    }
}

/// The body of `GET /health`: which copy of the app is answering, so the proxy can check that the
/// app it opened is the one serving (R2-1 finding 1). It has no token and is never given one.
public enum MCPHealth {
    public static func body(bundleURL: URL, info: [String: Any]) -> Data {
        var path = bundleURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let health: [String: String] = [
            "status": "ok",
            "bundle_path": path,
            "version": (info["CFBundleShortVersionString"] as? String) ?? "",
            "build": (info["CFBundleVersion"] as? String) ?? "",
        ]
        return (try? JSONSerialization.data(withJSONObject: health, options: [.sortedKeys])) ?? Data(#"{"status":"ok"}"#.utf8)
    }
}
