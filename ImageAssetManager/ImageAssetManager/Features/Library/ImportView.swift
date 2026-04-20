import SwiftUI
import ImageAssetManagerCore
#if os(macOS)
import UniformTypeIdentifiers
#endif

struct ImportView: View {
    @Bindable var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isTargeted: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                dropZone

                if !viewModel.importURLs.isEmpty {
                    fileList
                }

                Form {
                    Section {
                        Picker("File Handling", selection: $viewModel.importMode) {
                            ForEach(ImportMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(viewModel.importMode == .move
                             ? "Move removes the original from its source location."
                             : "Copy keeps the original in place.")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)

                        Picker("File Naming", selection: $viewModel.importNaming) {
                            ForEach(ImportNaming.allCases, id: \.self) { n in
                                Text(n.rawValue).tag(n)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(namingCaption)
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }

                    Picker("Project", selection: $viewModel.importProjectID) {
                        Text("None").tag(Optional<String>.none)
                        ForEach(viewModel.projects, id: \.id) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }

                    let filteredCollections = viewModel.allCollections.filter { c in
                        viewModel.importProjectID == nil || c.projectID == viewModel.importProjectID
                    }
                    if !filteredCollections.isEmpty {
                        Picker("Collection", selection: $viewModel.importCollectionID) {
                            Text("None").tag(Optional<String>.none)
                            ForEach(filteredCollections, id: \.id) { coll in
                                Text(coll.name).tag(Optional(coll.id))
                            }
                        }
                    }

                    TextField("Tags (comma-separated)", text: $viewModel.importTags)
                }
                .formStyle(.grouped)

                Spacer()
            }
            .padding()
            .navigationTitle("Import Images")
            #if os(macOS)
            .frame(minWidth: 400, minHeight: 480)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.importURLs = []
                        viewModel.importTags = ""
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { performImport() }
                        .disabled(viewModel.importURLs.isEmpty || viewModel.isImporting)
                }
            }
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isTargeted ? Color.appAccent : Color.appBorder,
                lineWidth: isTargeted ? 2 : 1
            )
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isTargeted ? Color.appAccent.opacity(0.08) : Color.appSurfaceRaised)
            )
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 32))
                        .foregroundStyle(isTargeted ? Color.appAccent : Color.appTextSecondary)
                    Text(isTargeted ? "Drop to add" : "Drop images here")
                        .foregroundStyle(isTargeted ? Color.appAccent : Color.appTextSecondary)
                    Button("Choose Files") { openFilePicker() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .frame(height: 140)
            .dropDestination(for: URL.self) { urls, _ in
                viewModel.importURLs.append(contentsOf: urls.filter { isImageURL($0) })
                return true
            } isTargeted: { isTargeted = $0 }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(viewModel.importURLs.count) file(s) selected")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(viewModel.importURLs, id: \.absoluteString) { url in
                        HStack {
                            Image(systemName: "photo")
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                            Text(url.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(Color.appTextPrimary)
                            Spacer()
                            Button {
                                viewModel.importURLs.removeAll { $0 == url }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.appTextSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: 120)
            .padding(8)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var namingCaption: String {
        switch viewModel.importNaming {
        case .preserveOriginal: "Files keep their original names, e.g. photo.png"
        case .prependDate:      "Date prepended to the original name, e.g. 2026-04-18_photo.png"
        case .dateAndIndex:     "Files renamed to date and sequence, e.g. 2026-04-18_001.png"
        }
    }

    private func performImport() {
        let tagNames = viewModel.importTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let mode = viewModel.importMode
        let naming = viewModel.importNaming
        Task {
            try? await viewModel.importAssets(
                urls: viewModel.importURLs,
                projectID: viewModel.importProjectID,
                collectionID: viewModel.importCollectionID,
                tagNames: tagNames,
                mode: mode,
                naming: naming
            )
            viewModel.importURLs = []
            viewModel.importTags = ""
            dismiss()
        }
    }

    private func openFilePicker() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .webP, .heic]
        if panel.runModal() == .OK {
            viewModel.importURLs.append(contentsOf: panel.urls.filter { isImageURL($0) })
        }
        #endif
    }

    private func isImageURL(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "webp", "heic"].contains(url.pathExtension.lowercased())
    }
}
