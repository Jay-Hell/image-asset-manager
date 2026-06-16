import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct ImageAssetManagerApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(ImageAssetManagerDelegate.self) var appDelegate
    #endif

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
                #if os(macOS)
                .task { env.mcpController.startIfEnabled() }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        .windowToolbarStyle(.unified(showsTitle: false))
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(env)
        }
        #endif
    }
}

#if os(macOS)
final class ImageAssetManagerDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    static var mcpServer: MCPServer?

    func applicationWillTerminate(_ notification: Notification) {
        let server = Self.mcpServer
        let sema = DispatchSemaphore(value: 0)
        Task {
            await server?.stop()
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 2)
    }
}
#endif
