import SwiftUI
import ImageAssetManagerCore
#if os(macOS)
import AppKit
#endif

struct AssetGridView: View {
    @Bindable var viewModel: LibraryViewModel
    var onGenerate: () -> Void

    @State private var showDeleteConfirmation: Bool = false
    @State private var showClearProjectsConfirmation: Bool = false
    @State private var showClearTagsConfirmation: Bool = false
    @State private var showNewTagSheet: Bool = false
    @State private var newTagName: String = ""
    /// A filing that failed, shown in an alert rather than looking like nothing happened.
    @State private var filingError: String?
    #if os(macOS)
    @FocusState private var gridFocused: Bool
    #endif

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
                                isSelected: { isMacSelected($0) },
                                onSelect: { assetID in
                                    #if os(macOS)
                                    // ⌘ and ⇧ work on a filmstrip member as on a grid image; the range runs in screen order.
                                    gridFocused = true
                                    let order = viewModel.displayedOrder
                                    Task { await viewModel.click(assetID, Self.clickKindFromModifiers(), order: order) }
                                    #else
                                    Task { await viewModel.selectAsset(assetID) }
                                    #endif
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
            #if os(macOS)
            // ⌘A selects every image in the view and Esc clears, while the grid has focus (a click on an image gives it).
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onKeyPress(.escape) {
                guard !viewModel.selection.selected.isEmpty else { return .ignored }
                Task { await viewModel.clearSelection() }
                return .handled
            }
            .onKeyPress(keys: [KeyEquivalent("a")]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                let order = viewModel.displayedOrder
                Task { await viewModel.selectAll(order: order) }
                return .handled
            }
            #endif
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
        .alert("Filing Failed", isPresented: .init(
            get: { filingError != nil },
            set: { if !$0 { filingError = nil } }
        )) {
            Button("OK") { filingError = nil }
        } message: {
            Text(filingError ?? "")
        }
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
        .confirmationDialog(
            "Remove all projects from \(viewModel.selectedAssetIDs.count) asset\(viewModel.selectedAssetIDs.count == 1 ? "" : "s")?",
            isPresented: $showClearProjectsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Projects", role: .destructive) {
                let ids = viewModel.selectedAssetIDs
                Task { try? await viewModel.bulkClearProjects(ids: ids) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The assets themselves remain, but every project membership is removed.")
        }
        .confirmationDialog(
            "Remove all tags from \(viewModel.selectedAssetIDs.count) asset\(viewModel.selectedAssetIDs.count == 1 ? "" : "s")?",
            isPresented: $showClearTagsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Tags", role: .destructive) {
                let ids = viewModel.selectedAssetIDs
                Task { try? await viewModel.bulkClearTags(ids: ids) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The assets themselves remain, but every tag is removed.")
        }
        .sheet(isPresented: $showNewTagSheet) {
            newTagSheet
        }
    }

    /// Inline sheet for creating a new tag and attaching it to the selection in one step.
    /// Short because it's a single field — no reason to navigate elsewhere for this.
    private var newTagSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Tag")
                .font(.headline)
            Text("Creates the tag if it doesn't exist and adds it to \(viewModel.selectedAssetIDs.count) asset\(viewModel.selectedAssetIDs.count == 1 ? "" : "s").")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
            TextField("Tag name", text: $newTagName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitNewTag() }
            HStack {
                Spacer()
                Button("Cancel") { showNewTagSheet = false }
                    .buttonStyle(.bordered)
                Button("Add") { commitNewTag() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
    }

    private func commitNewTag() {
        let trimmed = newTagName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let ids = viewModel.selectedAssetIDs
        Task { try? await viewModel.bulkAddTag(ids: ids, tagName: trimmed) }
        showNewTagSheet = false
    }

    // MARK: - Selectable cell

    #if os(macOS)
    /// The click kind the modifier keys held right now give.
    private static func clickKindFromModifiers() -> GridSelection.Click {
        let flags = NSEvent.modifierFlags
        return flags.contains(.command) ? .command : flags.contains(.shift) ? .shift : .plain
    }
    #endif

    /// macOS: the image is in the Mac selection. Elsewhere: it is the one the inspector shows.
    private func isMacSelected(_ id: String) -> Bool {
        #if os(macOS)
        viewModel.selection.selected.contains(id)
        #else
        viewModel.selectedAssetID == id
        #endif
    }

    @ViewBuilder
    private func selectableCell(asset: Asset) -> some View {
        ZStack(alignment: .topTrailing) {
            AssetThumbnailView(
                asset: asset,
                libraryURL: viewModel.libraryURL,
                isSelected: !viewModel.isSelectMode && isMacSelected(asset.id)
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
            .contextMenu {
                if !viewModel.projects.isEmpty {
                    // A selected asset's menu acts on the whole selection (ticked, or Mac-selected).
                    filingMenus(for: viewModel.selection.actedOn(asset.id))
                }
            }
            // Dragging a selected image drags the whole selection; an unselected one drags alone.
            .draggable(SidebarDrag.images(viewModel.selection.actedOn(asset.id).sorted()))
            .onTapGesture {
                if viewModel.isSelectMode {
                    if viewModel.selectedAssetIDs.contains(asset.id) {
                        viewModel.selectedAssetIDs.remove(asset.id)
                    } else {
                        viewModel.selectedAssetIDs.insert(asset.id)
                    }
                } else {
                    #if os(macOS)
                    gridFocused = true
                    let kind = Self.clickKindFromModifiers()
                    let order = viewModel.displayedOrder
                    Task { await viewModel.click(asset.id, kind, order: order) }
                    #else
                    Task { await viewModel.selectAsset(asset.id) }
                    #endif
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

    /// "Add to project…" keeps each asset's other projects; "Move to project…" replaces them.
    /// Both go through Core's `fileAssets`, so a variant family follows its members.
    @ViewBuilder
    private func filingMenus(for ids: Set<String>) -> some View {
        ForEach(FilingMode.allCases, id: \.self) { mode in
            Menu(mode == .add ? "Add to project…" : "Move to project…") {
                ForEach(viewModel.projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, id: \.id) { project in
                    Button(project.name) {
                        Task {
                            do {
                                try await viewModel.file(ids, to: project.id, mode: mode)
                            } catch {
                                filingError = error.localizedDescription
                            }
                        }
                    }
                }
            }
        }
    }

    /// Bulk project assignment menu: add a single project to every checked asset, or
    /// wipe every project membership from them. Disabled when no assets are selected.
    private var projectsMenu: some View {
        Menu {
            if viewModel.projects.isEmpty {
                Text("No projects — use New project… in the sidebar")
            } else {
                filingMenus(for: viewModel.selectedAssetIDs)
                Divider()
                Button("Clear All Projects", role: .destructive) {
                    showClearProjectsConfirmation = true
                }
            }
        } label: {
            Label("Projects", systemImage: "folder.badge.plus")
        }
        #if os(macOS)
        .menuStyle(.borderedButton)
        #endif
        .controlSize(.small)
        .disabled(viewModel.selectedAssetIDs.isEmpty)
        .fixedSize()
    }

    /// Bulk tag assignment menu. Supports adding an existing tag, creating a new one inline,
    /// or clearing every tag from the selected assets.
    private var tagsMenu: some View {
        Menu {
            Menu("Add tag…") {
                Button {
                    newTagName = ""
                    showNewTagSheet = true
                } label: {
                    Label("New tag…", systemImage: "plus")
                }
                if !viewModel.tagsWithCounts.isEmpty {
                    Divider()
                    ForEach(viewModel.tagsWithCounts, id: \.0.id) { tag, _ in
                        Button(tag.name) {
                            let ids = viewModel.selectedAssetIDs
                            Task { try? await viewModel.bulkAddTag(ids: ids, tagName: tag.name) }
                        }
                    }
                }
            }
            Divider()
            Button("Clear All Tags", role: .destructive) {
                showClearTagsConfirmation = true
            }
        } label: {
            Label("Tags", systemImage: "tag")
        }
        #if os(macOS)
        .menuStyle(.borderedButton)
        #endif
        .controlSize(.small)
        .disabled(viewModel.selectedAssetIDs.isEmpty)
        .fixedSize()
    }

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

            projectsMenu
                .padding(.trailing, 8)

            tagsMenu
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
