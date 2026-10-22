import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import ImageAssetManagerCore

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

private func tempDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "iam-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A solid-colour PNG made with ImageIO, so no code under test is involved.
private func solidPNG(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8)) throws -> Data {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for i in stride(from: 0, to: pixels.count, by: 4) {
        pixels[i] = rgb.0; pixels[i + 1] = rgb.1; pixels[i + 2] = rgb.2
    }
    let context = try #require(CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let out = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
    return out as Data
}

private func centreRGB(_ image: CGImage) -> (r: Int, g: Int, b: Int) {
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let cx = CGFloat(image.width / 2), cy = CGFloat(image.height / 2)
    ctx.draw(image, in: CGRect(x: -cx, y: -cy, width: CGFloat(image.width), height: CGFloat(image.height)))
    return (Int(px[0]), Int(px[1]), Int(px[2]))
}

/// Blue underneath, and an `<image>` no renderer can load on top. Drawn raw, the system
/// renderer paints its red placeholder over the middle; the sanitised copy has no `<image>`.
private let svgWithUnloadableImage = Data("""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
      <rect width="100" height="100" fill="#0000FF"/>
      <image href="file:///nonexistent/iam-sniff-test.png" width="100" height="100"/>
    </svg>
    """.utf8)

@Suite("Content sniffing")
struct ContentSniffingTests {
    // Signatures written out by hand from the format specifications.
    static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D]
    static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10] + bytes("JFIF")
    static let webp: [UInt8] = bytes("RIFF") + [0x24, 0, 0, 0] + bytes("WEBPVP8 ")
    /// ftyp box, 24 bytes: major brand mif1, minor 0, compatible mif1 + heic (as iPhone writes).
    static let heic: [UInt8] = [0, 0, 0, 0x18] + bytes("ftypmif1") + [0, 0, 0, 0] + bytes("mif1heic")
    /// The same box for AVIF: major avif, compatible mif1 + miaf. Not HEIC.
    static let avif: [UInt8] = [0, 0, 0, 0x18] + bytes("ftypavif") + [0, 0, 0, 0] + bytes("mif1miaf")
    static let wave: [UInt8] = bytes("RIFF") + [0x24, 0, 0, 0] + bytes("WAVEfmt ")

    @Test func signaturesAreRecognised() {
        #expect(MediaType(sniffing: Data(Self.png)) == .png)
        #expect(MediaType(sniffing: Data(Self.jpeg)) == .jpeg)
        #expect(MediaType(sniffing: Data(Self.webp)) == .webp)
        #expect(MediaType(sniffing: Data(Self.heic)) == .heic)
        #expect(MediaType(sniffing: Data(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)) == .svg)
    }

    @Test func lookalikesAreNotRecognised() {
        #expect(MediaType(sniffing: Data(Self.avif)) == nil)
        #expect(MediaType(sniffing: Data(Self.wave)) == nil)
        #expect(MediaType(sniffing: Data(#"<html><svg xmlns="http://www.w3.org/2000/svg"/></html>"#.utf8)) == nil)
        #expect(MediaType(sniffing: Data(Self.png.prefix(7))) == nil)
        #expect(MediaType(sniffing: Data()) == nil)
    }

    @Test func svgBytesLabelledAsPNGAreRefusedAndLeaveNoFile() throws {
        let library = try tempDirectory("sniff-store")

        #expect(throws: AssetStoreError.contentMismatch(declared: "image/png", actual: "image/svg+xml")) {
            try AssetStore.store(svgWithUnloadableImage, mimeType: "image/png", assetID: "M1", libraryURL: library)
        }
        #expect(throws: AssetStoreError.contentMismatch(declared: "image/svg+xml", actual: "image/png")) {
            try AssetStore.store(try solidPNG(width: 2, height: 2, rgb: (0, 0, 255)),
                                 mimeType: "image/svg+xml", assetID: "M2", libraryURL: library)
        }
        #expect(throws: AssetStoreError.unrecognisedContent(declared: "image/png")) {
            try AssetStore.store(Data("not an image".utf8), mimeType: "image/png", assetID: "M3", libraryURL: library)
        }
        let assets = library.appending(path: "assets").path(percentEncoded: false)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: assets)) ?? []
        #expect(written.isEmpty)
    }

    /// The preview picks its renderer from the bytes, never the file name: SVG in a `.png`
    /// still goes through the sanitiser, and a PNG in a `.svg` still draws.
    @Test func previewRoutesByContentNotByName() async throws {
        let dir = try tempDirectory("sniff-preview")
        let svgNamedPNG = dir.appending(path: "drawing.png")
        try svgWithUnloadableImage.write(to: svgNamedPNG)
        let pngNamedSVG = dir.appending(path: "photo.svg")
        try solidPNG(width: 10, height: 10, rgb: (0, 255, 0)).write(to: pngNamedSVG)

        let vector = try #require(await AssetPreview.render(contentsOf: svgNamedPNG, maxPixelSize: 100))
        let v = centreRGB(vector)
        #expect(v.r < 40 && v.g < 40 && v.b > 200, "centre is \(v)")

        let raster = try #require(await AssetPreview.render(contentsOf: pngNamedSVG, maxPixelSize: 100))
        let r = centreRGB(raster)
        #expect(r.r < 40 && r.g > 200 && r.b < 40, "centre is \(r)")
    }

    /// 10 MB is 10 485 760 bytes. One byte over draws nothing; the same drawing under it draws.
    @Test func anSVGOverTenMegabytesIsNotRendered() async throws {
        // Padded with 1000-byte comments: one comment that size would itself break libxml2's
        // 10 000 000-byte node limit, and then the parser, not the cap, would refuse it.
        func padded(to total: Int) -> Data {
            let head = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10" fill="#0000FF"/>"##
            let tail = "</svg>"
            let chunk = "<!--" + String(repeating: "x", count: 993) + "-->"
            let room = total - head.utf8.count - tail.utf8.count
            let filler = String(repeating: chunk, count: room / 1000) + String(repeating: " ", count: room % 1000)
            return Data((head + filler + tail).utf8)
        }
        let over = padded(to: 10_485_761)
        let under = padded(to: 10_000)
        #expect(over.count == 10_485_761)

        #expect(await SVGPreview.render(over, maxPixelSize: 10) == nil)
        #expect(await SVGPreview.render(under, maxPixelSize: 10) != nil)
    }

    @Test func previewDrawsNothingForUnrecognisedBytes() async throws {
        let dir = try tempDirectory("sniff-junk")
        let junk = dir.appending(path: "junk.png")
        try Data("<html><body>hello</body></html>".utf8).write(to: junk)
        #expect(await AssetPreview.render(contentsOf: junk, maxPixelSize: 100) == nil)
    }
}
