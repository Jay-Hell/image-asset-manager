import SwiftUI
import ImageAssetManagerCore

struct PromptLibraryView: View {
    @Bindable var viewModel: PromptViewModel
    var onGenerate: ((Prompt) -> Void)? = nil

    var body: some View {
        NavigationSplitView {
            promptSidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 340)
        } detail: {
            if let promptID = viewModel.selectedPromptID,
               let prompt = viewModel.prompts.first(where: { $0.id == promptID }) {
                PromptDetailView(
                    prompt: prompt,
                    linkedAssets: viewModel.linkedAssets,
                    libraryURL: viewModel.libraryURL,
                    onEdit: { viewModel.startEdit(prompt) },
                    onDelete: { Task { try? await viewModel.deletePrompt(promptID) } }
                )
            } else {
                Color.appBackground.ignoresSafeArea()
                    .overlay {
                        Text("Select a prompt to view")
                            .foregroundStyle(Color.appTextSecondary)
                            .font(.callout)
                    }
            }
        }
        .background(Color.appBackground)
        .sheet(isPresented: $viewModel.showEditor) {
            PromptEditorView(
                prompt: viewModel.editingPrompt,
                sectors: viewModel.sectors,
                onSave: { id, title, body, neg, sector, tags in
                    Task {
                        try? await viewModel.savePrompt(
                            id: id, title: title, body: body,
                            negativePrompt: neg, sector: sector, tags: tags
                        )
                    }
                }
            )
        }
        .task { await viewModel.loadPrompts() }
    }

    private var promptSidebar: some View {
        VStack(spacing: 0) {
            if !viewModel.sectors.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        sectorChip(label: "All", isSelected: viewModel.selectedSector == nil) {
                            viewModel.selectedSector = nil
                        }
                        ForEach(viewModel.sectors, id: \.self) { sector in
                            sectorChip(label: sector, isSelected: viewModel.selectedSector == sector) {
                                viewModel.selectedSector = viewModel.selectedSector == sector ? nil : sector
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                Divider()
            }

            Group {
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.prompts.isEmpty {
                    emptyState
                } else {
                    List(viewModel.prompts, id: \.id, selection: $viewModel.selectedPromptID) { prompt in
                        promptRow(prompt)
                            .tag(prompt.id)
                            .listRowBackground(Color.appSurface)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.appBackground)
                }
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search prompts")
        .onSubmit(of: .search) { Task { await viewModel.loadPrompts() } }
        .onChange(of: viewModel.searchText) { old, new in
            if new.isEmpty && !old.isEmpty { Task { await viewModel.loadPrompts() } }
        }
        .onChange(of: viewModel.selectedSector) { _, _ in
            Task { await viewModel.loadPrompts() }
        }
        .onChange(of: viewModel.selectedPromptID) { _, id in
            guard let id else { return }
            Task { await viewModel.selectPrompt(id) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.startCreate()
                } label: {
                    Label("New Prompt", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New Prompt (⌘N)")
            }
        }
    }

    private func sectorChip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? .white : Color.appTextPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? Color.appAccent : Color.appSurfaceRaised, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func promptRow(_ prompt: Prompt) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(prompt.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                if let sector = prompt.sector {
                    Text(sector)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.appTextSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appSurfaceRaised, in: Capsule())
                }
                if let onGenerate {
                    Button {
                        onGenerate(prompt)
                    } label: {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Generate image from this prompt")
                }
            }
            Text(prompt.body)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.appTextSecondary)
                .lineLimit(2)
            HStack(spacing: 4) {
                Image(systemName: "wand.and.stars")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextSecondary)
                Text("\(prompt.usageCount) use\(prompt.usageCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextSecondary)
                if let lastUsed = prompt.lastUsedAt {
                    Text("· \(String(lastUsed.prefix(10)))")
                        .font(.caption2)
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .swipeActions(edge: .leading) {
            if onGenerate != nil {
                Button {
                    onGenerate?(prompt)
                } label: {
                    Label("Generate", systemImage: "wand.and.stars")
                }
                .tint(Color.appAccent)
            }
        }
        .contextMenu {
            if onGenerate != nil {
                Button {
                    onGenerate?(prompt)
                } label: {
                    Label("Generate Image", systemImage: "wand.and.stars")
                }
                Divider()
            }
            Button("Edit") { viewModel.startEdit(prompt) }
            Divider()
            Button("Delete", role: .destructive) {
                Task { try? await viewModel.deletePrompt(prompt.id) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: viewModel.searchText.isEmpty ? "text.quote" : "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(Color.appTextSecondary)
                .accessibilityHidden(true)
            Text(viewModel.searchText.isEmpty ? "No prompts yet" : "No prompts match")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(Color.appTextPrimary)
            if viewModel.searchText.isEmpty {
                Text("Save prompts during generation, or create them here.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
                Button("New Prompt") { viewModel.startCreate() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .controlSize(.regular)
                    .accessibilityLabel("Create new prompt")
            } else {
                Text("Try a different search term.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
