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
                    emptyStateView
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
                .accessibilityLabel("Open generation panel")
                .accessibilityHint("Opens the image generation sheet")
            }
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView()
                    .tint(Color.appAccent)
            }
        }
    }

    // MARK: - Empty states

    @ViewBuilder
    private var emptyStateView: some View {
        if !viewModel.searchText.isEmpty {
            noSearchResultsState
        } else if case .collection = viewModel.sourceSelection {
            emptyCollectionState
        } else {
            emptyLibraryState
        }
    }

    private var emptyLibraryState: some View {
        emptyLayout(
            symbol: "photo.stack",
            title: "No assets yet",
            instruction: "Generate or import images to build your library."
        ) {
            HStack(spacing: 12) {
                Button("Generate", action: onGenerate)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .accessibilityLabel("Open generation panel")
                Button("Import") { viewModel.showImportSheet = true }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Import images from disk")
            }
        }
    }

    private var noSearchResultsState: some View {
        emptyLayout(
            symbol: "magnifyingglass",
            title: "No results",
            instruction: "No assets match \"\(viewModel.searchText)\"."
        ) {
            Button("Clear Search") { viewModel.searchText = "" }
                .buttonStyle(.bordered)
                .accessibilityLabel("Clear search field")
        }
    }

    private var emptyCollectionState: some View {
        emptyLayout(
            symbol: "rectangle.stack.badge.plus",
            title: "This collection is empty",
            instruction: "Generate or import images and assign them to this collection."
        ) {
            Button("Generate", action: onGenerate)
                .buttonStyle(.borderedProminent)
                .tint(Color.appAccent)
                .accessibilityLabel("Open generation panel")
        }
    }

    private func emptyLayout<Actions: View>(
        symbol: String,
        title: String,
        instruction: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 48))
                .foregroundStyle(Color.appTextSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(Color.appTextPrimary)
            Text(instruction)
                .font(.system(size: 15))
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
            actions()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
