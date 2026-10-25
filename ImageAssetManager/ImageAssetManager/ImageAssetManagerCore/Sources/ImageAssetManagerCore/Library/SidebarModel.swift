import GRDB
import Foundation

/// A client and its projects, as the sidebar lists them. `client` is nil for the group of
/// projects that have none.
public struct SidebarGroup: Sendable {
    public let client: Client?
    public let projects: [Project]
}

public enum SidebarGrouping {
    /// Clients by name ignoring case (one with no projects still appears), each with its
    /// projects by name; projects with no client (or a client that no longer exists) last.
    public static func groups(clients: [Client], projects: [Project]) -> [SidebarGroup] {
        func byName<T>(_ items: [T], _ name: (T) -> String) -> [T] {
            items.sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
        }
        let known = Set(clients.map(\.id))
        var result = byName(clients, { $0.name }).map { client in
            SidebarGroup(client: client, projects: byName(projects.filter { $0.clientID == client.id }, { $0.name }))
        }
        let loose = projects.filter { $0.clientID == nil || !known.contains($0.clientID!) }
        if !loose.isEmpty {
            result.append(SidebarGroup(client: nil, projects: byName(loose, { $0.name })))
        }
        return result
    }
}

/// Asset counts for the sidebar. An asset in two projects of one client counts once for the client.
public struct SidebarCounts: Sendable, Equatable {
    public var projects: [String: Int] = [:]
    public var clients: [String: Int] = [:]
    /// Assets with no project.
    public var unfiled: Int = 0
    public var all: Int = 0
}

extension AppDatabase {
    /// Counts for the sidebar. Hidden assets are left out unless `showHidden`, to match the grid.
    public func fetchSidebarCounts(showHidden: Bool = false) async throws -> SidebarCounts {
        let visible = showHidden ? "1 = 1" : "a.is_hidden = 0"
        return try await read { db in
            var counts = SidebarCounts()
            for row in try Row.fetchAll(db, sql: """
                SELECT ap.project_id AS id, COUNT(DISTINCT ap.asset_id) AS n
                FROM asset_projects ap JOIN assets a ON a.id = ap.asset_id
                WHERE \(visible) GROUP BY ap.project_id
                """) {
                counts.projects[row["id"]] = row["n"]
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT p.client_id AS id, COUNT(DISTINCT ap.asset_id) AS n
                FROM asset_projects ap JOIN assets a ON a.id = ap.asset_id
                JOIN projects p ON p.id = ap.project_id
                WHERE p.client_id IS NOT NULL AND \(visible) GROUP BY p.client_id
                """) {
                counts.clients[row["id"]] = row["n"]
            }
            counts.unfiled = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM assets a
                WHERE \(visible) AND a.id NOT IN (SELECT asset_id FROM asset_projects)
                """) ?? 0
            counts.all = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets a WHERE \(visible)") ?? 0
            return counts
        }
    }
}

/// The messages a sidebar or Settings shows when a name is taken, so the two say the same.
public enum NameClash {
    public static func client(_ existing: String) -> String { "A client named \u{201C}\(existing)\u{201D} already exists." }
    public static func project(_ existing: String) -> String { "A project named \u{201C}\(existing)\u{201D} already exists." }
}
