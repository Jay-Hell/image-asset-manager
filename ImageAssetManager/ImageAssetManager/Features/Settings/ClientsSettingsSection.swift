import SwiftUI
import ImageAssetManagerCore

struct ClientsSettingsSection: View {
    @Environment(AppEnvironment.self) private var env

    @State private var clients: [Client] = []
    @State private var editingID: String?
    @State private var editingName: String = ""
    @State private var newClientName: String = ""
    @State private var errorMessage: String?
    @State private var pendingDelete: DeleteTarget?

    var body: some View {
        Section {
            if clients.isEmpty {
                Text("No clients yet. Add one below.")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }

            ForEach(clients, id: \.id) { client in
                clientRow(client)
            }

            HStack(spacing: 8) {
                TextField("New client name", text: $newClientName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addClient() }
                Button("Add") { addClient() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .disabled(newClientName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Clients")
        } footer: {
            Text("Clients group projects. Rename any client inline. Deleting a client keeps its projects and images; the projects move to \u{201C}No client\u{201D}.")
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
                if case .client(let id, _, _) = target { try await env.database.deleteClient(id: id) }
            }
        }
        .alert("Client Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func clientRow(_ client: Client) -> some View {
        HStack(spacing: 8) {
            if editingID == client.id {
                TextField("Name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(client) }
                Button("Save") { commitRename(client) }
                    .buttonStyle(.bordered)
                Button("Cancel") { editingID = nil }
                    .buttonStyle(.bordered)
            } else {
                Text(client.name)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer()
                Button("Rename") {
                    editingID = client.id
                    editingName = client.name
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(Color.appAccent)
                Button(role: .destructive) {
                    deleteClient(client)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    private func reload() async {
        clients = (try? await env.database.fetchClients()) ?? []
    }

    private func addClient() {
        let trimmed = newClientName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                // The same find-or-create as the MCP's create_client: names are unique ignoring case.
                let (existing, created) = try await env.database.createClient(name: trimmed)
                guard created else {
                    errorMessage = NameClash.client(existing.name)
                    return
                }
                newClientName = ""
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func commitRename(_ client: Client) {
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { editingID = nil; return }
        Task {
            do {
                // The same clash rule and text as creating one (and as the sidebar's rename).
                try await env.database.renameClientReportingClash(id: client.id, newName: trimmed)
                editingID = nil
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Asks first, in the window, in the sidebar's words (`DeleteConfirmSheet`); the delete is the sheet's Delete.
    private func deleteClient(_ client: Client) {
        Task {
            let projects = (try? await env.database.projectCount(clientID: client.id)) ?? 0
            pendingDelete = .client(id: client.id, name: client.name, projects: projects)
        }
    }
}
