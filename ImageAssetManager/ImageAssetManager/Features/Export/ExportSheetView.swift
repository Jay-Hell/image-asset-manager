import SwiftUI
import ImageAssetManagerCore
#if os(macOS)
import AppKit
#endif

struct ExportSheetView: View {
    @Bindable var viewModel: ExportViewModel
    let asset: Asset
    let libraryURL: URL

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if viewModel.exportResults.isEmpty {
                exportSetupView
            } else {
                exportResultsView
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
        .sheet(isPresented: $viewModel.showPresetEditor) {
            ExportPresetEditorView(
                preset: viewModel.editingPreset,
                onSave: { id, name, fmt, mw, mh, q, suf in
                    Task {
                        try? await viewModel.savePreset(
                            id: id, name: name, format: fmt,
                            maxWidth: mw, maxHeight: mh,
                            jpegQuality: q, suffix: suf
                        )
                    }
                }
            )
        }
        .task { await viewModel.loadPresets() }
    }

    // MARK: - Setup view

    private var exportSetupView: some View {
        VStack(spacing: 0) {
            presetList
            Divider()
            destinationRow
            Divider()
            actionBar
        }
        .background(Color.appBackground)
        .navigationTitle("Export")
        #if os(macOS)
        .navigationSubtitle(asset.filename)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.startCreate()
                } label: {
                    Label("New Preset", systemImage: "plus")
                }
                .help("New Preset")
            }
        }
    }

    private var presetList: some View {
        Group {
            if viewModel.presets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.up.on.square")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.appTextSecondary)
                    Text("No export presets")
                        .font(.callout)
                        .foregroundStyle(Color.appTextSecondary)
                    Button("Create First Preset") { viewModel.startCreate() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.appAccent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.presets, id: \.id) { preset in
                    presetRow(preset)
                        .listRowBackground(Color.appSurface)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.appBackground)
            }
        }
        .frame(minHeight: 200)
    }

    private func presetRow(_ preset: ExportPreset) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { viewModel.selectedPresetIDs.contains(preset.id) },
                set: { on in
                    if on { viewModel.selectedPresetIDs.insert(preset.id) }
                    else  { viewModel.selectedPresetIDs.remove(preset.id) }
                }
            ))
            .labelsHidden()
            .tint(Color.appAccent)

            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.appTextPrimary)
                Text(presetDescription(preset))
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }

            Spacer()

            Button {
                viewModel.startEdit(preset)
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(Color.appTextSecondary)
            }
            .buttonStyle(.plain)
            .help("Edit preset")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit") { viewModel.startEdit(preset) }
            Divider()
            Button("Delete", role: .destructive) {
                Task { try? await viewModel.deletePreset(preset.id) }
            }
        }
    }

    private var destinationRow: some View {
        HStack {
            Image(systemName: "folder")
                .foregroundStyle(Color.appTextSecondary)
            if let dest = viewModel.destinationURL {
                Text(dest.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("No destination selected")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }
            Spacer()
            Button("Choose…") { chooseDestination() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.appSurface)
    }

    private var actionBar: some View {
        HStack {
            Text(viewModel.selectedPresetIDs.isEmpty
                 ? "Select at least one preset"
                 : "\(viewModel.selectedPresetIDs.count) preset(s) selected")
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
            Spacer()
            Button("Export") {
                Task { await viewModel.exportAsset(asset, libraryURL: libraryURL) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)
            .disabled(!canExport)
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.appSurface)
    }

    private var canExport: Bool {
        !viewModel.selectedPresetIDs.isEmpty &&
        viewModel.destinationURL != nil &&
        !viewModel.isExporting
    }

    // MARK: - Results view

    private var exportResultsView: some View {
        VStack(spacing: 0) {
            List(viewModel.exportResults) { result in
                HStack(spacing: 10) {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.success ? Color.green : Color.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.outputFilename)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.appTextPrimary)
                        if let err = result.error {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(Color.red)
                        } else {
                            Text(result.presetName)
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                        }
                    }
                }
                .listRowBackground(Color.appSurface)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)

            Divider()

            HStack {
                let successCount = viewModel.exportResults.filter(\.success).count
                Text("\(successCount) of \(viewModel.exportResults.count) exported successfully")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                Spacer()
                Button("Export Again") { viewModel.exportResults = [] }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .controlSize(.regular)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.appSurface)
        }
        .background(Color.appBackground)
        .navigationTitle("Export Complete")
    }

    // MARK: - Helpers

    private func presetDescription(_ preset: ExportPreset) -> String {
        var parts: [String] = [preset.format.uppercased()]
        if let w = preset.maxWidth, let h = preset.maxHeight {
            parts.append("max \(w)×\(h)")
        } else if let w = preset.maxWidth {
            parts.append("max \(w)px wide")
        } else if let h = preset.maxHeight {
            parts.append("max \(h)px tall")
        } else {
            parts.append("original size")
        }
        if preset.format == "jpeg" {
            parts.append("\(Int(preset.jpegQuality * 100))% quality")
        }
        if !preset.suffix.isEmpty {
            parts.append("suffix: \(preset.suffix)")
        }
        return parts.joined(separator: " · ")
    }

    private func chooseDestination() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select Destination"
        if panel.runModal() == .OK {
            viewModel.destinationURL = panel.url
        }
        #endif
    }
}
