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

    private var chipLabel: String {
        asset.providerID == "imported" ? "Import" : asset.providerID
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.imageMatte
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    LocalImage(url: fileURL)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(chipLabel)
                .font(.system(size: 10, weight: .medium, design: .default))
                .foregroundStyle(Color.appTextPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.appSurface.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                .padding(6)
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
        .accessibilityElement()
        .accessibilityLabel(asset.prompt ?? asset.filename)
        .accessibilityHint("Double-tap to inspect")
        .accessibilityAddTraits(.isImage)
    }
}
