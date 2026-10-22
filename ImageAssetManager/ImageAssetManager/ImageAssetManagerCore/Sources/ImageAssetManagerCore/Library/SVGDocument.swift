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

    /// A copy safe to hand to a renderer: no script, no event handlers, no animation, no
    /// `<style>`, no `foreignObject`, and no reference to anything outside the document.
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

    private static func positiveInt(_ value: Double) -> Int? {
        guard value.isFinite, value > 0 else { return nil }
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

/// Re-serialises the document from parser events, keeping only what draws. Whatever the
/// parser expands (entities included) passes through the same filter.
private final class PreviewSanitiser: NSObject, XMLParserDelegate {
    /// Elements dropped with everything inside them. `image` can only show an external file or
    /// a `data:` URI, both refused, and the system renderer draws a red placeholder for an
    /// `<image>` it cannot load — so the element goes, not just its `href`.
    static let droppedElements: Set<String> = [
        "script", "style", "foreignobject", "iframe", "object", "embed", "audio", "video", "canvas", "image",
        "animate", "animatemotion", "animatetransform", "animatecolor", "set", "discard",
        "handler", "listener",
    ]

    private(set) var output = ""
    private(set) var sawSVGRoot = false
    private var depth = 0
    private var skipFromDepth: Int?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        depth += 1
        if depth == 1 {
            sawSVGRoot = SVGDocument.localName(elementName) == "svg"
        }
        guard skipFromDepth == nil else { return }
        let local = SVGDocument.localName(elementName).lowercased()
        if Self.droppedElements.contains(local) || (local == "feimage" && !Self.hasFragmentHref(attributeDict)) {
            skipFromDepth = depth
            return
        }
        output += "<\(elementName)"
        for key in attributeDict.keys.sorted() {
            guard let value = attributeDict[key], Self.keeps(attribute: key, value: value) else { continue }
            output += " \(key)=\"\(Self.escape(value, quotes: true))\""
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

    static func keeps(attribute name: String, value: String) -> Bool {
        let lower = name.lowercased()
        if lower == "xmlns" || lower.hasPrefix("xmlns:") { return true }   // namespace URIs are never fetched
        if lower == "xml:base" { return false }
        let local = SVGDocument.localName(lower)
        if local.hasPrefix("on") { return false }                          // event handlers
        if local == "href" || local == "src" {
            return value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#")
        }
        if value.lowercased().contains("javascript:") { return false }
        return onlyFragmentURLs(in: value)
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
