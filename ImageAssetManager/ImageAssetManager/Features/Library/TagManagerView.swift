import SwiftUI
import ImageAssetManagerCore

/// Rename, merge and delete tags. The rules live in Core (`renameTag`, `mergeTags`, `deleteTag`);
/// this view lists, asks and reports. A delete is confirmed in the page, never in a system dialog.
struct TagManagerView: View {
    @Bindable var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [TagRow] = []
    @State private var ticked: Set<String> = []
    @State private var renamingID: String?
    @State private var renamingName = ""
    @State private var confirmingDelete: TagRow?
    @State private var mergeTarget: String?
    @State private var isMerging = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tags").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(Color.appAccent)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let doomed = confirmingDelete {
                deleteConfirmation(doomed)
            }

            if isMerging {
                mergePanel
            } else if ticked.count >= 2 {
                Button("Merge \(ticked.count) selected…") {
                    mergeTarget = rows.first { ticked.contains($0.id) }?.id
                    isMerging = true
                }
                .buttonStyle(.bordered)
            }

            if rows.isEmpty {
                Text("No tags yet.").font(.caption).foregroundStyle(Color.appTextSecondary)
            }

            List {
                ForEach(rows, id: \.id) { row in
                    tagRow(row)
                }
            }
            .frame(minHeight: 240)
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 420)
        .task { await reload() }
    }

    // MARK: - Rows

    @ViewBuilder
    private func tagRow(_ row: TagRow) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { ticked.contains(row.id) },
                set: { if $0 { ticked.insert(row.id) } else { ticked.remove(row.id) } }
            ))
            .labelsHidden()
            .accessibilityLabel("Select tag \(row.name)")

            if renamingID == row.id {
                TextField("Name", text: $renamingName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(row) }
                Button("Save") { commitRename(row) }.buttonStyle(.bordered)
                Button("Cancel") { renamingID = nil }.buttonStyle(.bordered)
            } else {
                Text(row.name)
                Spacer()
                Text("\(row.count)").font(.caption).foregroundStyle(Color.appTextSecondary)
                Button("Rename") {
                    renamingID = row.id
                    renamingName = row.name
                    errorMessage = nil
                }
                .buttonStyle(.borderless).controlSize(.small).foregroundStyle(Color.appAccent)
                Button(role: .destructive) {
                    confirmingDelete = row
                    errorMessage = nil
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).controlSize(.small)
                .accessibilityLabel("Delete tag \(row.name)")
            }
        }
    }

    // MARK: - In-page confirmations

    private func deleteConfirmation(_ row: TagRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delete \u{201C}\(row.name)\u{201D}?").font(.subheadline).fontWeight(.semibold)
            Text(row.count == 0
                 ? "No asset carries this tag."
                 : "It is taken off \(row.count) asset\(row.count == 1 ? "" : "s"). The assets themselves stay.")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
            HStack {
                Button("Delete tag", role: .destructive) { delete(row) }.buttonStyle(.borderedProminent)
                Button("Cancel") { confirmingDelete = nil }.buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 6))
    }

    private var mergePanel: some View {
        let chosen = rows.filter { ticked.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Merge \(chosen.count) tags into one").font(.subheadline).fontWeight(.semibold)
            Picker("Keep", selection: $mergeTarget) {
                ForEach(chosen, id: \.id) { row in
                    Text(row.name).tag(String?.some(row.id))
                }
            }
            Text("Every asset with any of them gets the kept tag once. The others are removed; no asset is.")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
            HStack {
                Button("Merge") { merge() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .disabled(mergeTarget == nil)
                Button("Cancel") { isMerging = false }.buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Actions

    private func reload() async {
        rows = await viewModel.loadTagRows()
        ticked = ticked.intersection(Set(rows.map(\.id)))
    }

    private func commitRename(_ row: TagRow) {
        Task {
            do {
                try await viewModel.renameTag(id: row.id, to: renamingName)
                renamingID = nil
                errorMessage = nil
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func merge() {
        guard let target = mergeTarget else { return }
        let ids = Array(ticked)
        Task {
            do {
                try await viewModel.mergeTags(ids: ids, into: target)
                isMerging = false
                ticked = []
                errorMessage = nil
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func delete(_ row: TagRow) {
        Task {
            do {
                try await viewModel.deleteTag(id: row.id)
                confirmingDelete = nil
                errorMessage = nil
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
