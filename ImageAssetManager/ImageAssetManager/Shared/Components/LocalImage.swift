import SwiftUI
import ImageAssetManagerCore

// Loads and displays a local file-system image asynchronously.
// Placeholder and background always use Color.imageMatte per spec.
struct LocalImage: View {
    /// Longest side an SVG is rasterised at: sharp in the inspector, cheap in the grid.
    static let svgPixelSize = 1024

    let url: URL
    @State private var image: Image?
    @State private var svgRequest: URL?

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                Color.imageMatte
            }
        }
        .onAppear { loadImage() }
        .onChange(of: url) { _, _ in loadImage() }
        .accessibilityHidden(true)  // accessibility handled by containing element
    }

    private func loadImage() {
        guard let data = try? Data(contentsOf: url) else { return }
        if MediaType(filename: url.lastPathComponent) == .svg {
            // Rendered from a sanitised copy: no script, no external references (see SVGPreview).
            let requested = url
            svgRequest = requested
            Task {
                guard let rendered = await SVGPreview.render(data, maxPixelSize: Self.svgPixelSize),
                      svgRequest == requested else { return }   // the view moved on to another file
                image = Image(decorative: rendered, scale: 1)
            }
            return
        }
        #if os(macOS)
        if let native = NSImage(data: data) { image = Image(nsImage: native) }
        #else
        if let native = UIImage(data: data) { image = Image(uiImage: native) }
        #endif
    }
}
