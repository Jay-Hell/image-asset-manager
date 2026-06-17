#if os(macOS)
import Foundation
import Observation
import ImageAssetManagerCore

/// Live state of the local MCP server, surfaced in Settings.
enum MCPServerStatus: Sendable, Equatable {
    case stopped
    case running(port: UInt16)
    case failed(String)
}

/// Owns the lifecycle of the loopback `MCPServer` and exposes observable state for
/// the Settings panel. Making the server user-toggleable and its status/activity
/// visible is what gives the `com.apple.security.network.server` entitlement
/// matching, demonstrable functionality (App Review guideline 2.4.5(i)).
@MainActor
@Observable
final class MCPServerController {
    static let enabledDefaultsKey = "mcpServerEnabled"
    static let port = MCPServer.port

    private(set) var status: MCPServerStatus = .stopped
    private(set) var activity = MCPActivityLog(capacity: 20)

    /// Persisted across launches. Defaults to **on** for a fresh install so the
    /// integration is active out of the box.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledDefaultsKey)
            reconcile()
        }
    }

    private var server: MCPServer?
    private var database: AppDatabase
    private var libraryURL: URL

    init(database: AppDatabase, libraryURL: URL) {
        self.database = database
        self.libraryURL = libraryURL
        if UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.enabledDefaultsKey)
        }
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    /// Called once at app launch.
    func startIfEnabled() {
        if isEnabled { start() }
    }

    /// Re-point the server at a new database/library after a location change.
    func updateBackend(database: AppDatabase, libraryURL: URL) {
        self.database = database
        self.libraryURL = libraryURL
        guard isEnabled, let old = server else { return }
        server = nil
        ImageAssetManagerDelegate.mcpServer = nil
        status = .stopped
        Task {
            await old.stop()
            if isEnabled { start() }   // bind only after the old listener releases the port
        }
    }

    private func reconcile() {
        if isEnabled { start() } else { stop() }
    }

    private func start() {
        guard server == nil else { return }
        let srv = MCPServer(
            database: database,
            libraryURL: libraryURL,
            onStatus: { [weak self] status in
                Task { @MainActor in self?.status = status }
            },
            onRequest: { [weak self] entry in
                Task { @MainActor in self?.activity.record(entry) }
            }
        )
        server = srv
        ImageAssetManagerDelegate.mcpServer = srv   // keep the termination hook in sync
        Task { await srv.start() }
    }

    private func stop() {
        guard let srv = server else { return }
        server = nil
        ImageAssetManagerDelegate.mcpServer = nil
        status = .stopped
        Task { await srv.stop() }
    }
}
#endif
