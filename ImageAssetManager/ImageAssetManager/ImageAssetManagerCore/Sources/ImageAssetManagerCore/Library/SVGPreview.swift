import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
import WebKit
#endif

/// Rasterises an SVG for the grid and inspector. Always renders the sanitised copy
/// (`SVGDocument.sanitisedForPreview`), so whatever the platform renderer would do with a
/// script or an external reference, it is never handed one.
///
/// - macOS: `NSImage(data:)` (CoreSVG). Runs no script; draws a red placeholder for any
///   `<image>` it cannot load, which is why the sanitiser drops `<image>` outright.
/// - iPadOS: `UIImage(data:)` returns nil for SVG (measured, iPadOS 26.5 simulator), so the
///   copy is drawn by WebKit as an `<img>` — the SVG-as-image context, which never runs
///   script or loads sub-resources — in a web view with JavaScript off and no persistent store.
public enum SVGPreview {
    public static func render(_ data: Data, maxPixelSize: Int) async -> CGImage? {
        guard let safe = SVGDocument.sanitisedForPreview(data) else { return nil }
        #if canImport(AppKit)
        guard let image = NSImage(data: safe), image.size.width > 0, image.size.height > 0 else { return nil }
        let size = fitted(image.size, maxPixelSize: maxPixelSize)
        guard let context = bitmapContext(width: size.width, height: size.height) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
        #elseif canImport(UIKit)
        let intrinsic = intrinsicSize(of: safe)
        let size = fitted(intrinsic, maxPixelSize: maxPixelSize)
        return await WebKitSVGRasteriser.shared.render(safe, width: size.width, height: size.height)
        #else
        return nil
        #endif
    }

    /// The image's own aspect, longest side `maxPixelSize`.
    static func fitted(_ size: CGSize, maxPixelSize: Int) -> (width: Int, height: Int) {
        let scale = Double(maxPixelSize) / max(size.width, size.height)
        return (max(1, Int((size.width * scale).rounded())), max(1, Int((size.height * scale).rounded())))
    }

    /// From `viewBox` or `width`/`height`; a browser's 300 × 150 default for whatever is missing.
    static func intrinsicSize(of data: Data) -> CGSize {
        let d = SVGDocument.dimensions(of: data)
        return CGSize(width: d.width ?? 300, height: d.height ?? 150)
    }

    static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}

#if canImport(UIKit) && !canImport(AppKit)
/// One reused, off-screen web view; renders one SVG at a time.
@MainActor
final class WebKitSVGRasteriser: NSObject, WKNavigationDelegate {
    static let shared = WebKitSVGRasteriser()
    static let timeoutSeconds = 5

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var loading: CheckedContinuation<Void, Error>?
    private var snapshotting: CheckedContinuation<UIImage, Error>?
    private var currentNavigation: WKNavigation?

    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.navigationDelegate = self
        return view
    }()

    func render(_ svg: Data, width: Int, height: Int) async -> CGImage? {
        await acquire()
        defer { release() }

        webView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let html = """
            <!doctype html><html><head><meta name="viewport" content="width=\(width),initial-scale=1">
            <style>html,body{margin:0;padding:0;width:100%;height:100%;background:transparent;overflow:hidden}
            img{display:block;width:100%;height:100%;object-fit:contain}</style></head>
            <body><img alt="" src="data:image/svg+xml;base64,\(svg.base64EncodedString())"></body></html>
            """
        // A load or snapshot that never reports back must not hold the queue for ever.
        let timeout = Task { @MainActor [weak self] in
            try await Task.sleep(for: .seconds(Self.timeoutSeconds))
            self?.abandon()
        }
        defer { timeout.cancel() }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                loading = continuation
                currentNavigation = webView.loadHTMLString(html, baseURL: nil)
            }
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            config.afterScreenUpdates = true
            let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                snapshotting = continuation
                webView.takeSnapshot(with: config) { [weak self] image, error in
                    guard let self, let pending = self.snapshotting else { return }
                    self.snapshotting = nil
                    if let image {
                        pending.resume(returning: image)
                    } else {
                        pending.resume(throwing: error ?? CancellationError())
                    }
                }
            }
            guard let cg = snapshot.cgImage,
                  let context = SVGPreview.bitmapContext(width: width, height: height) else { return nil }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        } catch {
            return nil
        }
    }

    private func abandon() {
        webView.stopLoading()
        currentNavigation = nil
        loading?.resume(throwing: CancellationError())
        loading = nil
        snapshotting?.resume(throwing: CancellationError())
        snapshotting = nil
    }

    // MARK: - Navigation: only the one document this type loads

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let scheme = navigationAction.request.url?.scheme ?? "about"
        return scheme == "about" ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(navigation, error: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(navigation, error: error)
    }

    /// Only the navigation this render started may complete it; a late callback from an
    /// abandoned one is ignored.
    private func finishLoad(_ navigation: WKNavigation?, error: Error?) {
        guard let navigation, navigation === currentNavigation, let pending = loading else { return }
        loading = nil
        currentNavigation = nil
        if let error {
            pending.resume(throwing: error)
        } else {
            pending.resume()
        }
    }

    // MARK: - One render at a time

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
#endif
