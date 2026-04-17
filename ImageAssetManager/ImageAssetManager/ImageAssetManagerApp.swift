import SwiftUI

@main
struct ImageAssetManagerApp: App {
    @State private var env: AppEnvironment = {
        do {
            return try AppEnvironment.make()
        } catch {
            fatalError("Failed to initialise app environment: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(env)
        }
        #if os(macOS)
        .defaultSize(width: 840, height: 700)
        #endif
    }
}
