import SwiftUI
import ImageAssetManagerCore

struct PostGenerationView: View {
    @Bindable var viewModel: GenerationViewModel
    @Binding var isConfirming: Bool
    @Binding var confirmError: String?

    var body: some View {
        #if os(macOS)
        HSplitView {
            imagePreview
                .frame(minWidth: 300)
            metadataForm
                .frame(width: 280)
        }
        #else
        ScrollView {
            VStack(spacing: 0) {
                imagePreview
                    .frame(maxHeight: 300)
                metadataForm
            }
        }
        #endif
    }

    // MARK: - Image Preview

    @ViewBuilder
    private var imagePreview: some View {
        ZStack {
            Color.imageMatte.ignoresSafeArea()
            if let image = generatedSwiftUIImage {
                image
                    .resizable()
                    .scaledToFit()
                    .padding(16)
            } else {
                ProgressView()
                    .tint(Color.appAccent)
            }
        }
    }

    private var generatedSwiftUIImage: Image? {
        guard let data = viewModel.generatedImage?.data else { return nil }
        #if os(macOS)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }

    // MARK: - Metadata Form

    private var metadataForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                formSection("Tags") {
                    tagEditor
                }

                Divider().overlay(Color.appBorder)

                formSection("Collection") {
                    collectionPicker
                }

                Divider().overlay(Color.appBorder)

                formSection("Variant Family") {
                    variantFamilyPicker
                }

                Divider().overlay(Color.appBorder)

                formSection("Prompt Library") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Save to prompt library", isOn: $viewModel.saveToPromptLibrary)
                            .toggleStyle(.switch)
                            .tint(Color.appAccent)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.appTextPrimary)
                        if viewModel.saveToPromptLibrary {
                            TextField("Prompt title", text: $viewModel.promptLibraryTitle)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.appTextPrimary)
                                .padding(8)
                                .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                Divider().overlay(Color.appBorder)

                // Error
                if let error = confirmError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                actionButtons
                    .padding(16)
            }
        }
        .background(Color.appSurface)
    }

    @ViewBuilder
    private func formSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.appTextSecondary)
                .kerning(0.5)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            content()
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    // MARK: - Tag Editor

    private var tagEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !viewModel.pendingTags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(viewModel.pendingTags, id: \.self) { tag in
                        tagChip(tag)
                    }
                }
            }
            HStack(spacing: 6) {
                TextField("Add tag…", text: $viewModel.tagInputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appTextPrimary)
                    .onSubmit { viewModel.addTagFromInput() }
                    .padding(6)
                    .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 6))
                Button {
                    viewModel.addTagFromInput()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func tagChip(_ tag: String) -> some View {
        HStack(spacing: 3) {
            Text(tag)
                .font(.system(size: 11))
                .foregroundStyle(Color.appTextPrimary)
            Button {
                viewModel.removeTag(tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.appTextSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.appSurfaceRaised, in: Capsule())
    }

    // MARK: - Variant Family Picker

    /// TextField for free-form entry, plus a Menu of existing families scoped to the current
    /// project (or orphan families when no project is selected). Leaving the field blank is
    /// allowed — the ViewModel derives a default name from the prompt at confirm time.
    private var variantFamilyPicker: some View {
        HStack(spacing: 6) {
            TextField("Family name (leave blank for default)", text: $viewModel.selectedVariantFamilyName)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.appTextPrimary)
                .padding(8)
                .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 6))

            if !viewModel.existingVariantFamilyNames.isEmpty {
                Menu {
                    ForEach(viewModel.existingVariantFamilyNames, id: \.self) { name in
                        Button(name) { viewModel.selectedVariantFamilyName = name }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.appTextSecondary)
                        .padding(8)
                        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Pick an existing family")
            }
        }
    }

    // MARK: - Collection Picker

    private var collectionPicker: some View {
        Picker("Collection", selection: $viewModel.selectedCollectionID) {
            Text("None").tag(nil as String?)
            ForEach(viewModel.collections, id: \.id) { col in
                Text(col.name).tag(col.id as String?)
            }
        }
        .pickerStyle(.menu)
        .font(.system(size: 13))
        .foregroundStyle(Color.appTextPrimary)
        .tint(Color.appTextPrimary)
        .labelsHidden()
        .padding(6)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button("Discard") {
                viewModel.discardGeneration()
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(isConfirming)

            Button {
                isConfirming = true
                confirmError = nil
                Task {
                    do {
                        try await viewModel.confirmGeneration()
                    } catch {
                        confirmError = error.localizedDescription
                    }
                    isConfirming = false
                }
            } label: {
                if isConfirming {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Saving…")
                    }
                } else {
                    Text("Confirm")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isConfirming)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Button Styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.appAccent.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Color.appTextPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.appSurfaceRaised.opacity(configuration.isPressed ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Flow Layout (for tag chips)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(subviews: subviews, in: proposal.width ?? 0)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews: subviews, in: bounds.width)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func layout(subviews: Subviews, in width: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxWidth = max(maxWidth, x - spacing)
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), frames)
    }
}
