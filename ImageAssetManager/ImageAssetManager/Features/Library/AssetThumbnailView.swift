import SwiftUI
import ImageAssetManagerCore

struct AssetThumbnailView: View {
    let asset: Asset
    let libraryURL: URL
    let isSelected: Bool

    @State private var isHovered: Bool = false

    private var fileURL: URL {
        libraryURL.appending(path: "assets").appending(path: asset.filename)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LocalImage(url: fileURL)
                .frame(minHeight: 120)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(asset.providerID == "imported" ? "Import" : asset.providerID)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.6), in: Capsule())
                .padding(5)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.appAccent, lineWidth: 2)
            }
        }
        .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
    }
}
