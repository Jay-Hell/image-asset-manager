import SwiftUI
import ImageAssetManagerCore

struct GenerationPanelView: View {
    @Bindable var viewModel: GenerationViewModel
    @State private var showPromptPicker = false
    @State private var isConfirming = false
    @State private var confirmError: String?
    @State private var showRefinementPanel = false
    @State private var refinementSession: PromptRefinementSession?
    @State private var showRefinementSheet = false

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            if viewModel.generatedImage != nil {
                PostGenerationView(
                    viewModel: viewModel,
                    isConfirming: $isConfirming,
                    confirmError: $confirmError
                )
                .transition(.opacity)
            } else {
                inputForm
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.generatedImage != nil)
        .onChange(of: viewModel.selectedProjectID) { _, _ in
            Task { await viewModel.projectSelectionChanged() }
        }
        .onChange(of: viewModel.selectedProviderID) { _, _ in
            viewModel.providerSelectionChanged()
        }
        .sheet(isPresented: $showPromptPicker) {
            PromptLibraryPickerView(viewModel: viewModel)
        }
        .sheet(isPresented: $showRefinementSheet) {
            if let session = refinementSession {
                RefinementSheetView(session: session) {
                    acceptRefinement(session: session)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 580)
        #endif
    }

    // MARK: - Input Form

    private var inputForm: some View {
        VStack(spacing: 0) {
            // Progress bar shown during generation
            if viewModel.isGenerating {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Color.appAccent)
                    .padding(.horizontal, 0)
                    .frame(height: 2)
            } else {
                Divider().frame(height: 2).opacity(0)
            }

            ScrollView {
                VStack(spacing: 0) {
                    projectProviderHeader
                    Divider().overlay(Color.appBorder)

                    if !viewModel.referenceEntries.isEmpty,
                       viewModel.currentProvider?.supportsReferenceImages == true {
                        ReferencePanelView(viewModel: viewModel)
                        Divider().overlay(Color.appBorder)
                    }

                    promptSection
                    Divider().overlay(Color.appBorder)
                    aspectRatioSection
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider().overlay(Color.appBorder)
            generationFooter
        }
    }

    // MARK: - Project / Provider Header

    private var additionalProjectsRow: some View {
        let addable = viewModel.projects.filter {
            $0.id != viewModel.selectedProjectID && !viewModel.additionalProjectIDs.contains($0.id)
        }
        return HStack(spacing: 4) {
            ForEach(viewModel.projects.filter { viewModel.additionalProjectIDs.contains($0.id) }, id: \.id) { project in
                HStack(spacing: 3) {
                    Text(project.name).font(.caption)
                    Button {
                        viewModel.additionalProjectIDs.remove(project.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appTextSecondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.appSurfaceRaised, in: Capsule())
            }
            if !addable.isEmpty {
                Menu {
                    ForEach(addable, id: \.id) { p in
                        Button(p.name) { viewModel.additionalProjectIDs.insert(p.id) }
                    }
                } label: {
                    Label("Add…", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appSurfaceRaised, in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Also add to another project")
            }
        }
    }

    private var projectProviderHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                // Project (primary + additional)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PROJECT")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.appTextSecondary)
                        .kerning(0.5)
                    Picker("Project", selection: $viewModel.selectedProjectID) {
                        Text("No Project").tag(nil as String?)
                        ForEach(viewModel.projects, id: \.id) { project in
                            Text(project.name).tag(project.id as String?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(Color.appTextPrimary)
                    .font(.system(size: 13))
                    additionalProjectsRow
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Provider
                VStack(alignment: .leading, spacing: 3) {
                    Text("PROVIDER")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.appTextSecondary)
                        .kerning(0.5)
                    Picker("Provider", selection: $viewModel.selectedProviderID) {
                        ForEach(viewModel.availableProviders, id: \.providerID) { p in
                            Text(p.displayName).tag(p.providerID as String?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(Color.appTextPrimary)
                    .font(.system(size: 13))
                }

                // Model
                VStack(alignment: .leading, spacing: 3) {
                    Text("MODEL")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.appTextSecondary)
                        .kerning(0.5)
                    Picker("Model", selection: $viewModel.selectedModelID) {
                        ForEach(viewModel.currentProvider?.availableModels ?? [], id: \.id) { model in
                            Text(model.displayName).tag(model.id as String?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(Color.appTextPrimary)
                    .font(.system(size: 13))
                }
            }

            if let note = viewModel.modelRouteNote {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                    Text(note)
                        .font(.system(size: 11))
                }
                .foregroundStyle(Color.appAccent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.appSurface)
    }

    // MARK: - Prompt Section

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PROMPT")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.appTextSecondary)
                    .kerning(0.5)
                Spacer()
                Button {
                    openRefinementPanel()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text("Refine")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(showRefinementPanel ? .white : Color.appAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        showRefinementPanel ? Color.appAccent : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                }
                .buttonStyle(.plain)
                .help("Refine prompt with Claude AI")

                Button {
                    showPromptPicker = true
                } label: {
                    Label("Load from Library", systemImage: "text.quote")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .keyboardShortcut("p", modifiers: .command)
                #endif
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            TextEditor(text: $viewModel.promptText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.appTextPrimary)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color.appSurface)
                .frame(minHeight: 100, idealHeight: 120)
                .overlay(alignment: .topLeading) {
                    if viewModel.promptText.isEmpty {
                        Text("Describe the image…")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.appTextSecondary)
                            .allowsHitTesting(false)
                            .padding(14)
                    }
                }

            // Inline refinement panel (macOS only — iPad uses sheet)
            #if os(macOS)
            if showRefinementPanel, let session = refinementSession {
                RefinementPanelView(
                    session: session,
                    onAccept: { acceptRefinement(session: session) },
                    onDismiss: { showRefinementPanel = false }
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .onChange(of: session.draftPrompt) { _, newDraft in
                    viewModel.promptText = newDraft
                }
            }
            #endif

            // Negative prompt toggle + field
            Button {
                viewModel.showNegativePrompt.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.showNegativePrompt ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                    Text("Negative Prompt")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Color.appTextSecondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if viewModel.showNegativePrompt {
                TextEditor(text: $viewModel.negativePromptText)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.appTextPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color.appSurface)
                    .frame(minHeight: 60, idealHeight: 72)
                    .overlay(alignment: .topLeading) {
                        if viewModel.negativePromptText.isEmpty {
                            Text("What to avoid…")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(Color.appTextSecondary)
                                .allowsHitTesting(false)
                                .padding(14)
                        }
                    }
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Aspect Ratio Section

    private var aspectRatioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ASPECT RATIO")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.appTextSecondary)
                .kerning(0.5)

            HStack(spacing: 6) {
                ForEach([AspectRatio.square, .landscape, .portrait, .custom], id: \.self) { ratio in
                    Button {
                        viewModel.aspectRatio = ratio
                    } label: {
                        Text(label(for: ratio))
                            .font(.system(size: 12, weight: viewModel.aspectRatio == ratio ? .semibold : .regular))
                            .foregroundStyle(viewModel.aspectRatio == ratio ? .white : Color.appTextSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                viewModel.aspectRatio == ratio
                                    ? Color.appAccent
                                    : Color.appSurfaceRaised,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if viewModel.aspectRatio == .custom {
                HStack(spacing: 8) {
                    TextField("W", value: $viewModel.customWidth, format: .number)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.appTextPrimary)
                        .frame(width: 70)
                        .padding(6)
                        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 6))
                    Text("×")
                        .foregroundStyle(Color.appTextSecondary)
                    TextField("H", value: $viewModel.customHeight, format: .number)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.appTextPrimary)
                        .frame(width: 70)
                        .padding(6)
                        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 6))
                }
            } else {
                Text(viewModel.dimensionLabel)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Generation Footer

    private var generationFooter: some View {
        HStack {
            // Cost estimate pill
            if viewModel.estimatedCost > 0 {
                Text("~\(viewModel.estimatedCost, format: .currency(code: "GBP"))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.appTextSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.appSurfaceRaised, in: Capsule())
            }

            Spacer()

            // Error message
            if let error = viewModel.generationError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Button {
                Task { await viewModel.generate() }
            } label: {
                HStack(spacing: 6) {
                    if viewModel.isGenerating {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                    Text(viewModel.isGenerating ? "Generating…" : "Generate")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(
                    viewModel.canGenerate ? Color.appAccent : Color.appSurfaceRaised,
                    in: RoundedRectangle(cornerRadius: 8)
                )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canGenerate)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.appSurface)
    }

    // MARK: - Refinement helpers

    private func openRefinementPanel() {
        #if os(macOS)
        if showRefinementPanel {
            showRefinementPanel = false
            return
        }
        #endif
        let project = viewModel.projects.first(where: { $0.id == viewModel.selectedProjectID })
        let refs = viewModel.referenceEntries.map { entry in
            ReferenceContextItem(role: entry.role, notes: entry.notes)
        }
        let context = RefinementContext(
            projectName: project?.name ?? "No Project",
            clientName: project?.clientName,
            activeReferences: refs,
            similarPrompts: [],
            aspectRatio: viewModel.aspectRatio.rawValue,
            modelName: viewModel.currentModel?.displayName ?? "Unknown"
        )
        let session = PromptRefinementSession(draft: viewModel.promptText, context: context)
        refinementSession = session

        Task {
            let similar = (try? await viewModel.database.findSimilarPrompts(to: viewModel.promptText)) ?? []
            session.context.similarPrompts = similar
        }

        #if os(macOS)
        showRefinementPanel = true
        #else
        showRefinementSheet = true
        #endif
    }

    private func acceptRefinement(session: PromptRefinementSession) {
        viewModel.promptText = session.refinedPrompt
        viewModel.pendingRefinement = GenerationViewModel.PendingRefinement(
            mode: session.mode.rawValue.lowercased(),
            draftPrompt: session.draftPrompt,
            conversationJSON: session.conversationJSON(),
            modelUsed: AnthropicClient.defaultModel,
            finalPrompt: session.refinedPrompt
        )
        showRefinementPanel = false
        showRefinementSheet = false
    }

    // MARK: - Aspect ratio helpers

    private func label(for ratio: AspectRatio) -> String {
        switch ratio {
        case .square:    return "Square"
        case .landscape: return "Landscape"
        case .portrait:  return "Portrait"
        case .custom:    return "Custom"
        }
    }
}
