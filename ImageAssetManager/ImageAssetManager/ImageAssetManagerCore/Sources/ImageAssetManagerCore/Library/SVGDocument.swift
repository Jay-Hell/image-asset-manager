import Foundation

/// Reads an SVG without rendering it.
public enum SVGDocument {
    /// Width and height from the root `viewBox`, falling back to its `width`/`height`
    /// attributes (unitless or `px`), else nil.
    public static func dimensions(of data: Data) -> (width: Int?, height: Int?) {
        guard let root = rootAttributes(of: data) else { return (nil, nil) }
        if let box = root["viewBox"].flatMap(parseViewBox) {
            return (box.width, box.height)
        }
        return (root["width"].flatMap(parseLength), root["height"].flatMap(parseLength))
    }

    /// A copy safe to hand to a renderer, built from allow-lists: only static SVG drawing
    /// elements, only geometry and presentation attributes, `style` filtered to presentation
    /// properties, and no reference to anything outside the document. So no script, event
    /// handler, animation, `<style>`, `foreignObject`, `<image>` or foreign-namespace markup.
    /// For preview only — the library keeps the bytes as delivered. Nil if unparseable.
    public static func sanitisedForPreview(_ data: Data) -> Data? {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let sanitiser = PreviewSanitiser()
        parser.delegate = sanitiser
        guard parser.parse(), sanitiser.sawSVGRoot else { return nil }
        return Data(sanitiser.output.utf8)
    }

    // MARK: - Dimensions

    static func rootAttributes(of data: Data) -> [String: String]? {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let reader = RootReader()
        parser.delegate = reader
        _ = parser.parse()   // aborted after the root element, so false is expected
        guard let name = reader.rootName, localName(name) == "svg" else { return nil }
        return reader.attributes
    }

    /// `min-x min-y width height`, separated by whitespace and/or commas.
    static func parseViewBox(_ raw: String) -> (width: Int, height: Int)? {
        let parts = raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { Double($0) }
        guard parts.count == 4, let w = positiveInt(parts[2]), let h = positiveInt(parts[3]) else { return nil }
        return (w, h)
    }

    /// Unitless or `px` only; percentages and physical units have no pixel size of their own.
    static func parseLength(_ raw: String) -> Int? {
        var value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasSuffix("px") { value.removeLast(2) }
        return Double(value).flatMap(positiveInt)
    }

    /// Largest side taken as a real size. Bounded before converting: `Int(1e19)` traps.
    static let maxDimension: Double = 100_000

    private static func positiveInt(_ value: Double) -> Int? {
        guard value.isFinite, value > 0, value <= maxDimension else { return nil }
        return Int(value.rounded())
    }

    static func localName(_ qualified: String) -> String {
        (qualified.split(separator: ":").last.map(String.init) ?? qualified)
    }
}

private final class RootReader: NSObject, XMLParserDelegate {
    var rootName: String?
    var attributes: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        rootName = elementName
        attributes = attributeDict
        parser.abortParsing()
    }
}

/// Re-serialises the document from parser events, keeping only what the allow-lists name.
/// Whatever the parser expands (entities included) passes through the same filter.
private final class PreviewSanitiser: NSObject, XMLParserDelegate {
    static let svgNamespace = "http://www.w3.org/2000/svg"
    static let xlinkNamespace = "http://www.w3.org/1999/xlink"

    /// Static drawing elements (lower-cased local names). Anything else is dropped with
    /// everything inside it. `image` is absent on purpose: it can only show an external file
    /// or a `data:` URI, both refused, and the system renderer draws a red placeholder for an
    /// `<image>` it cannot load. `feImage` is allowed only with a fragment `href`.
    static let allowedElements: Set<String> = [
        "svg", "g", "defs", "symbol", "use", "title", "desc",
        "path", "rect", "circle", "ellipse", "line", "polyline", "polygon",
        "text", "tspan", "textpath",
        "lineargradient", "radialgradient", "stop", "pattern", "clippath", "mask", "marker",
        "filter", "feblend", "fecolormatrix", "fecomponenttransfer", "fecomposite", "feconvolvematrix",
        "fediffuselighting", "fedisplacementmap", "fedistantlight", "fedropshadow", "feflood",
        "fefunca", "fefuncb", "fefuncg", "fefuncr", "fegaussianblur", "feimage", "femerge",
        "femergenode", "femorphology", "feoffset", "fepointlight", "fespecularlighting",
        "fespotlight", "fetile", "feturbulence",
    ]

