import SwiftUI
import ImageAssetManagerCore

struct LibraryBrowserView: View {
    @Bindable var viewModel: LibraryViewModel
    var onGenerate: () -> Void
    var onRegenerate: (Asset) -> Void
    var onExport: (Asset) -> Void

    var body: some View {
        NavigationSplitView {
            SourcePanelView(viewModel: viewModel, onGenerate: onGenerate)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            AssetGridView(viewModel: viewModel, onGenerate: onGenerate)
                .navigationSplitViewColumnWidth(min: 320, ideal: 600)
        } detail: {
            Group {
                if let detail = viewModel.inspectorDetail {
                    InspectorPanelView(
                        detail: detail,
                        libraryURL: viewModel.libraryURL,
                        allVariantFamilyNames: viewModel.allVariantFamilyNames,
                        onTagsChanged: { tagNames in
                            Task { try? await viewModel.updateAssetTags(assetID: detail.asset.id, tagNames: tagNames) }
                        },
                        onDelete: { fromDisk in
                            Task { try? await viewModel.deleteAsset(detail.asset.id, fromDisk: fromDisk) }
                        },
                        onRegenerate: { onRegenerate(detail.asset) },
                        onExport: { onExport(detail.asset) },
                        onPromoteVariant: { memberID, variantID in
                            Task { await viewModel.promoteVariantMember(memberID: memberID, in: variantID) }
                        },
                        onVariantFamilyChanged: { newName in
                            Task { try? await viewModel.updateAssetVariantFamily(assetID: detail.asset.id, familyName: newName) }
                        }
                    )
                } else {
                    Color.appBackground.ignoresSafeArea()
                        .overlay {
                            Text("Select an asset to inspect")
                                .foregroundStyle(Color.appTextSecondary)
                                .font(.callout)
                        }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        }
        .background(Color.appBackground)
        .sheet(isPresented: $viewModel.showImportSheet) {
            ImportView(viewModel: viewModel)
        }
        .task {
            await viewModel.loadSidebarData()
            await viewModel.loadAssets()
        }
    }
}
