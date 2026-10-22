import Foundation

public struct PromptVaultExporter: Sendable {
    public static func write(prompt: Prompt, to promptsDir: URL) throws {
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        let fileURL = promptsDir.appending(path: "\(prompt.id).md")
        let data = Data(buildMarkdown(prompt: prompt).utf8)
        try data.write(to: fileURL, options: .atomic)
    }

    public static func delete(promptID: String, from promptsDir: URL) {
        let fileURL = promptsDir.appending(path: "\(promptID).md")
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func buildMarkdown(prompt: Prompt) -> String {
        var lines: [String] = ["---"]
        lines.append("id: \(prompt.id)")
        lines.append("title: \"\(prompt.title.replacingOccurrences(of: "\"", with: "\\\""))\"")
        if let sector = prompt.sector { lines.append("sector: \(sector)") }
        if let tags = prompt.tags { lines.append("tags: \(tags)") }
        lines.append("usage_count: \(prompt.usageCount)")
        if let last = prompt.lastUsedAt { lines.append("last_used_at: \(last)") }
        lines.append("created_at: \(prompt.createdAt)")
        lines.append("updated_at: \(prompt.updatedAt)")
        lines.append("---")
        lines.append("")
        lines.append(prompt.body)
        if let neg = prompt.negativePrompt, !neg.isEmpty {
            lines.append("")
            lines.append("## Negative Prompt")
            lines.append("")
            lines.append(neg)
        }
        return lines.joined(separator: "\n")
    }
}
