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
    let refinement: PromptRefinement?
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

    // MARK: - Search & filter
    var searchText: String = ""
    var showHidden: Bool = false

    // MARK: - Multi-select
    var isSelectMode: Bool = false
    var selectedAssetIDs: Set<String> = []

    // MARK: - Import
    var showImportSheet: Bool = false
    var importURLs: [URL] = []
    var importProjectID: String?
    var importCollectionID: String?
    var importTags: String = ""
    var importMode: ImportMode = {
        let raw = UserDefaults.standard.string(forKey: "importMode") ?? ImportMode.copy.rawValue
        return ImportMode(rawValue: raw) ?? .copy
    }()
    var importNaming: ImportNaming = {
        let raw = UserDefaults.standard.string(forKey: "importNaming") ?? ImportNaming.preserveOriginal.rawValue
        return ImportNaming(rawValue: raw) ?? .preserveOriginal
    }()
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
        let capturedShowHidden = showHidden

        do {
            switch sourceSelection {
            case .allAssets:
                assets = try await database.searchAssets(searchText: searchArg, showHidden: capturedShowHidden)
                displayedVariantFamilies = try await database.fetchVariantFamilies()

            case .project(let pid):
                assets = try await database.searchAssets(projectID: pid, searchText: searchArg, showHidden: capturedShowHidden)
                displayedVariantFamilies = try await database.fetchVariantFamilies(projectID: pid)

            case .collection(let cid):
                assets = try await database.searchAssets(collectionID: cid, searchText: searchArg, showHidden: capturedShowHidden)
                displayedVariantFamilies = []

            case .tag(let tid):
                assets = try await database.searchAssets(tagID: tid, searchText: searchArg, showHidden: capturedShowHidden)
                displayedVariantFamilies = []

            case .variantFamily(let vid):
                assets = try await database.searchAssets(variantFamilyID: vid, searchText: searchArg, showHidden: capturedShowHidden)
                displayedVariantFamilies = variantFamilies.filter { $0.0.id == vid }
            }
            variantMemberIDs = (try? await database.fetchVariantMemberAssetIDs()) ?? []
        } catch {
            assets = []
        }
    }

    func selectAsset(_ assetID: String) async {
        selectedAssetID = assetID

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
        async let refinementResult = try? database.fetchRefinement(forAsset: assetID)

        let (tags, refs, variantCtx, usage, refinement) = await (tagsResult, refsResult, variantResult, usageResult, refinementResult)
        inspectorDetail = AssetDetail(
            asset: asset,
            tags: tags,
            references: refs,
            variantContext: variantCtx,
            usage: usage,
            refinement: refinement
        )
    }

    func onSourceChanged() async {
        selectedAssetID = nil
        inspectorDetail = nil
        isSelectMode = false
        selectedAssetIDs = []
        await loadAssets()
    }

    // MARK: - Import

    func importAssets(
        urls: [URL],
        projectID: String?,
        collectionID: String?,
        tagNames: [String],
        mode: ImportMode,
        naming: ImportNaming
    ) async throws {
        isImporting = true
        defer { isImporting = false }

        UserDefaults.standard.set(mode.rawValue, forKey: "importMode")
        UserDefaults.standard.set(naming.rawValue, forKey: "importNaming")

        let assetsDir = libraryURL.appending(path: "assets")
        let now = ISO8601DateFormatter().string(from: Date())

        let dateStr: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MMM-dd"
            return f.string(from: Date())
        }()

        // Pre-populate used names with whatever is already in the assets folder.
        var usedFilenames: Set<String> = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: assetsDir.path(percentEncoded: false))) ?? []
        )

        var batchIndex = 0

        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ["png", "jpg", "jpeg", "webp", "heic"].contains(ext) else { continue }

            batchIndex += 1
            let assetID = UUID().uuidString
            let filename = naming.filename(
                for: url,
                ext: ext,
                dateStr: dateStr,
                batchIndex: batchIndex,
                usedFilenames: &usedFilenames
            )
            let destURL = assetsDir.appending(path: filename)

            switch mode {
            case .move:
                guard (try? FileManager.default.moveItem(at: url, to: destURL)) != nil else { continue }
            case .copy:
                guard let data = try? Data(contentsOf: url) else { continue }
                try data.write(to: destURL)
            }

            let fileData = (try? Data(contentsOf: destURL)) ?? Data()
            let asset = Asset(
                id: assetID,
                filename: filename,
                fileHash: fileData.sha256,
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

    // MARK: - Multi-select actions

    func setHidden(_ ids: Set<String>, hidden: Bool) async throws {
        try await database.setHidden(assetIDs: Array(ids), hidden: hidden)
        if !hidden { return }
        // After hiding, deselect and exit select mode if all selected items are now hidden
        selectedAssetIDs.subtract(ids)
        if selectedAssetIDs.isEmpty { isSelectMode = false }
        if let selected = selectedAssetID, ids.contains(selected) {
            selectedAssetID = nil
            inspectorDetail = nil
        }
        let indexURL = libraryURL.appending(path: "index.json")
        let assetsDir = libraryURL.appending(path: "assets")
        try await IndexExporter.export(from: database, to: indexURL, assetsBaseURL: assetsDir)
        await loadAssets()
    }

    func deleteAssets(_ ids: Set<String>, fromDisk: Bool) async throws {
        if fromDisk {
            let assetsDir = libraryURL.appending(path: "assets")
            for id in ids {
                if let asset = assets.first(where: { $0.id == id }) {
                    try? FileManager.default.removeItem(at: assetsDir.appending(path: asset.filename))
                } else if let asset = try? await database.fetchAsset(id: id) {
                    try? FileManager.default.removeItem(at: assetsDir.appending(path: asset.filename))
                }
            }
        }
        try await database.deleteAssets(ids: Array(ids))

        selectedAssetIDs.subtract(ids)
        if selectedAssetIDs.isEmpty { isSelectMode = false }
        if let selected = selectedAssetID, ids.contains(selected) {
            selectedAssetID = nil
            inspectorDetail = nil
        }

        let indexURL = libraryURL.appending(path: "index.json")
        let assetsDir = libraryURL.appending(path: "assets")
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

    func deleteAsset(_ assetID: String, fromDisk: Bool = true) async throws {
        if fromDisk {
            let assetsDir = libraryURL.appending(path: "assets")
            if let asset = assets.first(where: { $0.id == assetID }) {
                try? FileManager.default.removeItem(at: assetsDir.appending(path: asset.filename))
            }
        }
        try await database.deleteAsset(id: assetID)

        if selectedAssetID == assetID {
            selectedAssetID = nil
            inspectorDetail = nil
        }

        let indexURL = libraryURL.appending(path: "index.json")
        let assetsDir = libraryURL.appending(path: "assets")
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
