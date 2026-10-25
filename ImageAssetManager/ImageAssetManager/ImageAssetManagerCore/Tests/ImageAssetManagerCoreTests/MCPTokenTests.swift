import Testing
import Foundation
import Network
@testable import ImageAssetManagerCore

// Release 1.2, the 23 Oct 401: the token file is written only once the listener is ready, never by an
// instance that cannot bind, and never by a test host; a refused token is logged without its value.

private final class Written: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Waits for a listener to reach `.ready` or `.failed`, feeding every state to `publisher` first,
/// as `MCPServer.start` does. Returns the state it settled in, or `.cancelled` after 5 s without one.
private func run(_ listener: NWListener, publishing publisher: MCPTokenPublisher) async -> NWListener.State {
    let queue = DispatchQueue(label: "mcp-token-test")
    return await withCheckedContinuation { (done: CheckedContinuation<NWListener.State, Never>) in
        let once = Written()
        let finish: @Sendable (NWListener.State) -> Void = { state in
            if once.all.isEmpty { once.append("done"); done.resume(returning: state) }
        }
        listener.stateUpdateHandler = { state in
            _ = try? publisher.listenerStateChanged(state)
            switch state {
            case .ready, .failed: finish(state)
            default: break
            }
        }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { finish(.cancelled) }
    }
}

private func loopbackListener(port: NWEndpoint.Port) throws -> NWListener {
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
    return try NWListener(using: params)
}

@Suite("MCP token: published on .ready")
struct MCPTokenTests {

    @Test func theTokenIsWrittenOnceOnReadyAndNeverBeforeOrForAFailedListener() throws {
        let written = Written()
        let publisher = try #require(MCPTokenPublisher(token: "tok-A", environment: [:]) { written.append($0) })
        for state: NWListener.State in [.setup, .waiting(.posix(.EADDRINUSE))] {
            #expect(try publisher.listenerStateChanged(state) == false)
        }
        #expect(written.all.isEmpty)                         // nothing before the port is bound
        #expect(try publisher.listenerStateChanged(.ready) == true)
        #expect(try publisher.listenerStateChanged(.ready) == false)
        #expect(written.all == ["tok-A"])

        // The pair: an instance whose listener fails never writes at all.
        let failedWrites = Written()
        let second = try #require(MCPTokenPublisher(token: "tok-B", environment: [:]) { failedWrites.append($0) })
        #expect(try second.listenerStateChanged(.failed(.posix(.EADDRINUSE))) == false)
        #expect(try second.listenerStateChanged(.cancelled) == false)
        #expect(failedWrites.all.isEmpty)
    }

    @Test func aTestHostGetsNoPublisherSoItCanNeverWriteTheToken() {
        #expect(MCPTokenPublisher(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]) { _ in } == nil)
        #expect(MCPTokenPublisher(environment: [:]) { _ in } != nil)
    }

    /// The 23 Oct shape with real listeners: a second instance on a port already taken fails to bind
    /// and leaves the first instance's token file as it was.
    @Test func aSecondInstanceThatCannotBindLeavesTheFirstInstancesTokenFile() async throws {
        let file = makeTempDirectory().appending(path: "mcp-token")
        let first = try #require(MCPTokenPublisher(token: "first-instance", environment: [:]) {
            try MCPTokenPublisher.writeTokenFile($0, to: file)
        })
        let one = try loopbackListener(port: .any)
        defer { one.cancel() }
        #expect(await run(one, publishing: first) == .ready)
        let port = try #require(one.port)
        #expect(try String(contentsOf: file, encoding: .utf8) == "first-instance")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o600)

        let second = try #require(MCPTokenPublisher(token: "second-instance", environment: [:]) {
            try MCPTokenPublisher.writeTokenFile($0, to: file)
        })
        let two = try loopbackListener(port: port)
        defer { two.cancel() }
        let settled = await run(two, publishing: second)
        #expect(settled != .ready)
        #expect(try String(contentsOf: file, encoding: .utf8) == "first-instance")
    }
}

@Suite("MCP auth: refusals are logged without the token")
struct MCPAuthTests {
    private let expected = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    @Test func theRightTokenIsAcceptedAndNothingIsLogged() {
        let outcome = MCPAuth.check(authorization: "Bearer \(expected)", expected: expected)
        #expect(outcome == .accepted)
        #expect(MCPAuth.refusalMessage(outcome) == nil)
    }

    @Test func aWrongOrMissingTokenIsRefusedAndTheLineNamesNeitherToken() throws {
        let supplied = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
        let wrong = MCPAuth.check(authorization: "Bearer \(supplied)", expected: expected)
        #expect(wrong == .mismatch(length: 64))
        let line = try #require(MCPAuth.refusalMessage(wrong))
        #expect(!line.contains(supplied) && !line.contains(expected))
        #expect(!line.contains(String(supplied.prefix(8))) && !line.contains(String(expected.prefix(8))))
        #expect(line.contains("64 characters"))

        #expect(MCPAuth.check(authorization: nil, expected: expected) == .missing)
        #expect(MCPAuth.check(authorization: "Bearer ", expected: expected) == .missing)
        #expect(MCPAuth.check(authorization: "Bearer \(expected)", expected: "") == .serverHasNoToken)
        #expect(MCPAuth.refusalMessage(.missing) != nil)
    }
}
