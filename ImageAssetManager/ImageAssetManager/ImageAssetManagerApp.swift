import SwiftUI
import ImageAssetManagerCore
#if os(macOS)
import AppKit
#endif

@main
struct ImageAssetManagerApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(ImageAssetManagerDelegate.self) var appDelegate
    #endif

    /// Nil when the library could not be opened (still downloading from iCloud, a failed
    /// backup): the window says why and offers a retry instead of crashing on every launch.
    @State private var env: AppEnvironment?
    @State private var launchError: String?

    init() {
        let (env, error) = Self.openLibrary()
        _env = State(initialValue: env)
        _launchError = State(initialValue: error)
    }

    private static func openLibrary() -> (AppEnvironment?, String?) {
        do {
            return (try AppEnvironment.make(), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            if AppEnvironment.isTestHost {
                // Under XCTest: no library UI, no view models, no MCP listener, no catalogue fetch.
                Text("Running tests")
            } else if let env {
                ContentView()
                    .environment(env)
                    // Check the model catalogue now and every 24 hours while the app runs.
                    .task { CatalogueStore.shared.start() }
                    #if os(macOS)
                    .task { await startMCPServer(env) }
                    #endif
            } else {
                LibraryUnavailableView(message: launchError ?? "The library could not be opened.") {
                    (env, launchError) = Self.openLibrary()
                }
            }
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        .windowToolbarStyle(.unified(showsTitle: false))
        #endif

        #if os(macOS)
        Settings {
            if let env, !AppEnvironment.isTestHost {
                SettingsView()
                    .environment(env)
            } else {
                Text("The library is not open.")
                    .padding()
            }
        }
        #endif
    }

    #if os(macOS)
    @MainActor
    private func startMCPServer(_ env: AppEnvironment) async {
        let server = MCPServer(database: env.database, libraryURL: env.libraryURL)
        ImageAssetManagerDelegate.mcpServer = server
        await server.start()
    }
    #endif
}

/// Shown instead of the library when it could not be opened. Nothing has been changed on disk.
private struct LibraryUnavailableView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Library unavailable")
                .font(.headline)
                .foregroundStyle(Color.appTextPrimary)
            Text(message)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
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
