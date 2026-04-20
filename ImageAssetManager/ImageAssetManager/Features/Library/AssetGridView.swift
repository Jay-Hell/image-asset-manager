import SwiftUI
import ImageAssetManagerCore

struct AssetGridView: View {
    @Bindable var viewModel: LibraryViewModel
    var onGenerate: () -> Void

    @State private var showDeleteConfirmation: Bool = false

    private let minTileWidth: CGFloat = 160
    private let spacing: CGFloat = 4

    private var standaloneAssets: [Asset] {
        viewModel.assets.filter { !viewModel.variantMemberIDs.contains($0.id) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
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
                                selectableCell(asset: asset)
                            }
                        }
                        .padding(spacing)
                        // Bottom padding so the action bar doesn't obscure the last row
                        .padding(.bottom, viewModel.isSelectMode ? 60 : 0)
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
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if viewModel.isSelectMode {
                                viewModel.isSelectMode = false
                                viewModel.selectedAssetIDs = []
                            } else {
                                viewModel.isSelectMode = true
                            }
                        }
                    } label: {
                        Image(systemName: viewModel.isSelectMode ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .help(viewModel.isSelectMode ? "Exit select mode" : "Select assets")
                    .accessibilityLabel(viewModel.isSelectMode ? "Exit select mode" : "Select multiple assets")
                }
            }
            .overlay {
                if viewModel.isLoading {
                    ProgressView()
                        .tint(Color.appAccent)
                }
            }

            // Bottom action bar (select mode)
            if viewModel.isSelectMode {
                selectModeActionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isSelectMode)
        .confirmationDialog(
            "Delete \(viewModel.selectedAssetIDs.count) asset\(viewModel.selectedAssetIDs.count == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove from Library", role: .destructive) {
                let ids = viewModel.selectedAssetIDs
                Task { try? await viewModel.deleteAssets(ids, fromDisk: false) }
            }
            Button("Delete from Disk", role: .destructive) {
                let ids = viewModel.selectedAssetIDs
                Task { try? await viewModel.deleteAssets(ids, fromDisk: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"Remove from Library\" keeps the file on disk. \"Delete from Disk\" permanently removes the file.")
        }
    }

    // MARK: - Selectable cell

    @ViewBuilder
    private func selectableCell(asset: Asset) -> some View {
        ZStack(alignment: .topTrailing) {
            AssetThumbnailView(
                asset: asset,
                libraryURL: viewModel.libraryURL,
                isSelected: !viewModel.isSelectMode && viewModel.selectedAssetID == asset.id
            )
            .opacity(asset.isHidden ? 0.4 : 1.0)
            .overlay(alignment: .topLeading) {
                if asset.isHidden {
                    Text("Hidden")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .padding(6)
                        .padding(.leading, 56) // offset past provider chip
                }
            }
            .onTapGesture {
                if viewModel.isSelectMode {
                    if viewModel.selectedAssetIDs.contains(asset.id) {
                        viewModel.selectedAssetIDs.remove(asset.id)
                    } else {
                        viewModel.selectedAssetIDs.insert(asset.id)
                    }
                } else {
                    Task { await viewModel.selectAsset(asset.id) }
                }
            }

            if viewModel.isSelectMode {
                checkboxOverlay(selected: viewModel.selectedAssetIDs.contains(asset.id))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    private func checkboxOverlay(selected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(selected ? Color.appAccent : Color.black.opacity(0.4))
                .frame(width: 22, height: 22)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Circle()
                    .strokeBorder(.white.opacity(0.8), lineWidth: 1.5)
                    .frame(width: 22, height: 22)
            }
        }
    }

    // MARK: - Select mode action bar

    private var selectModeActionBar: some View {
        HStack(spacing: 0) {
            Text(viewModel.selectedAssetIDs.isEmpty
                 ? "Select assets above"
                 : "\(viewModel.selectedAssetIDs.count) selected")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.appTextSecondary)
                .padding(.leading, 16)

            Spacer()

            Button {
                let allHidden = viewModel.assets
                    .filter { viewModel.selectedAssetIDs.contains($0.id) }
                    .allSatisfy { $0.isHidden }
                let ids = viewModel.selectedAssetIDs
                Task { try? await viewModel.setHidden(ids, hidden: !allHidden) }
            } label: {
                let allHidden = viewModel.assets
                    .filter { viewModel.selectedAssetIDs.contains($0.id) }
                    .allSatisfy { $0.isHidden }
                Label(allHidden ? "Unhide" : "Hide", systemImage: allHidden ? "eye" : "eye.slash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.selectedAssetIDs.isEmpty)
            .padding(.trailing, 8)

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.selectedAssetIDs.isEmpty)
            .padding(.trailing, 8)

            Button {
                viewModel.selectedAssetIDs = []
                viewModel.isSelectMode = false
            } label: {
                Text("Done")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)
            .controlSize(.small)
            .padding(.trailing, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(.thinMaterial)
        .overlay(alignment: .top) {
            Divider()
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
