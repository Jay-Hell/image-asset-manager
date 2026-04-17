import SwiftUI
import ImageAssetManagerCore

struct AssetGridView: View {
    @Bindable var viewModel: LibraryViewModel
    var onGenerate: () -> Void

    private let minTileWidth: CGFloat = 160
    private let spacing: CGFloat = 4

    private var standaloneAssets: [Asset] {
        viewModel.assets.filter { !viewModel.variantMemberIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !viewModel.displayedVariantFamilies.isEmpty {
                    ForEach(viewModel.displayedVariantFamilies, id: \.0.id) { variant, members in
                        VariantFilmstripRow(
                            variant: variant,
                            members: members,
                            libraryURL: viewModel.libraryURL,
                            selectedAssetID: viewModel.selectedAssetID,
                            onSelect: { assetID in
                                Task { await viewModel.selectAsset(assetID) }
                            },
                            onPromote: { memberID in
                                Task { await viewModel.promoteVariantMember(memberID: memberID, in: variant.id) }
                            }
                        )
                        .padding(.vertical, 8)

                        Divider()
                            .padding(.horizontal, 12)
                    }

                    if !standaloneAssets.isEmpty {
                        Text("Other Assets")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.appTextSecondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                    }
                }

                if standaloneAssets.isEmpty && viewModel.displayedVariantFamilies.isEmpty {
                    emptyState
                } else if !standaloneAssets.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: minTileWidth), spacing: spacing)],
                        spacing: spacing
                    ) {
                        ForEach(standaloneAssets, id: \.id) { asset in
                            AssetThumbnailView(
                                asset: asset,
                                libraryURL: viewModel.libraryURL,
                                isSelected: viewModel.selectedAssetID == asset.id
                            )
                            .onTapGesture {
                                Task { await viewModel.selectAsset(asset.id) }
                            }
                        }
                    }
                    .padding(spacing)
                }
            }
        }
        .background(Color.appBackground)
        .searchable(text: $viewModel.searchText, prompt: "Search assets")
        .onSubmit(of: .search) {
            Task { await viewModel.loadAssets() }
        }
        .onChange(of: viewModel.searchText) { old, new in
            if new.isEmpty && !old.isEmpty {
                Task { await viewModel.loadAssets() }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onGenerate) {
                    Label("Generate", systemImage: "wand.and.stars")
                }
                .keyboardShortcut("g", modifiers: .command)
                .help("Open Generation Panel (⌘G)")
            }
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView()
                    .tint(Color.appAccent)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(Color.appTextSecondary)
            Text("No assets yet")
                .font(.title3)
                .foregroundStyle(Color.appTextPrimary)
            Text("Generate or import images to build your library.")
                .font(.callout)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Generate", action: onGenerate)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                Button("Import") { viewModel.showImportSheet = true }
                    .buttonStyle(.bordered)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