    /// Elements whose tag goes but whose content stays: a link's drawing still draws.
    static let unwrappedElements: Set<String> = ["a"]

    /// Presentation properties, allowed both as attributes and inside `style`.
    static let presentationProperties: Set<String> = [
        "alignment-baseline", "baseline-shift", "clip", "clip-path", "clip-rule", "color",
        "color-interpolation", "color-interpolation-filters", "color-rendering", "direction",
        "display", "dominant-baseline", "fill", "fill-opacity", "fill-rule", "filter",
        "flood-color", "flood-opacity", "font", "font-family", "font-size", "font-size-adjust",
        "font-stretch", "font-style", "font-variant", "font-weight", "isolation", "letter-spacing",
        "lighting-color", "marker", "marker-end", "marker-mid", "marker-start", "mask",
        "mix-blend-mode", "opacity", "overflow", "paint-order", "shape-rendering", "stop-color",
        "stop-opacity", "stroke", "stroke-dasharray", "stroke-dashoffset", "stroke-linecap",
        "stroke-linejoin", "stroke-miterlimit", "stroke-opacity", "stroke-width", "text-anchor",
        "text-decoration", "text-rendering", "unicode-bidi", "vector-effect", "visibility",
        "word-spacing", "writing-mode",
    ]

    /// Geometry, structure and filter attributes (lower-cased), on top of the presentation set.
    static let allowedAttributes: Set<String> = presentationProperties.union([
        "id", "class", "lang", "xml:lang", "xml:space", "viewbox", "preserveaspectratio", "version",
        "x", "y", "width", "height", "transform", "href", "xlink:href", "style",
        "d", "points", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "pathlength",
        "gradientunits", "gradienttransform", "spreadmethod", "fx", "fy", "fr", "offset",
        "patternunits", "patterncontentunits", "patterntransform",
        "clippathunits", "maskunits", "maskcontentunits",
        "markerwidth", "markerheight", "markerunits", "refx", "refy", "orient",
        "filterunits", "primitiveunits", "in", "in2", "result", "stddeviation", "dx", "dy",
        "mode", "type", "values", "tablevalues", "slope", "intercept", "amplitude", "exponent",
        "operator", "k1", "k2", "k3", "k4", "order", "kernelmatrix", "divisor", "bias",
        "targetx", "targety", "edgemode", "kernelunitlength", "preservealpha", "surfacescale",
        "diffuseconstant", "specularconstant", "specularexponent", "scale", "xchannelselector",
        "ychannelselector", "radius", "basefrequency", "numoctaves", "seed", "stitchtiles",
        "azimuth", "elevation", "z", "pointsatx", "pointsaty", "pointsatz", "limitingconeangle",
        "rotate", "textlength", "lengthadjust", "startoffset", "method", "spacing", "side",
    ])

    /// CSS functions a drawing needs. Anything else (`image-set`, `expression`, `attr`, …) is
    /// refused, and `url()` only to a fragment.
    static let allowedFunctions: Set<String> = [
        "rgb", "rgba", "hsl", "hsla", "url", "matrix", "translate", "scale", "rotate", "skewx", "skewy",
    ]

