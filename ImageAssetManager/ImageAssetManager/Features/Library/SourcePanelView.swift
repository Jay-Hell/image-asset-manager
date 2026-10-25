import SwiftUI
import ImageAssetManagerCore

struct SourcePanelView: View {
    @Bindable var viewModel: LibraryViewModel

    private enum Sheet: Identifiable {
        case newClient, newProject, tags
        var id: Int { hashValue }
    }
    @State private var sheet: Sheet?

    var body: some View {
        // iOS only offers `List(selection:)` for an optional (or Set) binding.
        List(selection: Binding<SourceSelection?>(
            get: { viewModel.sourceSelection },
            set: { if let newValue = $0 { viewModel.sourceSelection = newValue } }
        )) {
            Section {
                row("All Assets", symbol: "photo.stack", count: viewModel.counts.all)
                    .tag(SourceSelection.allAssets)
                row("Unfiled", symbol: "tray", count: viewModel.counts.unfiled, highlight: viewModel.counts.unfiled > 0)
                    .tag(SourceSelection.unfiled)
            }

            ForEach(viewModel.sidebarGroups, id: \.client?.id) { group in
                Section(group.client?.name ?? "No client") {
                    if let client = group.client {
                        row("All \(client.name)", symbol: "person.crop.circle", count: viewModel.counts.clients[client.id] ?? 0)
                            .tag(SourceSelection.client(client.id))
                    }
                    ForEach(group.projects, id: \.id) { project in
                        row(project.name, symbol: "briefcase", count: viewModel.counts.projects[project.id] ?? 0)
                            .tag(SourceSelection.project(project.id))
                    }
                }
            }

            Section {
                ForEach(viewModel.tagsWithCounts, id: \.0.id) { tag, count in
                    row(tag.name, symbol: "tag", count: count)
                        .tag(SourceSelection.tag(tag.id))
                }
            } header: {
                HStack {
                    Text("Tags")
                    Spacer()
                    Button("Manage…") { sheet = .tags }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(Color.appAccent)
                }
            }

            if !viewModel.variantFamilies.isEmpty {
                Section("Variant Families") {
                    ForEach(viewModel.variantFamilies, id: \.0.id) { variant, members in
                        row(variant.name, symbol: "square.3.layers.3d", count: members.count)
                            .tag(SourceSelection.variantFamily(variant.id))
                    }
                }
            }

            Section("View Options") {
                Toggle(isOn: $viewModel.showHidden) {
                    Label("Show Hidden", systemImage: "eye.slash")
                }
                .toggleStyle(.switch)
                .onChange(of: viewModel.showHidden) { _, _ in
                    Task {
                        await viewModel.loadSidebarData()
                        await viewModel.loadAssets()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: viewModel.sourceSelection) { _, _ in
            Task { await viewModel.onSourceChanged() }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button { sheet = .newClient } label: { Label("New client…", systemImage: "person.badge.plus") }
                Button { sheet = .newProject } label: { Label("New project…", systemImage: "folder.badge.plus") }
            }
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(Color.appAccent)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .newClient: NewNameSheet(viewModel: viewModel, kind: .client)
            case .newProject: NewNameSheet(viewModel: viewModel, kind: .project)
            case .tags: TagManagerView(viewModel: viewModel)
            }
        }
    }

    private func row(_ title: String, symbol: String, count: Int, highlight: Bool = false) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text("\(count)")
                .foregroundStyle(highlight ? Color.appAccent : Color.appTextSecondary)
                .font(.caption)
        }
    }
}

/// One field and, for a project, its client. A refused name shows its reason in the sheet.
private struct NewNameSheet: View {
    enum Kind { case client, project }

    @Bindable var viewModel: LibraryViewModel
    let kind: Kind
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var clientID: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .client ? "New Client" : "New Project").font(.headline)
            TextField(kind == .client ? "Client name" : "Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }
            if kind == .project {
                Picker("Client", selection: $clientID) {
                    Text("No client").tag(String?.none)
                    ForEach(viewModel.clients, id: \.id) { client in
                        Text(client.name).tag(String?.some(client.id))
                    }
                }
            }
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
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 340)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                switch kind {
                case .client:
                    let client = try await viewModel.createClient(name: trimmed)
                    viewModel.sourceSelection = .client(client.id)
                case .project:
                    let project = try await viewModel.createProject(name: trimmed, clientID: clientID)
                    viewModel.sourceSelection = .project(project.id)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
