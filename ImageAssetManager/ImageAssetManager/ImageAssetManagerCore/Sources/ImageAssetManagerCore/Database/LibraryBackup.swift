import GRDB
import Foundation

/// Copies of `library.db` taken before a migration runs, in a `Backups/` folder beside it.
///
/// The copy goes through SQLite's online backup API, so it holds every committed page —
/// including those still in `library.db-wal`, which a file copy of `library.db` would miss.
enum LibraryBackup {
    static let folderName = "Backups"
    static let keep = 5

    /// Writes `Backups/library-<UTC timestamp>.db` and returns its URL, then deletes all but the
    /// newest `keep` backups. Throws if the backup cannot be made; the caller must not migrate then.
    @discardableResult
    static func backUp(_ source: any DatabaseReader, databasePath: String, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let folder = URL(filePath: databasePath).deletingLastPathComponent().appending(path: folderName)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let name = "library-\(timestamp(now)).db"
        let finalURL = folder.appending(path: name)
        // Written under a hidden name and renamed when complete, so a half-made backup is
        // never mistaken for a good one (or counted by rotation).
        let partialURL = folder.appending(path: ".\(name).partial")
        sweepPartials(folder: folder)
        defer { sweepPartials(folder: folder) }   // SQLite can leave -shm beside a closed partial
        do {
            let destination = try DatabaseQueue(path: partialURL.path(percentEncoded: false))
            try source.backup(to: destination)
            // One self-contained file: no -wal/-shm beside the backup.
            try destination.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode=DELETE")
            }
            try destination.close()
            try fm.moveItem(at: partialURL, to: finalURL)
        } catch {
            try? fm.removeItem(at: partialURL)
            throw error
        }

        rotate(folder: folder, keeping: name)
        return finalURL
    }

    /// Deletes all but the newest `keep` backups, never `newest` — the one just taken, which a
    /// later-named file (a clock once set ahead, or skew between devices) would otherwise push
    /// out. Only files this type names are touched. Best effort: the new backup already
    /// exists, so a failure here must not block the library.
    static func rotate(folder: URL, keeping newest: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else { return }
        let others = names.filter { $0.hasPrefix("library-") && $0.hasSuffix(".db") && $0 != newest }.sorted()
        for name in others.dropLast(keep - 1) {
            try? fm.removeItem(at: folder.appending(path: name))
        }
    }

    /// Removes hidden partial files (and their SQLite sidecars) left by a backup that never
    /// finished. A complete backup is never named like this.
    static func sweepPartials(folder: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else { return }
        for name in names where name.hasPrefix(".library-") && name.contains(".db.partial") {
            try? fm.removeItem(at: folder.appending(path: name))
        }
    }

    /// Fixed-width UTC, so name order is time order.
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter.string(from: date)
    }
}
