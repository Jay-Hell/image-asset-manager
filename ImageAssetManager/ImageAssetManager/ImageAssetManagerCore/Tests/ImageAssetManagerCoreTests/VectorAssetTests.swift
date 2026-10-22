import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import ImageAssetManagerCore

private func svg(_ s: String) -> Data { Data(s.utf8) }

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

/// RGB of the centre pixel, read back through a context of known layout.
private func centreRGB(_ image: CGImage) -> (r: Int, g: Int, b: Int) {
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let cx = CGFloat(image.width / 2), cy = CGFloat(image.height / 2)
    ctx.draw(image, in: CGRect(x: -cx, y: -cy, width: CGFloat(image.width), height: CGFloat(image.height)))
    return (Int(px[0]), Int(px[1]), Int(px[2]))
}

@Suite("SVG dimensions")
struct SVGDimensionTests {
    @Test func viewBoxWinsOverWidthAndHeight() {
        let d = SVGDocument.dimensions(of: svg(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 480" width="10" height="10"/>"#))
        #expect(d.width == 640 && d.height == 480)
    }

    @Test func viewBoxWithCommasNegativeOriginAndFractionsRounds() {
        let d = SVGDocument.dimensions(of: svg(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="-5,-5,120.4,60.6"/>"#))
        #expect(d.width == 120 && d.height == 61)
    }

    @Test func fallsBackToWidthAndHeightInPixels() {
        let d = SVGDocument.dimensions(of: svg(#"<svg xmlns="http://www.w3.org/2000/svg" width="300px" height="150"/>"#))
        #expect(d.width == 300 && d.height == 150)
    }

    @Test func aDegenerateViewBoxFallsBackToTheAttributes() {
        let d = SVGDocument.dimensions(of: svg(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 0 10" width="20" height="30"/>"#))
        #expect(d.width == 20 && d.height == 30)
    }

    @Test func percentagesAndAbsenceAreNil() {
        let d = SVGDocument.dimensions(of: svg(#"<svg xmlns="http://www.w3.org/2000/svg" width="100%" height="50"/>"#))
        #expect(d.width == nil && d.height == 50)
        let none = SVGDocument.dimensions(of: svg(#"<svg xmlns="http://www.w3.org/2000/svg"><rect width="5" height="5"/></svg>"#))
        #expect(none.width == nil && none.height == nil)
    }

    @Test func prologueDoctypeAndCommentAreSkipped() {
        let d = SVGDocument.dimensions(of: svg("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
            <!-- Generator: Illustrator -->
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M0 0h24v24H0z"/></svg>
            """))
        #expect(d.width == 24 && d.height == 24)
    }

    /// 1e19 is past `Int.max` (about 9.2e18): converting it traps. Anything over 100 000 is
    /// absurd for a drawing and is no size at all.
    @Test func anAbsurdViewBoxIsNoSizeAndDoesNotTrap() {
        let huge = SVGDocument.dimensions(of: svg(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1e19 10"/>"#))
        #expect(huge.width == nil && huge.height == nil)
        let overCap = SVGDocument.dimensions(of: svg(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100001 10"/>"#))
        #expect(overCap.width == nil && overCap.height == nil)
        let atCap = SVGDocument.dimensions(of: svg(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100000 100000"/>"#))
        #expect(atCap.width == 100000 && atCap.height == 100000)
        let attributes = SVGDocument.dimensions(of: svg(#"<svg xmlns="http://www.w3.org/2000/svg" width="1e300px" height="-4"/>"#))
        #expect(attributes.width == nil && attributes.height == nil)
        let notFinite = SVGDocument.dimensions(of: svg(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 inf nan" width="12" height="7"/>"#))
        #expect(notFinite.width == 12 && notFinite.height == 7)
    }

    @Test func notAnSVGIsNil() {
        let html = SVGDocument.dimensions(of: svg(#"<html width="10" height="10"></html>"#))
        #expect(html.width == nil && html.height == nil)
        let junk = SVGDocument.dimensions(of: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF]))
        #expect(junk.width == nil && junk.height == nil)
    }
}

@Suite("AssetStore")
struct AssetStoreTests {
    @Test func svgIsStoredByteForByteWithItsViewBox() throws {
        let library = try tempDirectory("store-svg")
        // CRLF, tabs, a comment, a non-ASCII character and a trailing newline — anything a
        // re-serialisation would normalise.
        let given = Data("<?xml version=\"1.0\"?>\r\n<!-- é -->\r\n<svg xmlns=\"http://www.w3.org/2000/svg\"\tviewBox=\"0 0 48 32\">\r\n\t<rect width=\"48\" height=\"32\" fill=\"#5856D6\"/>\r\n</svg>\n".utf8)

        let stored = try AssetStore.store(given, mimeType: "image/svg+xml", assetID: "A1", libraryURL: library)

        #expect(stored.filename == "A1.svg")
        #expect(stored.fileURL == library.appending(path: "assets").appending(path: "A1.svg"))
        #expect(try Data(contentsOf: stored.fileURL) == given)
        #expect(stored.mediaType == .svg)
        #expect(stored.fileHash == given.sha256)
        #expect(stored.width == 48 && stored.height == 32)
    }

    @Test func rasterIsStoredByteForByteWithItsPixelSize() throws {
        let library = try tempDirectory("store-png")
        let given = try solidPNG(width: 3, height: 2, rgb: (0, 0, 255))

        let stored = try AssetStore.store(given, mimeType: "image/png", assetID: "B2", libraryURL: library)

        #expect(stored.filename == "B2.png")
        #expect(try Data(contentsOf: stored.fileURL) == given)
        #expect(stored.mediaType == .png)
        #expect(stored.width == 3 && stored.height == 2)
    }

    @Test func anSVGWithAnAbsurdViewBoxIsStoredWithNoSize() throws {
        let library = try tempDirectory("store-huge")
        let given = svg(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1e19 10"/>"#)

        let stored = try AssetStore.store(given, mimeType: "image/svg+xml", assetID: "H1", libraryURL: library)

        #expect(stored.width == nil && stored.height == nil)
        #expect(try Data(contentsOf: stored.fileURL) == given)
    }

    @Test func mimeParametersAreIgnoredAndUnknownTypesRefused() throws {
        let library = try tempDirectory("store-mime")
        let stored = try AssetStore.store(svg(#"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="4"/>"#),
                                          mimeType: "Image/SVG+XML; charset=utf-8", assetID: "C3", libraryURL: library)
        #expect(stored.filename == "C3.svg")

        #expect(throws: AssetStoreError.unsupportedMediaType("image/tiff")) {
            try AssetStore.store(Data([1, 2, 3]), mimeType: "image/tiff", assetID: "D4", libraryURL: library)
        }
        let written = try FileManager.default.contentsOfDirectory(atPath: library.appending(path: "assets").path(percentEncoded: false))
        #expect(written == ["C3.svg"])
    }
}

@Suite("SVG preview safety")
struct SVGPreviewSafetyTests {
    static let hostile = """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 100 100" onload="alert(1)">
          <style>@import url(https://example.com/x.css); rect { fill: red }</style>
          <defs><linearGradient id="grad"><stop offset="0" stop-color="blue"/></linearGradient></defs>
          <rect id="r" width="100" height="100" fill="blue"/>
          <rect width="1" height="1" fill="url(#grad)" style="stroke: url(https://example.com/s.svg#p)"/>
          <script>document.getElementById('r').setAttribute('fill', 'red')</script>
          <image href="https://example.com/x.png" width="100" height="100"/>
          <image xlink:href="file:///tmp/x.png" width="100" height="100"/>
          <use href="#r"/>
          <a href="https://example.com/"><circle r="1"/></a>
          <foreignObject width="100" height="100"><div xmlns="http://www.w3.org/1999/xhtml">x</div></foreignObject>
          <animate attributeName="href" to="https://example.com/y.png"/>
          <set attributeName="fill" to="red"/>
        </svg>
        """

    @Test func sanitisedCopyCarriesNoScriptAndNoExternalReference() throws {
        let out = String(decoding: try #require(SVGDocument.sanitisedForPreview(svg(Self.hostile))), as: UTF8.self)
        for banned in ["script", "onload", "example.com", "file:", "foreignObject", "<animate", "<set", "<style", "@import"] {
            #expect(!out.contains(banned), "still contains \(banned)")
        }
        // What must survive: fragment references and the drawing itself.
        #expect(out.contains(##"href="#r""##))
        #expect(out.contains("url(#grad)"))
        #expect(out.contains(#"fill="blue""#))
        #expect(out.contains("<circle"))
    }

    /// What a denylist let through: a CSS-escaped `url(` in `style`, an XHTML `srcset`, a
    /// `<meta>` refresh, `image-set()`, and anything inside an element no list names.
    @Test func onlyAllowListedElementsAttributesAndStylePropertiesSurvive() throws {
        let doc = #"""
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:h="http://www.w3.org/1999/xhtml" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" viewBox="0 0 10 10">
              <rect width="10" height="10" style="fill:#0000FF;background:\75 rl(https://example.com/a.png)"/>
              <rect width="1" height="1" h:srcset="https://example.com/b.png 1x" srcset="https://example.com/b2.png 1x"/>
              <h:meta http-equiv="refresh" content="0;url=https://example.com/c"/>
              <meta content="0;url=https://example.com/d"/>
              <rect width="1" height="1" fill="image-set('https://example.com/e.png' 1x)"/>
              <rect width="1" height="1" style="fill: -webkit-image-set(url(https://example.com/f.png) 1x)"/>
              <rect width="1" height="1" cursor="url(https://example.com/g.cur), auto"/>
              <unknownthing><circle r="9" fill="red"/></unknownthing>
              <h:img src="https://example.com/h.png"/>
              <g inkscape:label="Layer 1" transform="translate(1, 2) scale(2)"><path d="M0 0L10 10" stroke="rgb(0,0,255)" stroke-width="2"/></g>
            </svg>
            """#
        let out = String(decoding: try #require(SVGDocument.sanitisedForPreview(svg(doc))), as: UTF8.self)
        for banned in ["example.com", "srcset", "meta", "\\", "image-set", "unknownthing", "cursor", "img", "inkscape", "xmlns:h", #"fill="red""#] {
            #expect(!out.contains(banned), "still contains \(banned)")
        }
        // The drawing itself survives, style filtered to what it may say.
        #expect(out.contains(#"style="fill:#0000FF""#))
        #expect(out.contains(#"transform="translate(1, 2) scale(2)""#))
        #expect(out.contains(#"<path d="M0 0L10 10" stroke="rgb(0,0,255)" stroke-width="2">"#))
        #expect(out.contains(#"xmlns="http://www.w3.org/2000/svg""#))
    }

    /// Blue underneath; a script would turn it red; any image that loads is green; an `<image>`
    /// the system renderer cannot load is drawn as a red placeholder. Only blue is a pass.
    /// (Measured on macOS 26: CoreSVG does not load `file:`/`https:` hrefs but does render
    /// `data:` ones, and draws the red placeholder for any `<image>` it cannot load.)
    @Test func aScriptAndAnExternalImageRenderNeither() async throws {
        let dir = try tempDirectory("render")
        let green = dir.appending(path: "green.png")
        let greenPNG = try solidPNG(width: 10, height: 10, rgb: (0, 255, 0))
        try greenPNG.write(to: green)
        let doc = """
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 100 100">
              <rect id="r" width="100" height="100" fill="#0000FF"/>
              <script>document.getElementById('r').setAttribute('fill', '#FF0000')</script>
              <image href="\(green.absoluteString)" width="100" height="100"/>
              <image xlink:href="https://example.com/green.png" width="100" height="100"/>
              <image href="data:image/png;base64,\(greenPNG.base64EncodedString())" width="100" height="100"/>
            </svg>
            """

        let image = try #require(await SVGPreview.render(svg(doc), maxPixelSize: 100))
        let c = centreRGB(image)
        #expect(c.r < 40 && c.g < 40 && c.b > 200, "centre is \(c)")
    }

    @Test func aFragmentReferenceStillRenders() async throws {
        let doc = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
              <defs><rect id="g" width="100" height="100" fill="#00FF00"/></defs>
              <rect width="100" height="100" fill="#0000FF"/>
              <use href="#g"/>
            </svg>
            """
        let image = try #require(await SVGPreview.render(svg(doc), maxPixelSize: 100))
        let c = centreRGB(image)
        #expect(c.g > 200 && c.b < 40, "centre is \(c)")
    }

    @Test func rendersAtTheDocumentsAspect() async throws {
        let doc = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 50"><rect width="200" height="50" fill="#0000FF"/></svg>"##
        let image = try #require(await SVGPreview.render(svg(doc), maxPixelSize: 400))
        #expect(image.width == 400 && image.height == 100)
    }
}
