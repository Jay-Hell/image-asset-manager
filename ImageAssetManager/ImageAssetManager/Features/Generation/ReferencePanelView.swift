import SwiftUI
import ImageAssetManagerCore

struct ReferencePanelView: View {
    @Bindable var viewModel: GenerationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("REFERENCE IMAGES")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.appTextSecondary)
                    .kerning(0.5)
                Spacer()
                Text("Confirm to apply")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appTextSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.referenceEntries, id: \.id) { entry in
                        ReferenceEntryTile(
                            entry: entry,
                            libraryURL: viewModel.libraryURL,
                            isConfirmed: viewModel.confirmedReferenceIDs.contains(entry.id)
                        ) {
                            toggleConfirmed(entry.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .frame(height: 112)
        }
        .background(Color.appSurface)
    }

    private func toggleConfirmed(_ id: String) {
        if viewModel.confirmedReferenceIDs.contains(id) {
            viewModel.confirmedReferenceIDs.remove(id)
        } else if viewModel.confirmedReferenceIDs.count < 3 {
            viewModel.confirmedReferenceIDs.insert(id)
        }
    }
}

private struct ReferenceEntryTile: View {
    let entry: ReferenceEntry
    let libraryURL: URL
    let isConfirmed: Bool
    let onTap: () -> Void

    private var thumbnailURL: URL {
        libraryURL.appending(path: "assets")
    }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topLeading) {
                // Thumbnail placeholder — actual image loaded via LocalImage
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.imageMatte)
                    .frame(width: 80, height: 80)
                    .overlay {
                        LocalImage(url: thumbnailURL.appending(path: "\(entry.assetID).png"))
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                isConfirmed ? Color.appAccent : Color.clear,
                                lineWidth: 2
                            )
                    }

                // Role badge
                Text(entry.role == "style_anchor" ? "Style" : "Subject")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(isConfirmed ? Color.appAccent : Color.appSurface.opacity(0.85))
                    )
                    .padding(4)
            }
        }
        .buttonStyle(.plain)
    }
}
