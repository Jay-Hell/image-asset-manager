import SwiftUI
import ImageAssetManagerCore

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var libraryVM: LibraryViewModel?
    @State private var generationVM: GenerationViewModel?
    @State private var showGenerationSheet: Bool = false

    var body: some View {
        Group {
            if let libraryVM, let generationVM {
                LibraryBrowserView(
                    viewModel: libraryVM,
                    onGenerate: {
                        showGenerationSheet = true
                    },
                    onRegenerate: { asset in
                        generationVM.prePopulate(from: asset)
                        showGenerationSheet = true
                    }
                )
                .sheet(isPresented: $showGenerationSheet) {
                    GenerationPanelView(viewModel: generationVM)
                        #if os(macOS)
                        .frame(width: 840, height: 700)
                        #endif
                }
                .onChange(of: showGenerationSheet) { _, isShowing in
                    if !isShowing {
                        Task {
                            await libraryVM.loadSidebarData()
                            await libraryVM.loadAssets()
                        }
                    }
                }
            } else {
                Color.appBackground.ignoresSafeArea()
                    .overlay {
                        ProgressView()
                            .tint(Color.appAccent)
                    }
            }
        }
        .task {
            guard libraryVM == nil else { return }
            await ProviderRegistry.shared.register(NanaBananaProvider())

            let newGenVM = GenerationViewModel(database: env.database, libraryURL: env.libraryURL)
            await newGenVM.loadInitialData()

            let newLibVM = LibraryViewModel(database: env.database, libraryURL: env.libraryURL)

            generationVM = newGenVM
            libraryVM = newLibVM
        }
    }
}
