import SwiftUI
import ImageAssetManagerCore

// Loads and displays a local file-system image asynchronously.
// Placeholder and background always use Color.imageMatte per spec.
struct LocalImage: View {
    /// Longest side a preview is drawn at: sharp in the inspector, cheap in the grid.
    static let previewPixelSize = 1024

    let url: URL
    @State private var image: Image?
    @State private var request: URL?

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

    /// The renderer is chosen from the file's bytes, never its name: SVG always goes through
    /// the sanitiser, and bytes that are neither SVG nor a known raster draw nothing.
    private func loadImage() {
        let requested = url
        request = requested
        Task {
            guard let rendered = await AssetPreview.render(contentsOf: requested, maxPixelSize: Self.previewPixelSize),
                  request == requested else { return }   // the view moved on to another file
            image = Image(decorative: rendered, scale: 1)
        }
    }
}
