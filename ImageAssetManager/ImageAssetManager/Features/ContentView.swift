import SwiftUI
import ImageAssetManagerCore

enum AppTab {
    case library
    case prompts
    case spend
}

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var libraryVM: LibraryViewModel?
    @State private var generationVM: GenerationViewModel?
    @State private var promptVM: PromptViewModel?
    @State private var exportVM: ExportViewModel?
    @State private var spendVM: SpendViewModel?
    @State private var showGenerationSheet: Bool = false
    @State private var showExportSheet: Bool = false
    @State private var assetToExport: Asset?
    @State private var activeTab: AppTab = .library

    var body: some View {
        Group {
            if let libraryVM, let generationVM, let promptVM, let exportVM, let spendVM {
                activeView(libraryVM: libraryVM, generationVM: generationVM, promptVM: promptVM, spendVM: spendVM)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Picker("View", selection: $activeTab) {
                                Label("Library", systemImage: "photo.stack")
                                    .tag(AppTab.library)
                                Label("Prompts", systemImage: "text.quote")
                                    .tag(AppTab.prompts)
                                Label("Spend", systemImage: "chart.bar")
                                    .tag(AppTab.spend)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 300)
                        }
                    }
                    .sheet(isPresented: $showGenerationSheet) {
                        GenerationPanelView(viewModel: generationVM)
                            #if os(macOS)
                            .frame(width: 840, height: 700)
                            #endif
                    }
                    .sheet(isPresented: $showExportSheet, onDismiss: { exportVM.resetExport() }) {
                        if let asset = assetToExport {
                            ExportSheetView(
                                viewModel: exportVM,
                                asset: asset,
                                libraryURL: env.libraryURL
                            )
                        }
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

            generationVM = newGenVM
            libraryVM = LibraryViewModel(database: env.database, libraryURL: env.libraryURL)
            promptVM = PromptViewModel(database: env.database, libraryURL: env.libraryURL)
            exportVM = ExportViewModel(database: env.database)
            spendVM = SpendViewModel(database: env.database)
        }
    }

    @ViewBuilder
    private func activeView(
        libraryVM: LibraryViewModel,
        generationVM: GenerationViewModel,
        promptVM: PromptViewModel,
        spendVM: SpendViewModel
    ) -> some View {
        switch activeTab {
        case .library:
            LibraryBrowserView(
                viewModel: libraryVM,
                onGenerate: { showGenerationSheet = true },
                onRegenerate: { asset in
                    generationVM.prePopulate(from: asset)
                    showGenerationSheet = true
                },
                onExport: { asset in
                    assetToExport = asset
                    showExportSheet = true
                }
            )
        case .prompts:
            PromptLibraryView(viewModel: promptVM)
        case .spend:
            SpendDashboardView(viewModel: spendVM)
        }
    }
}
