import SwiftUI
import ImageAssetManagerCore

struct VariantFilmstripRow: View {
    let variant: Variant
    let members: [(VariantMember, Asset)]
    let libraryURL: URL
    let selectedAssetID: String?
    var onSelect: (String) -> Void
    var onPromote: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(variant.name, systemImage: "square.3.layers.3d")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                Text("\(members.count) variants")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }
            .padding(.horizontal, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(members, id: \.0.id) { member, asset in
                        tile(member: member, asset: asset)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private func tile(member: VariantMember, asset: Asset) -> some View {
        let fileURL = libraryURL.appending(path: "assets").appending(path: asset.filename)
        let isSelected = selectedAssetID == asset.id

        return ZStack(alignment: .bottomLeading) {
            LocalImage(url: fileURL)
                .frame(width: 80, height: 80)
                .clipped()
                .background(Color.imageMatte)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text("\(member.sequence)")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(
                    member.isSelected ? Color.appAccent : Color.black.opacity(0.6),
                    in: Circle()
                )
                .padding(4)
                .accessibilityHidden(true)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.appAccent, lineWidth: 2)
            }
        }
        .onTapGesture { onSelect(asset.id) }
        .contextMenu {
            Button("Promote to Selected") { onPromote(member.id) }
                .disabled(member.isSelected)
        }
        .accessibilityElement()
        .accessibilityLabel("Variant \(member.sequence)\(member.isSelected ? ", selected" : ""): \(asset.prompt ?? asset.filename)")
        .accessibilityHint("Double-tap to select this variant")
    }
}
