#if DEBUG
import Foundation

/// A development build's way to open a copy of the library, for looking at the screens.
/// DEBUG only: in a Release build none of this exists.
///
/// A development build has the app's bundle ID, so it shares John's container (the saved
/// library location, `mcp-token`, the catalogue cache). `IAM_LIBRARY=<folder>` (environment, or
/// a launch argument `IAM_LIBRARY=<folder>` or `-IAM_LIBRARY <folder>`) opens that folder
/// instead, and is refused if it overlaps the live iCloud library or a saved library location.
/// While it is active the app starts no MCP server, saves no library location, and keeps its
/// caches inside the override library (`catalogueDirectory`, `thumbnailDirectory`).
public enum DebugLibrary {
    public static let variable = "IAM_LIBRARY"
    public static let iCloudContainerID = "iCloud.Ionic.ImageAssetManager"

    public enum Refusal: Error, Equatable, LocalizedError {
        case empty
        case conflicting(String, String)
        case notAbsolute(String)
        case notAFolder(String)
        /// The override and a live location are the same folder, or one is inside the other.
        case overlapsLive(override: String, live: String, what: String)
        /// `library.db` in the override is the live one's file (a hard link).
        case sameDatabaseFile(live: String, what: String)
        /// A saved location exists but cannot be read, so the override cannot be checked against it.
        case unreadable(what: String)
        case locationChangeRefused

        public var errorDescription: String? {
            switch self {
            case .empty: "\(DebugLibrary.variable) is set but empty. Give the folder of a copy of the library."
            case .conflicting(let a, let b): "\(DebugLibrary.variable) is given twice, as \(a) and as \(b). Give it once."
            case .notAbsolute(let p): "\(DebugLibrary.variable) must be an absolute path: \(p)"
            case .notAFolder(let p): "\(DebugLibrary.variable) is not a folder: \(p)"
            case .overlapsLive(let o, let l, let w):
                "Refused: \(DebugLibrary.variable) \(o) overlaps \(w) (\(l)). Use a copy (scripts/dev-library.sh)."
            case .sameDatabaseFile(let l, let w):
                "Refused: library.db in \(DebugLibrary.variable) is the same file as \(w)'s (\(l))."
            case .unreadable(let w): "Refused: \(w) could not be read, so \(DebugLibrary.variable) cannot be checked against it."
            case .locationChangeRefused: "The library location cannot be changed while \(DebugLibrary.variable) is in use."
            }
        }
    }

    /// A place the override must keep clear of.
    public enum Protected: Sendable, Equatable {
        case location(what: String, url: URL)
        case unreadable(what: String)
    }

    // MARK: - Reading the request

    /// The folder asked for, or nil when nothing asks. Set but empty, or given twice with two
    /// values, is a refusal, never a fall-through to the live library.
    public static func requested(environment: [String: String], arguments: [String]) throws -> String? {
        var found: [String] = []
        if let value = environment[variable] { found.append(value) }
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix(variable + "=") {
                found.append(String(argument.dropFirst(variable.count + 1)))
            } else if argument == "-" + variable {
                found.append(index + 1 < arguments.count ? arguments[index + 1] : "")
                index += 1
            }
            index += 1
        }
        guard let first = found.first else { return nil }
        if let other = found.first(where: { $0 != first }) { throw Refusal.conflicting(first, other) }
        guard !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Refusal.empty }
        return first
    }

    /// The override folder, resolved, or a refusal. `protected` is every live location.
    public static func resolve(_ requested: String, protected: [Protected]) throws -> URL {
        guard requested.hasPrefix("/") else { throw Refusal.notAbsolute(requested) }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: requested, isDirectory: &isFolder), isFolder.boolValue else {
            throw Refusal.notAFolder(requested)
        }
        let path = canonicalPath(URL(fileURLWithPath: requested))
        let database = URL(fileURLWithPath: path).appending(path: "library.db")
        for place in protected {
            switch place {
            case .unreadable(let what):
                throw Refusal.unreadable(what: what)
            case .location(let what, let url):
                let live = canonicalPath(url)
                if overlaps(path, live) { throw Refusal.overlapsLive(override: path, live: live, what: what) }
                if let mine = fileIdentity(database), mine == fileIdentity(url.appending(path: "library.db")) {
                    throw Refusal.sameDatabaseFile(live: live, what: what)
                }
            }
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - Paths

    /// Symlinks resolved through the deepest part that exists (`/tmp` is `/private/tmp`), the rest
    /// appended, `.` and `..` removed.
    public static func canonicalPath(_ url: URL) -> String {
        var head = url.standardizedFileURL.path(percentEncoded: false)
        var tail: [String] = []
        while head.count > 1 {
            if let resolved = realpath(head, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return tail.reversed().reduce(base) { ($0 as NSString).appendingPathComponent($1) }
            }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
        return url.standardizedFileURL.path(percentEncoded: false)
    }

    /// True when the two are one folder or one is inside the other, by whole path components,
    /// ignoring case and Unicode normalisation (as APFS does), so `/a/lib-copy` does not overlap `/a/lib`.
    public static func overlaps(_ a: String, _ b: String) -> Bool {
        func parts(_ p: String) -> [String] {
            (p as NSString).pathComponents.filter { $0 != "/" && !$0.isEmpty }
                .map { $0.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil) }
        }
        let x = parts(a), y = parts(b)
        let n = min(x.count, y.count)
        return Array(x.prefix(n)) == Array(y.prefix(n))
    }

    /// The live iCloud container, from the real home folder (a sandboxed process's home is its container).
    public static func iCloudContainer(home: URL) -> URL {
        home.appending(path: "Library/Mobile Documents/iCloud~Ionic~ImageAssetManager", directoryHint: .isDirectory)
    }

    public static func catalogueDirectory(in library: URL) -> URL {
        library.appending(path: "DebugCaches/Catalogue", directoryHint: .isDirectory)
    }

    public static func thumbnailDirectory(in library: URL) -> URL {
        library.appending(path: "DebugCaches/Thumbnails", directoryHint: .isDirectory)
    }

    public static func windowTitle(for library: URL) -> String {
        "DEBUG LIBRARY: \(library.path(percentEncoded: false))"
    }

    private static func fileIdentity(_ url: URL) -> [Int]? {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else { return nil }
        return [Int(info.st_dev), Int(info.st_ino)]
    }

    // MARK: - The running process

    /// Which library, if any, overrides the live one in this process. Set once at launch, before
    /// any shared store is made; tests make their own.
    public final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URL?

        public init() {}

        public var library: URL? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }

        /// The first library set stands for the life of the process.
        public func activate(_ library: URL) {
            lock.lock(); defer { lock.unlock() }
            if stored == nil { stored = library }
        }
    }

    public static let current = Session()
}
#endif