    private(set) var output = ""
    private(set) var sawSVGRoot = false
    private var depth = 0
    private var skipFromDepth: Int?
    private var unwrappedDepths: [Int] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        depth += 1
        if depth == 1 {
            sawSVGRoot = SVGDocument.localName(elementName) == "svg"
        }
        guard skipFromDepth == nil else { return }
        // Unprefixed or `svg:` only: another namespace's markup is not SVG, whatever it's called.
        let parts = elementName.split(separator: ":")
        let foreign = parts.count > 1 && parts[0] != "svg"
        let local = SVGDocument.localName(elementName).lowercased()
        if !foreign && Self.unwrappedElements.contains(local) {
            unwrappedDepths.append(depth)
            return
        }
        if foreign || !Self.allowedElements.contains(local)
            || (local == "feimage" && !Self.hasFragmentHref(attributeDict)) {
            skipFromDepth = depth
            return
        }
        output += "<\(elementName)"
        for key in attributeDict.keys.sorted() {
            guard let value = attributeDict[key], let kept = Self.kept(attribute: key, value: value) else { continue }
            output += " \(key)=\"\(Self.escape(kept, quotes: true))\""
        }
        output += ">"
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        defer { depth -= 1 }
        if let from = skipFromDepth {
            if depth == from { skipFromDepth = nil }
            return
        }
        if unwrappedDepths.last == depth {
            unwrappedDepths.removeLast()
            return
        }
        output += "</\(elementName)>"
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipFromDepth == nil, depth > 0 else { return }
        output += Self.escape(string, quotes: false)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard skipFromDepth == nil, depth > 0 else { return }
        output += Self.escape(String(decoding: CDATABlock, as: UTF8.self), quotes: false)
    }

    static func hasFragmentHref(_ attributes: [String: String]) -> Bool {
        attributes.contains { key, value in
            SVGDocument.localName(key.lowercased()) == "href"
                && value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#")
        }
    }

    /// The value to write for an attribute, or nil to drop it.
    static func kept(attribute name: String, value: String) -> String? {
        let lower = name.lowercased()
        // Namespace declarations: only SVG's and XLink's. Every other prefix's markup is dropped,
        // so its declaration is not needed.
        switch lower {
        case "xmlns", "xmlns:svg": return value == svgNamespace ? value : nil
        case "xmlns:xlink":        return value == xlinkNamespace ? value : nil
        default: break
        }
        guard allowedAttributes.contains(lower) else { return nil }
        if lower == "href" || lower == "xlink:href" {
            return value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") ? value : nil
        }
        if lower == "style" {
            return filteredStyle(value)
        }
        return safeValue(value) ? value : nil
    }

    /// Only presentation properties with safe values; nil when none is left.
    static func filteredStyle(_ value: String) -> String? {
        let kept = value.split(separator: ";").compactMap { declaration -> String? in
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let property = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let propertyValue = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard presentationProperties.contains(property), safeValue(propertyValue) else { return nil }
            return "\(property):\(propertyValue)"
        }
        return kept.isEmpty ? nil : kept.joined(separator: ";")
    }

    /// No CSS escapes or comments (they can spell any function name), every function one a
    /// drawing needs, and every `url()` a fragment.
    static func safeValue(_ value: String) -> Bool {
        let lower = value.lowercased()
        if lower.contains("\\") || lower.contains("/*") { return false }
        let characters = Array(lower)
        for (index, character) in characters.enumerated() where character == "(" {
            var end = index
            while end > 0, characters[end - 1].isWhitespace { end -= 1 }
            var start = end
            while start > 0, characters[start - 1].isLetter || characters[start - 1].isNumber
                    || characters[start - 1] == "-" || characters[start - 1] == "_" {
                start -= 1
            }
            guard allowedFunctions.contains(String(characters[start..<end])) else { return false }
        }
        return onlyFragmentURLs(in: lower)
    }

    /// Every `url(...)` in the value must point inside the document: `url(#id)`.
    static func onlyFragmentURLs(in value: String) -> Bool {
        var rest = Substring(value.lowercased())
        while let range = rest.range(of: "url(") {
            rest = rest[range.upperBound...].drop(while: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
            guard rest.first == "#" else { return false }
        }
        return true
    }

    static func escape(_ s: String, quotes: Bool) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if quotes { out = out.replacingOccurrences(of: "\"", with: "&quot;") }
        return out
    }
}
