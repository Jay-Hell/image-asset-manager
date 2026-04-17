import SwiftUI
import ImageAssetManagerCore

struct InspectorPanelView: View {
    let detail: AssetDetail
    let libraryURL: URL
    var onTagsChanged: ([String]) -> Void
    var onDelete: () -> Void
    var onRegenerate: () -> Void
    var onExport: () -> Void
    var onPromoteVariant: (String, String) -> Void

    @State private var editingTags: Bool = false
    @State private var tagEditText: String = ""
    @State private var showDeleteConfirmation: Bool = false

    private var fileURL: URL {
        libraryURL.appending(path: "assets").appending(path: detail.asset.filename)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LocalImage(url: fileURL)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.imageMatte)
                    .accessibilityLabel(detail.asset.prompt ?? detail.asset.filename)
                    .accessibilityAddTraits(.isImage)

                VStack(alignment: .leading, spacing: 16) {
                    actionBar

                    metadataSection

                    Divider()

                    if let prompt = detail.asset.prompt {
                        promptSection(prompt)
                        Divider()
                    }

                    tagsSection

                    if !detail.references.isEmpty {
                        Divider()
                        referencesSection
                    }

                    if let (variant, members) = detail.variantContext, members.count > 1 {
                        Divider()
                        variantSection(variant: variant, members: members)
                    }

                    if !detail.usage.isEmpty {
                        Divider()
                        usageSection
                    }

                    if let refinement = detail.refinement {
                        Divider()
                        refinementSection(refinement)
                    }
                }
                .padding(12)
            }
        }
        .background(Color.appSurface)
        .confirmationDialog("Delete this asset?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. The image file will also be removed.")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button("Re-generate", action: onRegenerate)
                .buttonStyle(.bordered)
                .inspectorButtonStyle()
                .accessibilityLabel("Re-generate this asset")
                .accessibilityHint("Opens generation panel pre-filled with this asset's prompt")
            #if os(macOS)
            Button("Export…", action: onExport)
                .buttonStyle(.bordered)
                .inspectorButtonStyle()
                .accessibilityLabel("Export this asset")
                .accessibilityHint("Opens the export sheet to save a copy")
            #endif
            Spacer()
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .inspectorButtonStyle()
            .accessibilityLabel("Delete asset")
            .accessibilityHint("Permanently removes this asset and its file")
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Details")
            labeledRow("Provider", detail.asset.providerID)
            labeledRow("Model", detail.asset.modelID)
            if let w = detail.asset.width, let h = detail.asset.height {
                labeledRow("Dimensions", "\(w) × \(h)")
            }
            if let cost = detail.asset.estimatedCost {
                labeledRow("Est. cost", String(format: "$%.4f", cost))
            }
            labeledRow("Created", String(detail.asset.createdAt.prefix(10)))
        }
    }

    private func promptSection(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Prompt")
            Text(prompt)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.appTextPrimary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let neg = detail.asset.negativePrompt {
                Text("Negative: \(neg)")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.appTextSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("Tags")
                Spacer()
                Button(editingTags ? "Done" : "Edit") {
                    if editingTags {
                        let names = tagEditText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        onTagsChanged(names)
                    } else {
                        tagEditText = detail.tags.map(\.name).joined(separator: ", ")
                    }
                    editingTags.toggle()
                }
                .controlSize(.mini)
                .buttonStyle(.plain)
                .foregroundStyle(Color.appAccent)
            }

            if editingTags {
                TextField("tag1, tag2, tag3", text: $tagEditText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            } else if detail.tags.isEmpty {
                Text("No tags")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            } else {
                InspectorFlowLayout {
                    ForEach(detail.tags, id: \.id) { tag in
                        Text(tag.name)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.appSurfaceRaised, in: Capsule())
                            .foregroundStyle(Color.appTextPrimary)
                    }
                }
            }
        }
    }

    private var referencesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("References Used")
            ForEach(detail.references, id: \.0.id) { ref, refAsset in
                HStack(spacing: 8) {
                    if let asset = refAsset {
                        LocalImage(url: libraryURL.appending(path: "assets").appending(path: asset.filename))
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if let role = ref.roleUsed {
                            Text(role.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.appAccent)
                        }
                        if let weight = ref.weightUsed {
                            Text("Weight: \(String(format: "%.1f", weight))")
                                .font(.caption2)
                                .foregroundStyle(Color.appTextSecondary)
                        }
                    }
                }
            }
        }
    }

    private func variantSection(variant: Variant, members: [(VariantMember, Asset)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Variant Family: \(variant.name)")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(members, id: \.0.id) { member, asset in
                        let isCurrentAsset = asset.id == detail.asset.id
                        let thumbURL = libraryURL.appending(path: "assets").appending(path: asset.filename)

                        ZStack(alignment: .bottomLeading) {
                            LocalImage(url: thumbURL)
                                .frame(width: 56, height: 56)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                            Text("\(member.sequence)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 14, height: 14)
                                .background(
                                    member.isSelected ? Color.appAccent : Color.black.opacity(0.6),
                                    in: Circle()
                                )
                                .padding(2)
                        }
                        .overlay {
                            if isCurrentAsset {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.appAccent, lineWidth: 2)
                            }
                        }
                        .onTapGesture { onPromoteVariant(member.id, variant.id) }
                        .help("Promote to selected")
                    }
                }
            }
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Usage")
            ForEach(detail.usage, id: \.id) { usage in
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.appAccent)
                        .font(.caption)
                    Text(usage.usedIn ?? "Unknown")
                        .font(.caption)
                        .foregroundStyle(Color.appTextPrimary)
                    Spacer()
                    if let at = usage.usedAt {
                        Text(String(at.prefix(10)))
                            .font(.caption2)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
            }
        }
    }

    private func refinementSection(_ refinement: PromptRefinement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(refinement.mode.capitalized)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.appAccent, in: Capsule())
                        Text(refinement.modelUsed)
                            .font(.caption2)
                            .foregroundStyle(Color.appTextSecondary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Draft")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.appTextSecondary)
                        Text(refinement.draftPrompt)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    let turns = refinement.parsedConversation
                    if !turns.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Conversation")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.appTextSecondary)
                            ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                                HStack(alignment: .top, spacing: 4) {
                                    Text(turn.role == "user" ? "👤" : "🤖")
                                        .font(.system(size: 11))
                                    Text(turn.content)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.appTextPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                sectionHeader("Prompt Refinement")
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.appTextSecondary)
            .textCase(.uppercase)
            .kerning(0.3)
    }

    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.appTextSecondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(Color.appTextPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Shared button style modifier

private extension View {
    func inspectorButtonStyle() -> some View {
        self
            .controlSize(.regular)
            #if os(macOS)
            .frame(minHeight: 28)
            #else
            .frame(minHeight: 44)
            #endif
    }
}

struct InspectorFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 200
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
