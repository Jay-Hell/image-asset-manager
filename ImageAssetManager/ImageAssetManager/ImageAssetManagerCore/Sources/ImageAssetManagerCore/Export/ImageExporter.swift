import Foundation
import CoreGraphics
import ImageIO

public struct ImageExporter: Sendable {

    public enum ExportError: Error, LocalizedError {
        case unreadableSource
        case resizeFailed
        case encodingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unreadableSource:         return "Could not read source image"
            case .resizeFailed:             return "Failed to resize image"
            case .encodingFailed(let fmt):  return "Failed to encode as \(fmt)"
            }
        }
    }

    /// Resizes and re-encodes `imageData` according to `preset`, writes the result to
    /// `destinationDir`, and returns the output URL.
    @discardableResult
    public static func export(
        imageData: Data,
        preset: ExportPreset,
        to destinationDir: URL,
        baseFilename: String
    ) throws -> URL {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ExportError.unreadableSource }

        let (targetW, targetH) = computeTargetSize(
            sourceWidth: sourceImage.width,
            sourceHeight: sourceImage.height,
            maxWidth: preset.maxWidth,
            maxHeight: preset.maxHeight
        )

        let resized = try resize(sourceImage, width: targetW, height: targetH)

        let ext = fileExtension(for: preset.format)
        let outputFilename = "\(baseFilename)\(preset.suffix).\(ext)"
        let outputURL = destinationDir.appending(path: outputFilename)

        try encode(resized, format: preset.format, quality: preset.jpegQuality, to: outputURL)
        return outputURL
    }

    // MARK: - Private helpers

    private static func computeTargetSize(
        sourceWidth: Int, sourceHeight: Int,
        maxWidth: Int?, maxHeight: Int?
    ) -> (Int, Int) {
        guard maxWidth != nil || maxHeight != nil else {
            return (sourceWidth, sourceHeight)
        }
        let aspect = Double(sourceWidth) / Double(sourceHeight)
        var w = Double(sourceWidth)
        var h = Double(sourceHeight)

        if let mw = maxWidth.map(Double.init), w > mw {
            w = mw; h = mw / aspect
        }
        if let mh = maxHeight.map(Double.init), h > mh {
            h = mh; w = mh * aspect
        }
        return (max(1, Int(w.rounded())), max(1, Int(h.rounded())))
    }

    private static func resize(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info.rawValue
        ) else { throw ExportError.resizeFailed }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let result = ctx.makeImage() else { throw ExportError.resizeFailed }
        return result
    }

    private static func encode(_ image: CGImage, format: String, quality: Double, to url: URL) throws {
        let uti = utTypeIdentifier(for: format) as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti, 1, nil) else {
            throw ExportError.encodingFailed(format)
        }
        var props: [CFString: Any] = [:]
        if format == "jpeg" {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ExportError.encodingFailed(format)
        }
    }

    private static func utTypeIdentifier(for format: String) -> String {
        switch format {
        case "jpeg": return "public.jpeg"
        case "webp": return "org.webmproject.webp"
        default:     return "public.png"
        }
    }

    private static func fileExtension(for format: String) -> String {
        switch format {
        case "jpeg": return "jpg"
        case "webp": return "webp"
        default:     return "png"
        }
    }
}
