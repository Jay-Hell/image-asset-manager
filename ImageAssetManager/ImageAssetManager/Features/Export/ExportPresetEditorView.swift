import SwiftUI
import ImageAssetManagerCore

struct ExportPresetEditorView: View {
    let preset: ExportPreset?
    var onSave: (_ id: String?, _ name: String, _ format: String,
                 _ maxWidth: Int?, _ maxHeight: Int?,
                 _ jpegQuality: Double, _ suffix: String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var format: String = "png"
    @State private var maxWidthText: String = ""
    @State private var maxHeightText: String = ""
    @State private var jpegQuality: Double = 0.85
    @State private var suffix: String = ""

    private var isEditing: Bool { preset != nil }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    private var parsedMaxWidth: Int? { Int(maxWidthText.trimmingCharacters(in: .whitespaces)) }
    private var parsedMaxHeight: Int? { Int(maxHeightText.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Preset") {
                    TextField("Name (e.g. Web 1×, Thumbnail)", text: $name)
                    Picker("Format", selection: $format) {
                        Text("PNG").tag("png")
                        Text("JPEG").tag("jpeg")
                        Text("WebP").tag("webp")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Dimensions") {
                    HStack {
                        Text("Max width")
                            .foregroundStyle(Color.appTextSecondary)
                        Spacer()
                        TextField("px (optional)", text: $maxWidthText)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                    }
                    HStack {
                        Text("Max height")
                            .foregroundStyle(Color.appTextSecondary)
                        Spacer()
                        TextField("px (optional)", text: $maxHeightText)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                    }
                    Text("Aspect ratio is preserved. Leave both empty to export at original size.")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }

                if format == "jpeg" {
                    Section("JPEG Quality") {
                        VStack(alignment: .leading, spacing: 4) {
                            Slider(value: $jpegQuality, in: 0.5...1.0, step: 0.05)
                                .tint(Color.appAccent)
                            Text("\(Int(jpegQuality * 100))%")
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                        }
                    }
                }

                Section("Filename") {
                    HStack {
                        Text("Suffix")
                            .foregroundStyle(Color.appTextSecondary)
                        Spacer()
                        TextField("e.g. _2x, _thumb", text: $suffix)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 140)
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                    }
                    Text("Output: original-name\(suffix).\(format == "jpeg" ? "jpg" : format)")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Preset" : "New Preset")
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 380)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(preset?.id, name, format,
                               parsedMaxWidth, parsedMaxHeight,
                               jpegQuality, suffix)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .onAppear { populateFromPreset() }
    }

    private func populateFromPreset() {
        guard let p = preset else { return }
        name = p.name
        format = p.format
        maxWidthText = p.maxWidth.map(String.init) ?? ""
        maxHeightText = p.maxHeight.map(String.init) ?? ""
        jpegQuality = p.jpegQuality
        suffix = p.suffix
    }
}
