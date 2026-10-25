import SwiftUI
import UniformTypeIdentifiers
import ImageAssetManagerCore

struct SourcePanelView: View {
    @Bindable var viewModel: LibraryViewModel

    private enum Sheet: Identifiable {
        case newClient, newProject, tags
        case renameClient(id: String, name: String)
        case renameProject(id: String, name: String)
        case deleteClient(id: String, name: String, projects: Int)
        case deleteProject(id: String, name: String, images: Int)
        var id: String {
            switch self {
            case .newClient: return "newClient"
            case .newProject: return "newProject"
            case .tags: return "tags"
            case .renameClient(let id, _): return "renameClient-\(id)"
            case .renameProject(let id, _): return "renameProject-\(id)"
            case .deleteClient(let id, _, _): return "deleteClient-\(id)"
            case .deleteProject(let id, _, _): return "deleteProject-\(id)"
            }
        }
    }
    @State private var sheet: Sheet?
    /// The row a drag is over, by `"client:<id>"`, `"project:<id>"` or `"none"`.
    @State private var dropTargeted: String?
    /// A drop that failed, shown rather than looking like nothing happened.
    @State private var dropError: String?

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
                Section {
                    if let client = group.client {
                        row("All \(client.name)", symbol: "person.crop.circle", count: viewModel.counts.clients[client.id] ?? 0)
                            .tag(SourceSelection.client(client.id))
                            .contextMenu { clientMenu(client) }
                            .modifier(DropHighlight(active: dropTargeted == "client:\(client.id)"))
                            .onDrop(of: [SidebarDrag.Kind.project.contentType], delegate: clientDropDelegate(client.id))
                    }
                    ForEach(group.projects, id: \.id) { project in
                        row(project.name, symbol: "briefcase", count: viewModel.counts.projects[project.id] ?? 0)
                            .tag(SourceSelection.project(project.id))
                            .contextMenu { projectMenu(project) }
                            .modifier(DropHighlight(active: dropTargeted == "project:\(project.id)"))
                            .draggable(SidebarDrag.project(project.id))
                            .onDrop(of: [SidebarDrag.Kind.images.contentType], delegate: projectDropDelegate(project.id))
                    }
                } header: {
                    if let client = group.client {
                        Text(client.name)
                            .modifier(DropHighlight(active: dropTargeted == "client:\(client.id)"))
                            .contextMenu { clientMenu(client) }
                            .onDrop(of: [SidebarDrag.Kind.project.contentType], delegate: clientDropDelegate(client.id))
                    } else {
                        Text("No client")
                            .modifier(DropHighlight(active: dropTargeted == "none"))
                            .onDrop(of: [SidebarDrag.Kind.project.contentType], delegate: clientDropDelegate(nil))
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
            case .renameClient(let id, let name): RenameSheet(viewModel: viewModel, kind: .client, id: id, name: name)
            case .renameProject(let id, let name): RenameSheet(viewModel: viewModel, kind: .project, id: id, name: name)
            case .deleteClient(let id, let name, let projects):
                DeleteConfirmSheet(target: .client(id: id, name: name, projects: projects)) {
                    try await viewModel.deleteClient(id: id)
                }
            case .deleteProject(let id, let name, let images):
                DeleteConfirmSheet(target: .project(id: id, name: name, images: images)) {
                    try await viewModel.deleteProject(id: id)
                }
            }
        }
        .alert("Filing Failed", isPresented: .init(
            get: { dropError != nil },
            set: { if !$0 { dropError = nil } }
        )) {
            Button("OK") { dropError = nil }
        } message: {
            Text(dropError ?? "")
        }
    }

    // MARK: - Context menus

    @ViewBuilder
    private func clientMenu(_ client: Client) -> some View {
        Button("Rename…") { sheet = .renameClient(id: client.id, name: client.name) }
        Button("Delete…", role: .destructive) {
            let projects = viewModel.projects.filter { $0.clientID == client.id }.count
            sheet = .deleteClient(id: client.id, name: client.name, projects: projects)
        }
    }

    @ViewBuilder
    private func projectMenu(_ project: Project) -> some View {
        Button("Rename…") { sheet = .renameProject(id: project.id, name: project.name) }
        Menu("Move to client") {
            ForEach(viewModel.clients, id: \.id) { client in
                Button(client.name) { moveProject(project.id, to: client.id) }
                    .disabled(project.clientID == client.id)
            }
            Divider()
            Button("No client") { moveProject(project.id, to: nil) }
                .disabled(project.clientID == nil)
        }
        Button("Delete…", role: .destructive) {
            Task {
                let images = await viewModel.imageCount(projectID: project.id)
                sheet = .deleteProject(id: project.id, name: project.name, images: images)
            }
        }
    }

    private func moveProject(_ id: String, to clientID: String?) {
        Task {
            do { try await viewModel.moveProject(id: id, toClient: clientID) } catch { dropError = error.localizedDescription }
        }
    }

    // MARK: - Drops

    /// Images dropped on a project add (⌥: also leave the project being viewed). It takes images only,
    /// so a project dragged over it shows nothing.
    private func projectDropDelegate(_ projectID: String) -> SidebarDropDelegate {
        SidebarDropDelegate(key: "project:\(projectID)", accepts: .images, targeted: $dropTargeted, alwaysMove: false) { [viewModel] drag, option in
            guard case .images(let ids) = drag else { return }
            Task {
                do { try await viewModel.dropImages(Set(ids), onto: projectID, move: option) } catch { dropError = error.localizedDescription }
            }
        }
    }

    /// A project dropped on a client moves there, on "No client" (nil) detaches. It takes projects
    /// only, so images dragged over it show nothing.
    private func clientDropDelegate(_ clientID: String?) -> SidebarDropDelegate {
        SidebarDropDelegate(key: clientID.map { "client:\($0)" } ?? "none", accepts: .project, targeted: $dropTargeted, alwaysMove: true) { [viewModel] drag, _ in
            guard case .project(let projectID) = drag else { return }
            Task {
                do { try await viewModel.moveProject(id: projectID, toClient: clientID) } catch { dropError = error.localizedDescription }
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

/// Rename a client or project. A name another has in any case is refused here, with the text creating gives.
private struct RenameSheet: View {
    enum Kind { case client, project }

    @Bindable var viewModel: LibraryViewModel
    let kind: Kind
    let id: String
    @State var name: String
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    init(viewModel: LibraryViewModel, kind: Kind, id: String, name: String) {
        self.viewModel = viewModel
        self.kind = kind
        self.id = id
        _name = State(initialValue: name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .client ? "Rename Client" : "Rename Project").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { rename() }
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
                Button("Rename") { rename() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 340)
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                switch kind {
                case .client: try await viewModel.renameClient(id: id, to: trimmed)
                case .project: try await viewModel.renameProject(id: id, to: trimmed)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// An accent outline and wash on the row a drag is over.
private struct DropHighlight: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .background(active ? Color.appAccent.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if active { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.appAccent, lineWidth: 2) }
            }
    }
}
