import SwiftUI
import ImageAssetManagerCore

struct PromptDetailView: View {
    let prompt: Prompt
    let linkedAssets: [Asset]
    let libraryURL: URL
    var onEdit: () -> Void
    var onDelete: () -> Void

    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                promptBodySection
                if let neg = prompt.negativePrompt, !neg.isEmpty {
                    negativeSectionView(neg)
                }
                if let tagsJSON = prompt.tags, !tagsJSON.isEmpty {
                    tagsSection(tagsJSON)
                }
                Divider()
                statsRow
                if !linkedAssets.isEmpty {
                    Divider()
                    linkedAssetsSection
                }
            }
            .padding(16)
        }
        .background(Color.appSurface)
        .confirmationDialog("Delete this prompt?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The markdown file will also be removed from your prompts folder.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(prompt.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.appTextPrimary)
                if let sector = prompt.sector {
                    Text(sector)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.appSurfaceRaised, in: Capsule())
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Button("Edit", action: onEdit)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var promptBodySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Prompt")
            Text(prompt.body)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.appTextPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func negativeSectionView(_ neg: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Negative Prompt")
            Text(neg)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Color.appTextSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tagsSection(_ tagsJSON: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Tags")
            Text(
                tagsJSON
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .replacingOccurrences(of: "\"", with: "")
            )
            .font(.caption)
            .foregroundStyle(Color.appTextSecondary)
        }
    }

    private var statsRow: some View {
        HStack(spacing: 24) {
            statItem(label: "Uses", value: "\(prompt.usageCount)")
            if let last = prompt.lastUsedAt {
                statItem(label: "Last used", value: String(last.prefix(10)))
            }
            statItem(label: "Created", value: String(prompt.createdAt.prefix(10)))
        }
    }

    private var linkedAssetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Generated with this prompt")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(linkedAssets, id: \.id) { asset in
                        LocalImage(
                            url: libraryURL
                                .appending(path: "assets")
                                .appending(path: asset.filename)
                        )
                        .frame(width: 64, height: 64)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(Color.appTextSecondary)
            .textCase(.uppercase)
    }

    private func statItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.appTextSecondary)
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.appTextPrimary)
        }
    }
}
