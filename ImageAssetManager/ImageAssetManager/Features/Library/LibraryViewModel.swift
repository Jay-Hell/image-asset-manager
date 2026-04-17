import Foundation
import ImageAssetManagerCore

enum SourceSelection: Hashable {
    case allAssets
    case project(String)
    case collection(String)
    case tag(String)
    case variantFamily(String)
}

struct AssetDetail {
    let asset: Asset
    let tags: [Tag]
    let references: [(AssetReference, Asset?)]
    let variantContext: (Variant, [(VariantMember, Asset)])?
    let usage: [AssetUsage]
}

@Observable
final class LibraryViewModel {

    // MARK: - Sidebar data
    var projects: [Project] = []
    var allCollections: [ImageCollection] = []
    var tagsWithCounts: [(Tag, Int)] = []
    var variantFamilies: [(Variant, [(VariantMember, Asset)])] = []

    // MARK: - Selection
    var sourceSelection: SourceSelection = .allAssets
    var selectedAssetID: String?

    // MARK: - Grid content
    var assets: [Asset] = []
    var variantMemberIDs: Set<String> = []
    var displayedVariantFamilies: [(Variant, [(VariantMember, Asset)])] = []

    // MARK: - Inspector
    var inspectorDetail: AssetDetail?

    // MARK: - Search
    var searchText: String = ""

    // MARK: - Import
    var showImportSheet: Bool = false
    var importURLs: [URL] = []
    var importProjectID: String?
    var importCollectionID: String?
    var importTags: String = ""
    var isImporting: Bool = false

    var isLoading: Bool = false

    private let database: AppDatabase
    let libraryURL: URL

    init(database: AppDatabase, libraryURL: URL) {
        self.database = database
        self.libraryURL = libraryURL
    }

    // MARK: - Loading

    func loadSidebarData() async {
        // async let bindings: no explicit `await` inside — Swift inserts it at consumption
        async let projsResult = (try? database.fetchProjects()) ?? []
        async let collsResult = (try? database.fetchAllCollections()) ?? []
        async let tagsResult = (try? database.fetchTagsWithCounts()) ?? []
        async let variantsResult = (try? database.fetchVariantFamilies()) ?? []

        let (projs, colls, tags, variants) = await (projsResult, collsResult, tagsResult, variantsResult)
        projects = projs
        allCollections = colls
        tagsWithCounts = tags.filter { $0.1 > 0 }
        variantFamilies = variants
    }

    func loadAssets() async {
        isLoading = true
        defer { isLoading = false }

        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchArg: String? = text.isEmpty ? nil : text

        do {
            switch sourceSelection {
            case .allAssets:
                assets = try await database.searchAssets(searchText: searchArg)
                displayedVariantFamilies = try await database.fetchVariantFamilies()

            case .project(let pid):
                assets = try await database.searchAssets(projectID: pid, searchText: searchArg)
                displayedVariantFamilies = try await database.fetchVariantFamilies(projectID: pid)

            case .collection(let cid):
                assets = try await database.searchAssets(collectionID: cid, searchText: searchArg)
                displayedVariantFamilies = []

            case .tag(let tid):
                assets = try await database.searchAssets(tagID: tid, searchText: searchArg)
                displayedVariantFamilies = []

            case .variantFamily(let vid):
                assets = try await database.searchAssets(variantFamilyID: vid, searchText: searchArg)
                displayedVariantFamilies = variantFamilies.filter { $0.0.id == vid }
            }
            variantMemberIDs = (try? await database.fetchVariantMemberAssetIDs()) ?? []
        } catch {
            assets = []
        }
    }

    func selectAsset(_ assetID: String) async {
        selectedAssetID = assetID

        // Check grid first, then fall back to a DB fetch (e.g. filmstrip selection)
        let asset: Asset?
        if let found = assets.first(where: { $0.id == assetID }) {
            asset = found
        } else {
            asset = try? await database.fetchAsset(id: assetID)
        }
        guard let asset else { return }

        async let tagsResult = (try? database.fetchTagsForAsset(assetID: assetID)) ?? []
        async let refsResult = (try? database.fetchReferencesForAsset(assetID: assetID)) ?? []
        async let variantResult = try? database.fetchVariantContext(assetID: assetID)
        async let usageResult = (try? database.fetchUsageForAsset(assetID: assetID)) ?? []

        let (tags, refs, variantCtx, usage) = await (tagsResult, refsResult, variantResult, usageResult)
        inspectorDetail = AssetDetail(
            asset: asset,
            tags: tags,
            references: refs,
            variantContext: variantCtx,
            usage: usage
        )
    }

    func onSourceChanged() async {
        selectedAssetID = nil
        inspectorDetail = nil
        await loadAssets()
    }

    // MARK: - Import

    func importAssets(urls: [URL], projectID: String?, collectionID: String?, tagNames: [String]) async throws {
        isImporting = true
        defer { isImporting = false }

        let assetsDir = libraryURL.appending(path: "assets")
        let now = ISO8601DateFormatter().string(from: Date())

        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let ext = url.pathExtension.lowercased()
            guard ["png", "jpg", "jpeg", "webp", "heic"].contains(ext) else { continue }

            let assetID = UUID().uuidString
            let filename = "\(assetID).\(ext)"
            try data.write(to: assetsDir.appending(path: filename))

            let asset = Asset(
                id: assetID,
                filename: filename,
                fileHash: data.sha256,
                projectID: projectID,
                collectionID: collectionID,
                providerID: "imported",
                modelID: "imported",
                createdAt: now,
                importedAt: now
            )
            try await database.insertAsset(asset)

            for name in tagNames {
                let tag = try await database.findOrCreateTag(name: name)
                try await database.attachTag(tagID: tag.id, assetID: assetID)
            }
        }

        let indexURL = libraryURL.appending(path: "index.json")
        try await IndexExporter.export(from: database, to: indexURL, assetsBaseURL: assetsDir)

        await loadSidebarData()
        await loadAssets()
    }

    // MARK: - Mutations

    func promoteVariantMember(memberID: String, in variantID: String) async {
        try? await database.promoteVariantMember(memberID: memberID, in: variantID)
        await loadSidebarData()
        await loadAssets()
    }

    func deleteAsset(_ assetID: String) async throws {
        let assetsDir = libraryURL.appending(path: "assets")
        if let asset = assets.first(where: { $0.id == assetID }) {
            try? FileManager.default.removeItem(at: assetsDir.appending(path: asset.filename))
        }
        try await database.deleteAsset(id: assetID)

        if selectedAssetID == assetID {
            selectedAssetID = nil
            inspectorDetail = nil
        }

        let indexURL = libraryURL.appending(path: "index.json")
        try await IndexExporter.export(from: database, to: indexURL, assetsBaseURL: assetsDir)

        await loadSidebarData()
        await loadAssets()
    }

    func updateAssetTags(assetID: String, tagNames: [String]) async throws {
        try await database.setTagsForAsset(assetID: assetID, tagNames: tagNames)
        if selectedAssetID == assetID {
            await selectAsset(assetID)
        }
        await loadSidebarData()
    }
}
