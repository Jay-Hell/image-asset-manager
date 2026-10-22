import Foundation

public enum ImportNaming: String, CaseIterable, Sendable {
    case preserveOriginal = "Original Name"
    case prependDate      = "Prepend Date"
    case dateAndIndex     = "Date + Index"
}

extension ImportNaming {
    /// Derive a unique stored filename for one file in an import batch.
    ///
    /// - Parameters:
    ///   - originalURL: The source URL being imported.
    ///   - ext: Lowercase file extension (without dot).
    ///   - dateStr: Pre-formatted date string, e.g. "2026-Apr-18".
    ///   - batchIndex: 1-based position of this file within the current batch (used for Date+Index).
    ///   - usedFilenames: Set of filenames already taken; updated in-place as names are allocated.
    public func filename(
        for originalURL: URL,
        ext: String,
        dateStr: String,
        batchIndex: Int,
        usedFilenames: inout Set<String>
    ) -> String {
        switch self {
        case .preserveOriginal:
            let stem = originalURL.deletingPathExtension().lastPathComponent
            return allocate(base: stem, ext: ext, usedFilenames: &usedFilenames)

        case .prependDate:
            let stem = originalURL.deletingPathExtension().lastPathComponent
            return allocate(base: "\(dateStr)_\(stem)", ext: ext, usedFilenames: &usedFilenames)

        case .dateAndIndex:
            var idx = batchIndex
            while true {
                let candidate = String(format: "\(dateStr)_%03d.\(ext)", idx)
                if !usedFilenames.contains(candidate) {
                    usedFilenames.insert(candidate)
                    return candidate
                }
                idx += 1
            }
        }
    }

    private func allocate(base: String, ext: String, usedFilenames: inout Set<String>) -> String {
        var candidate = "\(base).\(ext)"
        var n = 1
        while usedFilenames.contains(candidate) {
            candidate = "\(base)_\(n).\(ext)"
            n += 1
        }
        usedFilenames.insert(candidate)
        return candidate
    }
}
