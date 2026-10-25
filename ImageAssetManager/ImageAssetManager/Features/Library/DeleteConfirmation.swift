import SwiftUI
import ImageAssetManagerCore

/// What a delete of a client or project names. One wording, shared by the sidebar and Settings.
enum DeleteTarget: Identifiable {
    case client(id: String, name: String, projects: Int)
    case project(id: String, name: String, images: Int)

    var id: String {
        switch self {
        case .client(let id, _, _): return "client-\(id)"
        case .project(let id, _, _): return "project-\(id)"
        }
    }

    private static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    var title: String {
        switch self {
        case .client(_, let name, _): return "Delete client \u{201C}\(name)\u{201D}?"
        case .project(_, let name, _): return "Delete project \u{201C}\(name)\u{201D}?"
        }
    }

    var detail: String {
        switch self {
        case .client(_, _, let projects):
            return projects == 0
                ? "It has no projects."
                : "Its \(Self.plural(projects, "project")) will move to \u{201C}No client\u{201D}. No project or image is deleted."
        case .project(_, _, let images):
            return images == 0
                ? "It holds no images."
                : "It holds \(Self.plural(images, "image")). The images stay in the library; any left with no project show under Unfiled."
        }
    }
}

/// The delete confirmation, in the window rather than a system dialog, saying what goes and what stays.
/// `onConfirm` does the delete; a refusal shows in the sheet and keeps it open.
struct DeleteConfirmSheet: View {
    let target: DeleteTarget
    let onConfirm: () async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.title).font(.headline)
            Text(target.detail)
                .font(.callout)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                Button("Delete", role: .destructive) { confirm() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(20)
        .frame(minWidth: 340, maxWidth: 420)
    }

    private func confirm() {
        Task {
            do {
                try await onConfirm()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
