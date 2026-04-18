import Foundation

public enum MigrationMode: String, Sendable {
    case move
    case copy
}

public enum MigrationError: Error, LocalizedError, Sendable {
    case sourceNotFound(String)
    case destinationNotWritable(String)
    case itemFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let path):
            return "Source library not found at: \(path)"
        case .destinationNotWritable(let path):
            return "Cannot write to destination folder: \(path)"
        case .itemFailed(let name, let message):
            return "Failed to migrate \"\(name)\": \(message)"
        }
    }
}

public actor LibraryMigrationService {

    public init() {}

    /// Migrate all library files from `sourceURL` to `destinationURL`.
    /// Call `AppDatabase.checkpoint()` before invoking this to ensure the WAL is flushed.
    public func migrate(
        from sourceURL: URL,
        to destinationURL: URL,
        mode: MigrationMode
    ) async throws {
        let fm = FileManager.default
        let sourcePath = sourceURL.path(percentEncoded: false)

        guard fm.fileExists(atPath: sourcePath) else {
            throw MigrationError.sourceNotFound(sourcePath)
        }

        // Preflight: verify we can write to the destination by creating and removing a temp file.
        let probe = destinationURL.appending(path: ".iam_probe_\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try fm.removeItem(at: probe)
        } catch {
            throw MigrationError.destinationNotWritable(destinationURL.path(percentEncoded: false))
        }

        // Core library files plus WAL sidecar files that SQLite creates in WAL mode.
        let items = [
            "library.db",
            "library.db-shm",
            "library.db-wal",
            "index.json",
            "providers.json",
            "assets",
            "prompts",
        ]

        for item in items {
            let src = sourceURL.appending(path: item)
            guard fm.fileExists(atPath: src.path(percentEncoded: false)) else { continue }
            let dst = destinationURL.appending(path: item)

            // Remove any existing item at the destination first.
            if fm.fileExists(atPath: dst.path(percentEncoded: false)) {
                try fm.removeItem(at: dst)
            }

            // Use copyItem for both modes — it works reliably across volume boundaries and
            // iCloud Drive (triggers download if needed). For move, delete source after copy.
            do {
                try fm.copyItem(at: src, to: dst)
                if mode == .move {
                    try fm.removeItem(at: src)
                }
            } catch {
                throw MigrationError.itemFailed(item, error.localizedDescription)
            }
        }
    }
}
