import Foundation
import ImageAssetManagerCore

enum SourceSelection: Hashable {
    case allAssets
    case client(String)
    case project(String)
    case tag(String)
    case variantFamily(String)
}

struct AssetDetail {
    let asset: Asset
    let tags: [Tag]
    let projects: [Project]
    let references: [(AssetReference, Asset?)]
    let variantContext: (Variant, [(VariantMember, Asset)])?
    let usage: [AssetUsage]
    let refinement: PromptRefinement?
}

@Observable
final class LibraryViewModel {

    // MARK: - Sidebar data
    var projects: [Project] = []
    var clients: [Client] = []
    var tagsWithCounts: [(Tag, Int)] = []
    var variantFamilies: [(Variant, [(VariantMember, Asset)])] = []
    /// Distinct family names across all projects (including singletons). Used by the
    /// inspector's family picker so the user can move an asset into any existing family.
    var allVariantFamilyNames: [String] = []

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
        async let clientsResult = (try? database.fetchClients()) ?? []
        async let tagsResult = (try? database.fetchTagsWithCounts()) ?? []
        async let variantsResult = (try? database.fetchVariantFamilies()) ?? []
        async let familyNamesResult = (try? database.fetchAllVariantFamilyNames()) ?? []

        let (projs, cls, tags, variants, familyNames) = await (projsResult, clientsResult, tagsResult, variantsResult, familyNamesResult)
        projects = projs
        clients = cls
        tagsWithCounts = tags.filter { $0.1 > 0 }
        variantFamilies = variants
        allVariantFamilyNames = familyNames
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

            case .client(let cid):
                let clientProjectIDs = projects.filter { $0.clientID == cid }.map(\.id)
                assets = try await database.searchAssets(projectIDs: clientProjectIDs, searchText: searchArg, showHidden: capturedShowHidden)
                displayedVariantFamilies = []

            case .project(let pid):
                assets = try await database.searchAssets(projectIDs: [pid], searchText: searchArg, showHidden: capturedShowHidden)
                displayedVariantFamilies = try await database.fetchVariantFamilies(projectID: pid)

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
        async let projectsResult = (try? database.fetchProjectsForAsset(assetID: assetID)) ?? []
        async let refsResult = (try? database.fetchReferencesForAsset(assetID: assetID)) ?? []
        async let variantResult = try? database.fetchVariantContext(assetID: assetID)
        async let usageResult = (try? database.fetchUsageForAsset(assetID: assetID)) ?? []
        async let refinementResult = try? database.fetchRefinement(forAsset: assetID)

        let (tags, projs, refs, variantCtx, usage, refinement) = await (tagsResult, projectsResult, refsResult, variantResult, usageResult, refinementResult)
        inspectorDetail = AssetDetail(
            asset: asset,
            tags: tags,
            projects: projs,
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
            f.dateFormat = "yyyy-MM-dd"
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
                providerID: "imported",
                modelID: "imported",
                createdAt: now,
                importedAt: now
            )
            try await database.insertAsset(asset)

            if let pid = projectID {
                try await database.setProjectsForAsset(assetID: assetID, projectIDs: [pid])
            }

            for name in tagNames {
                let tag = try await database.findOrCreateTag(name: name)
                try await database.attachTag(tagID: tag.id, assetID: assetID)
            }

            try await database.attachToVariantFamily(
                assetID: assetID,
                projectID: projectID,
                familyName: nil,
                prompt: nil,
                filename: filename
            )
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

    /// Move an asset to the named variant family (creating the family if needed). Empty names
    /// are rejected upstream — the invariant is every asset has at least one family membership.
    /// Add a tag (created on the fly if new) to every asset in `ids`.
    func bulkAddTag(ids: Set<String>, tagName: String) async throws {
        try await database.bulkAddTagToAssets(assetIDs: Array(ids), tagName: tagName)
        let indexURL = libraryURL.appending(path: "index.json")
        let assetsDir = libraryURL.appending(path: "assets")
        try await IndexExporter.export(from: database, to: indexURL, assetsBaseURL: assetsDir)
        await loadSidebarData()
        await loadAssets()
        if let sid = selectedAssetID, ids.contains(sid) {
            await selectAsset(sid)
        }
    }

