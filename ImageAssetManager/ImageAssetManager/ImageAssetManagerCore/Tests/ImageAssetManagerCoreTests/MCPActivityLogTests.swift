import Testing
import Foundation
@testable import ImageAssetManagerCore

@Suite("MCPActivityLog")
struct MCPActivityLogTests {

    private func entry(_ n: Int) -> MCPRequestLogEntry {
        MCPRequestLogEntry(
            timestamp: Date(timeIntervalSince1970: TimeInterval(n)),
            method: "POST",
            path: "/tool",
            tool: "tool_\(n)",
            ok: true
        )
    }

    @Test func recordsBelowCapacityKeepsAll() {
        var log = MCPActivityLog(capacity: 5)
        for n in 0..<3 { log.record(entry(n)) }
        #expect(log.entries.count == 3)
        #expect(log.entries.first?.tool == "tool_0")
        #expect(log.entries.last?.tool == "tool_2")
    }

    @Test func recordingBeyondCapacityDropsOldest() {
        var log = MCPActivityLog(capacity: 3)
        for n in 0..<8 { log.record(entry(n)) }
        #expect(log.entries.count == 3)
        // Oldest (0..4) dropped; the three most recent retained, oldest-first.
        #expect(log.entries.map(\.tool) == ["tool_5", "tool_6", "tool_7"])
    }

    @Test func mostRecentIsReversed() {
        var log = MCPActivityLog(capacity: 10)
        for n in 0..<3 { log.record(entry(n)) }
        #expect(log.mostRecent.map(\.tool) == ["tool_2", "tool_1", "tool_0"])
    }

    @Test func summaryIncludesToolWhenPresent() {
        let withTool = MCPRequestLogEntry(timestamp: .init(timeIntervalSince1970: 0), method: "POST", path: "/tool", tool: "generate_image", ok: true)
        let withoutTool = MCPRequestLogEntry(timestamp: .init(timeIntervalSince1970: 0), method: "GET", path: "/health", ok: true)
        #expect(withTool.summary == "POST /tool · generate_image")
        #expect(withoutTool.summary == "GET /health")
    }
}
