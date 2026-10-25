import SwiftUI
import ImageAssetManagerCore

/// A grid thumbnail from Core's `ThumbnailCache` (kept per asset and file hash, outside the
/// library), drawn off the main thread. The matte shows until it arrives.
struct ThumbnailImage: View {
    let asset: Asset
    let fileURL: URL

    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                Color.imageMatte
            }
        }
        // A new file under the same asset (new hash) or a different asset restarts the load.
        .task(id: "\(asset.id)|\(asset.fileHash)") {
            image = nil
            guard let cg = await ThumbnailCache.shared.thumbnail(
                assetID: asset.id, fileHash: asset.fileHash, source: fileURL) else { return }
            image = Image(decorative: cg, scale: 1)
        }
        .accessibilityHidden(true)  // accessibility handled by containing element
    }
}
