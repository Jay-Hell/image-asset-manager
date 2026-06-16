#if os(macOS)
import SwiftUI
import ImageAssetManagerCore

/// Settings panel for the local MCP server: a user-facing toggle, live status, an
/// in-app connection test, and a request log. This makes the loopback server a
/// visible, demonstrable feature (and justifies the network.server entitlement).
struct MCPServerSettingsSection: View {
    @Environment(AppEnvironment.self) private var env

    @State private var testResult: TestResult?
    @State private var isTesting = false

    private enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    var body: some View {
        @Bindable var controller = env.mcpController

        Section {
            Toggle("Enable local MCP server", isOn: $controller.isEnabled)
                .tint(Color.appAccent)

            statusRow(controller.status)

            HStack(spacing: 8) {
                Button {
                    Task { await runConnectionTest() }
                } label: {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test Connection")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isTesting || !controller.isEnabled)

                testResultLabel
            }

            activityList(controller.activity)
        } header: {
            Text("Claude Code Integration (MCP Server)")
        } footer: {
            Text("A local server on 127.0.0.1:\(String(MCPServerController.port)) that lets Claude Code and other MCP clients query and generate assets. Loopback only — it never accepts connections from outside this Mac. Disable it if you don't use the Claude Code integration.")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
        }
    }

    // MARK: - Status

    @ViewBuilder
    private func statusRow(_ status: MCPServerStatus) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 8, height: 8)
            Text(statusText(status))
                .font(.system(size: 12))
                .foregroundStyle(Color.appTextSecondary)
                .textSelection(.enabled)
        }
    }

    private func statusColor(_ status: MCPServerStatus) -> Color {
        switch status {
        case .running: .green
        case .stopped: Color.appTextSecondary
        case .failed:  .red
        }
    }

    private func statusText(_ status: MCPServerStatus) -> String {
        switch status {
        case .running(let port): "Running on 127.0.0.1:\(port)"
        case .stopped:           "Stopped"
        case .failed(let msg):   "Failed: \(msg)"
        }
    }

    // MARK: - Test

    @ViewBuilder
    private var testResultLabel: some View {
        switch testResult {
        case .success(let body):
            Label(body, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
                .lineLimit(1)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .lineLimit(1)
        case nil:
            EmptyView()
        }
    }

    private func runConnectionTest() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }

        let url = URL(string: "http://127.0.0.1:\(MCPServerController.port)/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            testResult = code == 200 ? .success(body) : .failure("HTTP \(code)")
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }

    // MARK: - Activity

    @ViewBuilder
    private func activityList(_ log: MCPActivityLog) -> some View {
        let entries = log.mostRecent
        if entries.isEmpty {
            Text("No requests yet.")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent Activity")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.appTextSecondary)
                    .textCase(.uppercase)
                ForEach(entries) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.ok ? "checkmark" : "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(entry.ok ? Color.green : Color.orange)
                        Text(entry.summary)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 11))
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
            }
        }
    }
}
#endif
