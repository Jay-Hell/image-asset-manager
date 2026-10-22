import Foundation
import CoreGraphics
import ImageIO

/// Draws an asset file for the grid and inspector. The renderer is chosen by what the bytes
/// are, never by the file name: SVG (by its `<svg>` root) always goes through `SVGPreview`,
/// so through the sanitiser; a raster ImageIO recognises is drawn by ImageIO; anything else
/// draws nothing. Nothing here hands raw bytes to a renderer that would draw an SVG.
public enum AssetPreview {
    /// Raster formats drawn directly. SVG and PDF are deliberately absent.
    static let rasterTypes: Set<String> = [
        "public.png", "public.jpeg", "org.webmproject.webp", "public.heic", "public.heif",
        "com.compuserve.gif", "public.tiff", "com.microsoft.bmp",
    ]

    public static func render(contentsOf url: URL, maxPixelSize: Int) async -> CGImage? {
        if let raster = rasterThumbnail(url, maxPixelSize: maxPixelSize) {
            return raster
        }
        // Size checked before reading, so an oversized file is never read or parsed.
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= SVGPreview.maxInputBytes,
              let data = try? Data(contentsOf: url),
              MediaType(sniffing: data) == .svg
        else { return nil }
        return await SVGPreview.render(data, maxPixelSize: maxPixelSize)
    }

    /// Longest side `maxPixelSize`, EXIF orientation applied.
    static func rasterThumbnail(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?,
              rasterTypes.contains(type)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
