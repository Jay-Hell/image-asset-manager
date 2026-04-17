import SwiftUI
import ImageAssetManagerCore

enum AppTab {
    case library
    case prompts
}

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var libraryVM: LibraryViewModel?
    @State private var generationVM: GenerationViewModel?
    @State private var promptVM: PromptViewModel?
    @State private var showGenerationSheet: Bool = false
    @State private var activeTab: AppTab = .library

    var body: some View {
        Group {
            if let libraryVM, let generationVM, let promptVM {
                activeView(libraryVM: libraryVM, generationVM: generationVM, promptVM: promptVM)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Picker("View", selection: $activeTab) {
                                Label("Library", systemImage: "photo.stack")
                                    .tag(AppTab.library)
                                Label("Prompts", systemImage: "text.quote")
                                    .tag(AppTab.prompts)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }
                    }
                    .sheet(isPresented: $showGenerationSheet) {
                        GenerationPanelView(viewModel: generationVM)
                            #if os(macOS)
                            .frame(width: 840, height: 700)
                            #endif
                    }
                    .onChange(of: showGenerationSheet) { _, isShowing in
                        guard !isShowing else { return }
                        Task {
                            await libraryVM.loadSidebarData()
                            await libraryVM.loadAssets()
                            await promptVM.loadPrompts()
                        }
                    }
            } else {
                Color.appBackground.ignoresSafeArea()
                    .overlay { ProgressView().tint(Color.appAccent) }
            }
        }
        .task {
            guard libraryVM == nil else { return }
            await ProviderRegistry.shared.register(NanaBananaProvider())

            let newGenVM = GenerationViewModel(database: env.database, libraryURL: env.libraryURL)
            await newGenVM.loadInitialData()

            let newLibVM = LibraryViewModel(database: env.database, libraryURL: env.libraryURL)
            let newPromptVM = PromptViewModel(database: env.database, libraryURL: env.libraryURL)

            generationVM = newGenVM
            libraryVM = newLibVM
            promptVM = newPromptVM
        }
    }

    @ViewBuilder
    private func activeView(
        libraryVM: LibraryViewModel,
        generationVM: GenerationViewModel,
        promptVM: PromptViewModel
    ) -> some View {
        switch activeTab {
        case .library:
            LibraryBrowserView(
                viewModel: libraryVM,
                onGenerate: { showGenerationSheet = true },
                onRegenerate: { asset in
                    generationVM.prePopulate(from: asset)
                    showGenerationSheet = true
                }
            )
        case .prompts:
            PromptLibraryView(viewModel: promptVM)
        }
    }
}
