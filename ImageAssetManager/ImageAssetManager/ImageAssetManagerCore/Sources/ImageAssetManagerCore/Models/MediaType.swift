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

    /// What the bytes are, whatever they are called or labelled: PNG, JPEG, WebP and HEIC by
    /// their signatures, SVG by an `<svg>` root element. Nil for anything else.
    public init?(sniffing data: Data) {
        let head = [UInt8](data.prefix(64))
        func ascii(_ range: Range<Int>, _ text: String) -> Bool {
            head.count >= range.upperBound && head[range].elementsEqual(text.utf8)
        }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            self = .png
        } else if head.starts(with: [0xFF, 0xD8, 0xFF]) {
            self = .jpeg
        } else if ascii(0..<4, "RIFF"), ascii(8..<12, "WEBP") {
            self = .webp
        } else if Self.isHEIC(head) {
            self = .heic
        } else if SVGDocument.rootAttributes(of: data) != nil {
            self = .svg
        } else {
            return nil
        }
    }

    /// An ISO-BMFF `ftyp` box whose major or a compatible brand is a HEIC/HEVC one. AVIF shares
    /// the box and the `mif1` brand, so `mif1` alone is not enough.
    private static func isHEIC(_ head: [UInt8]) -> Bool {
        let heicBrands: Set<String> = ["heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs"]
        guard head.count >= 12, head[4..<8].elementsEqual("ftyp".utf8) else { return false }
        let boxSize = head[0..<4].reduce(0) { $0 << 8 | Int($1) }
        let end = min(boxSize, head.count)
        var brands = [String(decoding: head[8..<12], as: UTF8.self)]
        var offset = 16   // after major brand and minor version
        while offset + 4 <= end {
            brands.append(String(decoding: head[offset..<offset + 4], as: UTF8.self))
            offset += 4
        }
        return brands.contains(where: heicBrands.contains)
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
