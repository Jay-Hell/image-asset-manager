import Foundation
import Network

/// The MCP server's bearer token: minted per server start, held in memory, and published to the
/// `mcp-token` file for the Node proxy only once the listener is accepting connections.
///
/// The order matters (release 1.2, the 23 Oct 401). A token written before the port is bound lets a
/// second instance — an app-test host, an Xcode run, a second copy — overwrite the shared file, fail
/// to bind, and leave the running app refusing every call. Published on `.ready`, a second instance
/// that cannot bind never touches the file. A test host never publishes at all.
public final class MCPTokenPublisher: @unchecked Sendable {
    public let token: String
    private let write: @Sendable (String) throws -> Void
    private let lock = NSLock()
    private var published = false

    /// Nil in a test host (`TestHostIsolation`): it has no business serving MCP or writing the token.
    public init?(
        token: String = MCPTokenPublisher.mint(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        write: @escaping @Sendable (String) throws -> Void
    ) {
        guard !TestHostIsolation.isTestHost(environment: environment) else { return nil }
        self.token = token
        self.write = write
    }

    /// 32 random bytes as 64 hex characters.
    public static func mint() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    /// Call from the listener's `stateUpdateHandler`. Writes the token on the first `.ready` and
    /// returns true then; any other state, or a later `.ready`, writes nothing.
    @discardableResult
    public func listenerStateChanged(_ state: NWListener.State) throws -> Bool {
        guard case .ready = state else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard !published else { return false }
        try write(token)
        published = true
        return true
    }

    /// Write the token file 0600, atomically, creating its folder.
    public static func writeTokenFile(_ token: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(token.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
    }
}

/// The bearer check on `/tool`, and what may be logged about a refusal.
public enum MCPAuth {
    public enum Outcome: Equatable, Sendable {
        case accepted
        /// No `Authorization: Bearer …` header, or an empty one.
        case missing
        /// A token, but not this server's. `length` is all that is said about it.
        case mismatch(length: Int)
        /// The server has no token (it never started properly).
        case serverHasNoToken
    }

    public static func check(authorization: String?, expected: String) -> Outcome {
        let supplied = (authorization ?? "")
            .replacingOccurrences(of: "Bearer ", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !expected.isEmpty else { return .serverHasNoToken }
        guard !supplied.isEmpty else { return .missing }
        return constantTimeEquals(supplied, expected) ? .accepted : .mismatch(length: supplied.count)
    }

    /// The line logged for a refusal. It never contains either token, only why and how long.
    public static func refusalMessage(_ outcome: Outcome) -> String? {
        switch outcome {
        case .accepted: return nil
        case .missing: return "Refused an MCP call: no bearer token"
        case .mismatch(let length):
            return "Refused an MCP call: the bearer token (\(length) characters) is not this server's. The proxy may hold a token another instance wrote."
        case .serverHasNoToken: return "Refused an MCP call: this server has no token"
        }
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}
