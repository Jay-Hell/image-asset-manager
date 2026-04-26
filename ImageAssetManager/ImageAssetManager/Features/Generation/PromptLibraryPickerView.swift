import SwiftUI
import ImageAssetManagerCore

struct PromptLibraryPickerView: View {
    @Bindable var viewModel: GenerationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredPrompts: [Prompt] {
        guard !searchText.isEmpty else { return viewModel.allPrompts }
        let q = searchText.lowercased()
        return viewModel.allPrompts.filter {
            $0.title.lowercased().contains(q)
            || $0.body.lowercased().contains(q)
            || ($0.sector?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredPrompts.isEmpty {
                    emptyState
                } else {
                    promptList
                }
            }
            .navigationTitle("Prompt Library")
            #if os(macOS)
            .navigationSubtitle("\(viewModel.allPrompts.count) prompts")
            #endif
            .searchable(text: $searchText, prompt: "Search prompts…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
        .background(Color.appBackground)
    }

    private var promptList: some View {
        List(filteredPrompts, id: \.id) { prompt in
            Button {
                Task { await viewModel.applyPrompt(prompt) }
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(prompt.title)
                            .font(.system(size: 13, weight: .medium))
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
                        Text("\(prompt.usageCount)×")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    Text(prompt.body)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.appTextSecondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.appSurface)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.quote")
                .font(.system(size: 40))
                .foregroundStyle(Color.appTextSecondary)
            Text(searchText.isEmpty ? "No prompts saved yet" : "No prompts match your search")
                .font(.system(size: 15))
                .foregroundStyle(Color.appTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
