import Foundation

/// A single request handled by the local MCP server, surfaced in Settings so the
/// loopback server's activity is visible in-app (and demonstrable to App Review).
public struct MCPRequestLogEntry: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let method: String
    public let path: String
    /// Tool name for `POST /tool` requests; nil for `/health` and unmatched paths.
    public let tool: String?
    public let ok: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        method: String,
        path: String,
        tool: String? = nil,
        ok: Bool
    ) {
        self.id = id
        self.timestamp = timestamp
        self.method = method
        self.path = path
        self.tool = tool
        self.ok = ok
    }

    /// Human-readable summary for the activity row, e.g. `POST /tool · generate_image`.
    public var summary: String {
        if let tool { return "\(method) \(path) · \(tool)" }
        return "\(method) \(path)"
    }
}

/// A bounded, in-memory log of the most recent MCP requests. Oldest entries are
/// dropped once `capacity` is exceeded; `entries` is ordered oldest-first.
public struct MCPActivityLog: Sendable, Equatable {
    public private(set) var entries: [MCPRequestLogEntry]
    public let capacity: Int

    public init(capacity: Int = 20) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        self.entries = []
    }

    public mutating func record(_ entry: MCPRequestLogEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Most-recent-first, for display.
    public var mostRecent: [MCPRequestLogEntry] {
        entries.reversed()
    }
}
