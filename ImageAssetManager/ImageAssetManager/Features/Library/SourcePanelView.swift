import SwiftUI
import ImageAssetManagerCore

struct SourcePanelView: View {
    @Bindable var viewModel: LibraryViewModel
    var onGenerate: () -> Void

    var body: some View {
        List(selection: $viewModel.sourceSelection) {
            Section {
                Label("All Assets", systemImage: "photo.stack")
                    .tag(SourceSelection.allAssets)
            }

            if !viewModel.clients.isEmpty {
                Section("Clients") {
                    ForEach(viewModel.clients, id: \.id) { client in
                        let clientProjects = viewModel.projects.filter { $0.clientID == client.id }
                        HStack {
                            Label(client.name, systemImage: "person.crop.circle")
                            Spacer()
                            if !clientProjects.isEmpty {
                                Text("\(clientProjects.count)")
                                    .foregroundStyle(Color.appTextSecondary)
                                    .font(.caption)
                            }
                        }
                        .tag(SourceSelection.client(client.id))
                    }
                }
            }

            if !viewModel.projects.isEmpty {
                Section("Projects") {
                    ForEach(viewModel.projects, id: \.id) { project in
                        let projectCollections = viewModel.allCollections.filter { $0.projectID == project.id }
                        if projectCollections.isEmpty {
                            Label(project.name, systemImage: "briefcase")
                                .tag(SourceSelection.project(project.id))
                        } else {
                            DisclosureGroup {
                                ForEach(projectCollections, id: \.id) { coll in
                                    Label(coll.name, systemImage: "folder")
                                        .tag(SourceSelection.collection(coll.id))
                                        .padding(.leading, 4)
                                }
                            } label: {
                                Label(project.name, systemImage: "briefcase")
                                    .tag(SourceSelection.project(project.id))
                            }
                        }
                    }
                }
            }

            if !viewModel.tagsWithCounts.isEmpty {
                Section("Tags") {
                    ForEach(viewModel.tagsWithCounts, id: \.0.id) { tag, count in
                        HStack {
                            Label(tag.name, systemImage: "tag")
                            Spacer()
                            Text("\(count)")
                                .foregroundStyle(Color.appTextSecondary)
                                .font(.caption)
                        }
                        .tag(SourceSelection.tag(tag.id))
                    }
                }
            }

            if !viewModel.variantFamilies.isEmpty {
                Section("Variant Families") {
                    ForEach(viewModel.variantFamilies, id: \.0.id) { variant, members in
                        HStack {
                            Label(variant.name, systemImage: "square.3.layers.3d")
                            Spacer()
                            Text("\(members.count)")
                                .foregroundStyle(Color.appTextSecondary)
                                .font(.caption)
                        }
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
                    Task { await viewModel.loadAssets() }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: viewModel.sourceSelection) { _, _ in
            Task { await viewModel.onSourceChanged() }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onGenerate) {
                    Label("Generate", systemImage: "wand.and.stars")
                }
                .keyboardShortcut("g", modifiers: .command)
                .help("Open Generation Panel (⌘G)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.showImportSheet = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("i", modifiers: .command)
                .help("Import images (⌘I)")
            }
        }
    }
}
