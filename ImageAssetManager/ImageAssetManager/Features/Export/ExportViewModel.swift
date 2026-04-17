import Foundation
import ImageAssetManagerCore

struct ExportResult: Identifiable {
    let id = UUID().uuidString
    let presetName: String
    let outputFilename: String
    let error: String?
    var success: Bool { error == nil }
}

@Observable
final class ExportViewModel {

    // MARK: - Preset management
    var presets: [ExportPreset] = []
    var selectedPresetIDs: Set<String> = []
    var showPresetEditor: Bool = false
    var editingPreset: ExportPreset? = nil

    // MARK: - Export state
    var destinationURL: URL?
    var exportResults: [ExportResult] = []
    var isExporting: Bool = false

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Loading

    func loadPresets() async {
        presets = (try? await database.fetchExportPresets()) ?? []
        // Auto-select all presets if nothing selected yet
        if selectedPresetIDs.isEmpty {
            selectedPresetIDs = Set(presets.map(\.id))
        }
    }

    // MARK: - Preset CRUD

    func savePreset(
        id: String?,
        name: String,
        format: String,
        maxWidth: Int?,
        maxHeight: Int?,
        jpegQuality: Double,
        suffix: String
    ) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        if let id {
            guard var existing = presets.first(where: { $0.id == id }) else { return }
            existing.name = name
            existing.format = format
            existing.maxWidth = maxWidth
            existing.maxHeight = maxHeight
            existing.jpegQuality = jpegQuality
            existing.suffix = suffix
            try await database.updateExportPreset(existing)
        } else {
            let preset = ExportPreset(
                name: name, format: format,
                maxWidth: maxWidth, maxHeight: maxHeight,
                jpegQuality: jpegQuality, suffix: suffix,
                createdAt: now
            )
            try await database.insertExportPreset(preset)
            selectedPresetIDs.insert(preset.id)
        }
        await loadPresets()
    }

    func deletePreset(_ id: String) async throws {
        try await database.deleteExportPreset(id: id)
        selectedPresetIDs.remove(id)
        await loadPresets()
    }

    func startCreate() {
        editingPreset = nil
        showPresetEditor = true
    }

    func startEdit(_ preset: ExportPreset) {
        editingPreset = preset
        showPresetEditor = true
    }

    // MARK: - Export

    func exportAsset(_ asset: Asset, libraryURL: URL) async {
        guard let destDir = destinationURL else { return }
        let chosen = presets.filter { selectedPresetIDs.contains($0.id) }
        guard !chosen.isEmpty else { return }

        isExporting = true
        exportResults = []

        let fileURL = libraryURL.appending(path: "assets").appending(path: asset.filename)
        guard let imageData = try? Data(contentsOf: fileURL) else {
            isExporting = false
            return
        }

        let base = (asset.filename as NSString).deletingPathExtension

        var results: [ExportResult] = []
        for preset in chosen {
            do {
                let outURL = try ImageExporter.export(
                    imageData: imageData,
                    preset: preset,
                    to: destDir,
                    baseFilename: base
                )
                results.append(ExportResult(
                    presetName: preset.name,
                    outputFilename: outURL.lastPathComponent,
                    error: nil
                ))
            } catch {
                results.append(ExportResult(
                    presetName: preset.name,
                    outputFilename: "\(base)\(preset.suffix)",
                    error: error.localizedDescription
                ))
            }
        }

        exportResults = results
        isExporting = false
    }

    func resetExport() {
        exportResults = []
        destinationURL = nil
    }
}
