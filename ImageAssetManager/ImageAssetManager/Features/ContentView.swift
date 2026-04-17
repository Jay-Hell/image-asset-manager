import SwiftUI
import ImageAssetManagerCore

struct ContentView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var vm: GenerationViewModel?

    var body: some View {
        Group {
            if let vm {
                GenerationPanelView(viewModel: vm)
            } else {
                Color.appBackground.ignoresSafeArea()
                    .overlay {
                        ProgressView()
                            .tint(Color.appAccent)
                    }
            }
        }
        .task {
            guard vm == nil else { return }
            await ProviderRegistry.shared.register(NanaBananaProvider())
            let newVM = GenerationViewModel(database: env.database, libraryURL: env.libraryURL)
            await newVM.loadInitialData()
            vm = newVM
        }
    }
}
