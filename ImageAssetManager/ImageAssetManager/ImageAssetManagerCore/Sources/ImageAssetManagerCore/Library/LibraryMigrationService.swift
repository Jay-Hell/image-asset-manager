import Foundation

public enum MigrationMode: String, Sendable {
    case move
    case copy
}

public enum MigrationError: Error, LocalizedError, Sendable {
    case sourceNotFound(String)
    case itemFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let path):
            return "Source library not found at: \(path)"
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

            do {
                switch mode {
                case .move:
                    try fm.moveItem(at: src, to: dst)
                case .copy:
                    try fm.copyItem(at: src, to: dst)
                }
            } catch {
                throw MigrationError.itemFailed(item, error.localizedDescription)
            }
        }
    }
}