    /// Remove every tag from every asset in `ids`.
    func bulkClearTags(ids: Set<String>) async throws {
        try await database.bulkClearTagsForAssets(assetIDs: Array(ids))
        let indexURL = libraryURL.appending(path: "index.json")
        let assetsDir = libraryURL.appending(path: "assets")
        try await IndexExporter.export(from: database, to: indexURL, assetsBaseURL: assetsDir)
        await loadSidebarData()
        await loadAssets()
        if let sid = selectedAssetID, ids.contains(sid) {
            await selectAsset(sid)
        }
    }

    /// Toggle isHidden for a single asset from the inspector.
    func toggleHidden(assetID: String) async throws {
        let asset: Asset?
        if let found = assets.first(where: { $0.id == assetID }) {
            asset = found
        } else {
            asset = try? await database.fetchAsset(id: assetID)
        }
        guard let asset else { return }
        try await database.setHidden(assetIDs: [assetID], hidden: !asset.isHidden)
        let indexURL = libraryURL.appending(path: "index.json")
        let assetsDir = libraryURL.appending(path: "assets")
        try await IndexExporter.export(from: database, to: indexURL, assetsBaseURL: assetsDir)
        await loadAssets()
        if selectedAssetID == assetID {
            await selectAsset(assetID)
        }
    }

    /// Add one project to every asset in `ids`. Existing memberships are preserved.
    func bulkAddProject(ids: Set<String>, projectID: String) async throws {
        try await database.bulkAddAssetsToProject(assetIDs: Array(ids), projectID: projectID)
        let indexURL = libraryURL.appending(path: "index.json")
        let assetsDir = libraryURL.appending(path: "assets")
        try await IndexExporter.export(from: database, to: indexURL, assetsBaseURL: assetsDir)
        await loadSidebarData()
        await loadAssets()
        if let sid = selectedAssetID, ids.contains(sid) {
            await selectAsset(sid)
        }
    }

    /// Remove every project membership from every asset in `ids`.
    func bulkClearProjects(ids: Set<String>) async throws {
        try await database.bulkClearAssetProjects(assetIDs: Array(ids))
        let indexURL = libraryURL.appending(path: "index.json")
        let assetsDir = libraryURL.appending(path: "assets")
        try await IndexExporter.export(from: database, to: indexURL, assetsBaseURL: assetsDir)
        await loadSidebarData()
        await loadAssets()
        if let sid = selectedAssetID, ids.contains(sid) {
            await selectAsset(sid)
        }
    }

    /// Replace an asset's project memberships. Pass an empty array to detach from all projects.
    /// The first ID becomes the primary.
    func setAssetProjects(assetID: String, projectIDs: [String]) async throws {
        try await database.setProjectsForAsset(assetID: assetID, projectIDs: projectIDs)
        let indexURL = libraryURL.appending(path: "index.json")
        let assetsDir = libraryURL.appending(path: "assets")
        try await IndexExporter.export(from: database, to: indexURL, assetsBaseURL: assetsDir)
        await loadAssets()
        if selectedAssetID == assetID {
            await selectAsset(assetID)
        }
    }

    func updateAssetVariantFamily(assetID: String, familyName: String) async throws {
        let asset: Asset?
        if let found = assets.first(where: { $0.id == assetID }) {
            asset = found
        } else {
            asset = try? await database.fetchAsset(id: assetID)
        }
        guard let asset else { return }
        _ = try await database.moveAssetToVariantFamily(
            assetID: assetID,
            newFamilyName: familyName,
            projectID: asset.projectID
        )
        let indexURL = libraryURL.appending(path: "index.json")
        let assetsDir = libraryURL.appending(path: "assets")
        try await IndexExporter.export(from: database, to: indexURL, assetsBaseURL: assetsDir)
        await loadSidebarData()
        await loadAssets()
        if selectedAssetID == assetID {
            await selectAsset(assetID)
        }
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
