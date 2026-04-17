import SwiftUI
import ImageAssetManagerCore

struct PromptEditorView: View {
    let prompt: Prompt?
    let sectors: [String]
    var onSave: (_ id: String?, _ title: String, _ body: String, _ negativePrompt: String, _ sector: String, _ tags: String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var promptBody: String = ""
    @State private var negativePrompt: String = ""
    @State private var sector: String = ""
    @State private var tags: String = ""

    private var isEditing: Bool { prompt != nil }
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        !promptBody.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Prompt title", text: $title)
                }

                Section("Prompt Body") {
                    TextEditor(text: $promptBody)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                }

                Section("Negative Prompt") {
                    TextEditor(text: $negativePrompt)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 60)
                        .scrollContentBackground(.hidden)
                }

                Section("Metadata") {
                    if !sectors.isEmpty {
                        Picker("Sector", selection: $sector) {
                            Text("None").tag("")
                            ForEach(sectors, id: \.self) { s in
                                Text(s).tag(s)
                            }
                        }
                    } else {
                        TextField("Sector (e.g. Marketing, Product)", text: $sector)
                    }
                    TextField("Tags (comma-separated)", text: $tags)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Prompt" : "New Prompt")
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 520)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(prompt?.id, title, promptBody, negativePrompt, sector, tags)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .onAppear { populateFromPrompt() }
    }

    private func populateFromPrompt() {
        guard let p = prompt else { return }
        title = p.title
        promptBody = p.body
        negativePrompt = p.negativePrompt ?? ""
        sector = p.sector ?? ""
        if let tagsJSON = p.tags {
            tags = tagsJSON
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .replacingOccurrences(of: "\"", with: "")
        }
    }
}
