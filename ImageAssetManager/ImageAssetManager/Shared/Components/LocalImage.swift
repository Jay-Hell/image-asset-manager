import SwiftUI

// Loads and displays a local file-system image asynchronously.
// Placeholder and background always use Color.imageMatte per spec.
struct LocalImage: View {
    let url: URL
    @State private var image: Image?

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
        #if os(macOS)
        if let native = NSImage(data: data) { image = Image(nsImage: native) }
        #else
        if let native = UIImage(data: data) { image = Image(uiImage: native) }
        #endif
    }
}
