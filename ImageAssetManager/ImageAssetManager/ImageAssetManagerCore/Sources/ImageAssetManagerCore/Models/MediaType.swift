import Foundation

/// What an asset is, as far as display and export care. Derived from `MediaType`, never stored.
public enum MediaKind: String, Sendable {
    case image
    case vector
}

/// The MIME type of an asset's file, as stored in `assets.media_type` (migration v8).
public enum MediaType: String, Sendable, CaseIterable {
    case png = "image/png"
    case jpeg = "image/jpeg"
    case webp = "image/webp"
    case heic = "image/heic"
    case svg = "image/svg+xml"

    public var kind: MediaKind {
        self == .svg ? .vector : .image
    }

    /// The extension written to `assets/` when the library stores bytes of this type.
    /// `jpeg` matches what generation has always written (`{uuid}.jpeg`).
    public var fileExtension: String {
        switch self {
        case .png:  return "png"
        case .jpeg: return "jpeg"
        case .webp: return "webp"
        case .heic: return "heic"
        case .svg:  return "svg"
        }
    }

    /// Parses a MIME type as a provider sends it: case-insensitive, parameters
    /// (`; charset=utf-8`) ignored, and the common `image/jpg` misspelling accepted.
    public init?(mimeType: String) {
        let essence = mimeType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if essence == "image/jpg" {
            self = .jpeg
            return
        }
        self.init(rawValue: essence)
    }

    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "png":         self = .png
        case "jpg", "jpeg": self = .jpeg
        case "webp":        self = .webp
        case "heic":        self = .heic
        case "svg":         self = .svg
        default:            return nil
        }
    }

    public init?(filename: String) {
        self.init(fileExtension: (filename as NSString).pathExtension)
    }
}

extension Asset {
    /// The stored media type, else the one the filename implies. Rows written by a build
    /// without migration v8 (App Store 1.0.x) leave `media_type` NULL, so the fallback is
    /// what keeps those assets classified.
    public var effectiveMediaType: MediaType? {
        mediaType.flatMap(MediaType.init(mimeType:)) ?? MediaType(filename: filename)
    }

    public var mediaKind: MediaKind {
        effectiveMediaType?.kind ?? .image
    }
}
