import SwiftUI
import ImageAssetManagerCore

struct LibraryMigrationSheetView: View {
    let destinationURL: URL
    var isMigrating: Bool = false
    var onConfirm: (MigrationMode) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New location")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.appTextSecondary)
                    Text(destinationURL.path(percentEncoded: false))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.appTextPrimary)
                        .textSelection(.enabled)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))

                Text("Choose how to transfer the library database, assets, prompts, and configuration files to the new location.")
                    .font(.callout)
                    .foregroundStyle(Color.appTextSecondary)

                Spacer()

                if isMigrating {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Migrating library…")
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 10) {
                        Button {
                            onConfirm(.move)
                        } label: {
                            Label("Move", systemImage: "arrow.right.square")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.appAccent)
                        .controlSize(.large)
                        .accessibilityHint("Moves all files to the new location and removes them from the current one")

                        Button {
                            onConfirm(.copy)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .accessibilityHint("Copies all files to the new location leaving originals in place")
                    }

                    Text("Move removes files from the current location. Copy duplicates them — you can delete the originals manually afterwards.")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .navigationTitle("Change Library Location")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isMigrating)
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 360)
        #endif
    }
}
