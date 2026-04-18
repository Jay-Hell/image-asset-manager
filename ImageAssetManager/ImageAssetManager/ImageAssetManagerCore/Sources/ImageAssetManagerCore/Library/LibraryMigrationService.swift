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
            return "Source not found: \(path)"
        case .destinationNotWritable(let path):
            return "Cannot write to destination: \(path)"
        case .itemFailed(let name, let message):
            return "Failed to migrate \(name): \(message)"
        }
    }
}

public actor LibraryMigrationService {

    public init() {}

    public func migrate(
        from sourceURL: URL,
        to destinationURL: URL,
        mode: MigrationMode
    ) async throws {
        let fm = FileManager.default
        let sourcePath = sourceURL.path(percentEncoded: false)
        let destPath = destinationURL.path(percentEncoded: false)

        guard fm.fileExists(atPath: sourcePath) else {
            throw MigrationError.sourceNotFound(sourcePath)
        }
        guard fm.isWritableFile(atPath: destPath) else {
            throw MigrationError.destinationNotWritable(destPath)
        }

        let items = ["library.db", "index.json", "assets", "prompts", "providers.json"]

        for item in items {
            let src = sourceURL.appending(path: item)
            guard fm.fileExists(atPath: src.path(percentEncoded: false)) else { continue }
            let dst = destinationURL.appending(path: item)

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
