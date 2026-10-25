import Testing
import Foundation
@testable import ImageAssetManagerCore

// R2-1: one MCP server per app process however many windows open (finding 4), and a /health that
// says which copy of the app is answering, for the proxy to check after it opens one (finding 1).

private final class FakeServer: Sendable {}

@MainActor
private final class Tally {
    var made = 0
    var started = 0
}

@Suite("MCP server: one per app process")
@MainActor
struct MCPServerOwnerTests {

    /// What each window's `.task` does: ask the app's owner to start the server.
    private func openWindow(_ owner: MCPServerOwner<FakeServer>, _ tally: Tally) async -> Bool {
        await owner.startOnce(
            make: { tally.made += 1; return FakeServer() },
            start: { _ in
                await MainActor.run { tally.started += 1 }
                // A start that takes a while, as binding the listener does.
                try? await Task.sleep(for: .milliseconds(20))
            })
    }

    @Test func everyWindowAfterTheFirstFindsTheServerRunningAndStartsNothing() async {
        let owner = MCPServerOwner<FakeServer>()
        let tally = Tally()
        // The first window, then Cmd-N, then the Dock reopening one after the last window closed.
        var started: [Bool] = []
        for _ in 0..<3 { started.append(await openWindow(owner, tally)) }
        #expect(started == [true, false, false])
        #expect(tally.made == 1)
        #expect(tally.started == 1)
        let first = owner.server
        #expect(first != nil)
        _ = await openWindow(owner, tally)
        #expect(owner.server === first)          // the listening server is never replaced
    }

    @Test func twoWindowsOpeningAtOnceStartOneServer() async {
        let owner = MCPServerOwner<FakeServer>()
        let tally = Tally()
        let one = Task { await openWindow(owner, tally) }
        let two = Task { await openWindow(owner, tally) }
        let results = [await one.value, await two.value]
        #expect(results.filter { $0 }.count == 1)
        #expect(tally.made == 1)
        #expect(tally.started == 1)
    }

    @Test func theOwnerStartsNothingUntilAWindowAsks() {
        let owner = MCPServerOwner<FakeServer>()
        #expect(owner.server == nil)
    }
}

@Suite("MCP /health: which copy is answering")
struct MCPHealthTests {

    private func decode(_ data: Data) throws -> [String: String] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    @Test func healthReportsTheBundlePathAndVersionAndNothingElse() throws {
        let body = MCPHealth.body(
            bundleURL: URL(filePath: "/Applications/ImageAssetManager.app/", directoryHint: .isDirectory),
            info: ["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "6", "CFBundleIdentifier": "Ionic.ImageAssetManager"])
        let health = try decode(body)
        #expect(health == [
            "status": "ok",
            "bundle_path": "/Applications/ImageAssetManager.app",
            "version": "1.2.0",
            "build": "6",
        ])
    }

    @Test func aPathWithSpacesIsReportedAsWrittenNotPercentEncoded() throws {
        let health = try decode(MCPHealth.body(
            bundleURL: URL(filePath: "/Users/John Smith/Build/Products/Debug/ImageAssetManager.app", directoryHint: .isDirectory),
            info: [:]))
        #expect(health["bundle_path"] == "/Users/John Smith/Build/Products/Debug/ImageAssetManager.app")
        // The pair: no version in the bundle's Info.plist is reported as empty, never left out.
        #expect(health["version"] == "")
        #expect(health["build"] == "")
    }
}
