import SwiftUI
import ImageAssetManagerCore

struct ProjectsSettingsSection: View {
    @Environment(AppEnvironment.self) private var env

    @State private var projects: [Project] = []
    @State private var clients: [Client] = []
    @State private var editingID: String?
    @State private var editingName: String = ""
    @State private var newProjectName: String = ""
    @State private var newProjectClientID: String?
    @State private var errorMessage: String?
    @State private var pendingDelete: DeleteTarget?

    var body: some View {
        Section {
            if projects.isEmpty {
                Text("No projects yet. Add one below.")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }

            ForEach(projects, id: \.id) { project in
                projectRow(project)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("New project name", text: $newProjectName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addProject() }
                    Button("Add") { addProject() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.appAccent)
                        .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                clientPicker(selection: $newProjectClientID, label: "Client for new project")
            }
        } header: {
            Text("Projects")
        } footer: {
            Text("Projects are scoped to a client. Deleting a project keeps its images; any left with no project show under Unfiled.")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
        }
        // Loads now and again after every change to the library, from here, the sidebar, another window or the MCP.
        .task(id: ObjectIdentifier(env.database)) {
            await reload()
            for await _ in env.database.libraryChanges() { await reload() }
        }
        .sheet(item: $pendingDelete) { target in
            DeleteConfirmSheet(target: target) {
                if case .project(let id, _, _) = target { try await env.database.deleteProject(id: id) }
            }
        }
        .alert("Project Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func projectRow(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if editingID == project.id {
                    TextField("Name", text: $editingName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename(project) }
                    Button("Save") { commitRename(project) }
                        .buttonStyle(.bordered)
                    Button("Cancel") { editingID = nil }
                        .buttonStyle(.bordered)
                } else {
                    Text(project.name)
                        .foregroundStyle(Color.appTextPrimary)
                    Spacer()
                    Button("Rename") {
                        editingID = project.id
                        editingName = project.name
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(Color.appAccent)
                    Button(role: .destructive) {
                        deleteProject(project)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            if editingID != project.id {
                clientPicker(
                    selection: Binding(
                        get: { project.clientID },
                        set: { newID in setClient(project: project, clientID: newID) }
                    ),
                    label: "Client"
                )
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func clientPicker(selection: Binding<String?>, label: String) -> some View {
        Picker(label, selection: selection) {
            Text("No client").tag(nil as String?)
            ForEach(clients, id: \.id) { client in
                Text(client.name).tag(client.id as String?)
            }
        }
        .pickerStyle(.menu)
        .font(.caption)
    }

    private func reload() async {
        async let ps = (try? env.database.fetchProjects()) ?? []
        async let cs = (try? env.database.fetchClients()) ?? []
        let (projs, cls) = await (ps, cs)
        projects = projs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        clients = cls
    }

    private func addProject() {
        let trimmed = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let clientID = newProjectClientID
        Task {
            do {
                // The same find-or-create as the MCP's create_project: names are unique ignoring case.
                let (existing, created) = try await env.database.createProject(
                    name: trimmed, clientID: clientID, description: nil)
                guard created else {
                    errorMessage = NameClash.project(existing.name)
                    return
                }
                newProjectName = ""
                newProjectClientID = nil
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func commitRename(_ project: Project) {
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { editingID = nil; return }
        Task {
            do {
                try await env.database.renameProjectReportingClash(id: project.id, newName: trimmed)
                editingID = nil
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func setClient(project: Project, clientID: String?) {
        Task {
            do {
                try await env.database.setProjectClient(projectID: project.id, clientID: clientID)
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Asks first, in the window, in the sidebar's words (`DeleteConfirmSheet`); the delete is the sheet's Delete.
    private func deleteProject(_ project: Project) {
        Task {
            let images = (try? await env.database.assetCount(projectID: project.id)) ?? 0
            pendingDelete = .project(id: project.id, name: project.name, images: images)
        }
    }
}
