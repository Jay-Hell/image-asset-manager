import Foundation

/// A reference attached to a generation request, with DB provenance.
/// `input` is what gets sent to the provider API; `referenceSetID` /
/// `referenceEntryID` are used to populate `asset_references` rows after the
/// generation succeeds (so the lineage chain stays intact).
public struct GenerationReference: Sendable {
    public let input: ReferenceInput
    public let referenceSetID: String?
    public let referenceEntryID: String?

    public init(input: ReferenceInput, referenceSetID: String? = nil, referenceEntryID: String? = nil) {
        self.input = input
        self.referenceSetID = referenceSetID
        self.referenceEntryID = referenceEntryID
    }
}

/// End-to-end image generation pipeline: provider call → disk write → DB rows
/// → index.json export. Shared by the in-app Generation Panel (eventually) and
/// the MCP `generate_image` tool, so any bug fix or policy change lands in
/// both places at once.
public actor GenerationService {
    private let database: AppDatabase
    private let libraryURL: URL
    private let provider: any ImageProvider
    private let router: RouteExecutor?

    /// `router` serves requests that carry `routes` (the resolver's list, first route first);
    /// without it, or without routes, the one `provider` is called as before.
    public init(database: AppDatabase, libraryURL: URL, provider: any ImageProvider, router: RouteExecutor? = nil) {
        self.database = database
        self.libraryURL = libraryURL
        self.provider = provider
        self.router = router
    }

    public struct Request: @unchecked Sendable {
        public let prompt: String
        public let negativePrompt: String?
        public let model: ImageModel
        public let aspectRatio: AspectRatio
        public let width: Int
        public let height: Int
        public let references: [GenerationReference]
        /// Ordered list of project IDs the asset belongs to. The first entry becomes the
        /// primary (mirrored into `assets.project_id`); subsequent entries add extra memberships.
        /// Empty means no project membership.
        public let projectIDs: [String]
        public let tags: [String]
        public let variantFamilyName: String?
        /// What the caller gated this call against; the provider re-checks it if it must change model.
        public let budget: GenerationPolicy.BudgetContext?
        /// The resolver's routes for this request, first route first. Empty: use the service's provider.
        public let routes: [Resolution]
        /// An exact ratio such as `4:3`, when the three named aspect ratios cannot say it.
        public let ratio: String?

        public var primaryProjectID: String? { projectIDs.first }

        /// The same request gated against another budget (a batch's next image, after spending).
        public func with(budget: GenerationPolicy.BudgetContext?) -> Request {
            Request(
                prompt: prompt, negativePrompt: negativePrompt, model: model, aspectRatio: aspectRatio,
                width: width, height: height, references: references, projectIDs: projectIDs, tags: tags,
                variantFamilyName: variantFamilyName, budget: budget, routes: routes, ratio: ratio)
        }

        public init(
            prompt: String,
            negativePrompt: String? = nil,
            model: ImageModel,
            aspectRatio: AspectRatio,
            width: Int,
            height: Int,
            references: [GenerationReference] = [],
            projectIDs: [String] = [],
            tags: [String] = [],
            variantFamilyName: String? = nil,
            budget: GenerationPolicy.BudgetContext? = nil,
            routes: [Resolution] = [],
            ratio: String? = nil
        ) {
            self.ratio = ratio
            self.routes = routes
            self.budget = budget
            self.prompt = prompt
            self.negativePrompt = negativePrompt
            self.model = model
            self.aspectRatio = aspectRatio
            self.width = width
            self.height = height
            self.references = references
            self.projectIDs = projectIDs
            self.tags = tags
            self.variantFamilyName = variantFamilyName
        }
    }

    public struct Outcome: Sendable {
        public let assetID: String
        public let filename: String
        public let fileURL: URL
        public let modelID: String
        public let providerID: String
        public let estimatedCost: Double
        public let actualCost: Double?
        public let seed: String?
        /// The stored file's MIME type (`image/png`, `image/svg+xml`, …).
        public let mediaType: String
        /// Why earlier routes were left, in order. Empty when the first route served.
        public let fallbackNotes: [String]
    }

    /// What a provider call returned, before anything is stored. The panel holds one while the
    /// user decides whether to keep it; `record` stores it.
    public struct Generated: Sendable {
        public let image: GeneratedImage
        /// Why earlier routes were left, in order. Empty when the first route served.
        public let fallbackNotes: [String]
        /// The provider that served it.
        public let providerID: String
        /// The paid call's ID. Until `record` keeps the image, a `refused_spend` row with this ID
        /// ("not kept") holds the charge; `record` swaps it for the asset's `spend_log` row, which
        /// takes this ID too, and the asset's ID is this ID.
        public let chargeID: String
    }

    /// The reason on the row written the moment a paid image exists.
    public static let notKeptReason = "not kept"
    /// The reason when the provider charged and returned nothing to keep.
    public static let noImageReason = "no image returned"

    /// Generate one image, save it as a library asset, and return the outcome.
    /// `index.json` is re-exported once per call. For batch generation, loop
    /// and accept the repeated export cost (it's milliseconds per pass).
    public func generate(_ request: Request) async throws -> Outcome {
        try await record(try await call(request), for: request)
    }

    /// The provider call alone, along the request's routes with fallback. Nothing is stored.
    public func call(_ request: Request) async throws -> Generated {
        let params = GenerationParams(
            prompt: request.prompt,
            negativePrompt: request.negativePrompt,
            model: request.model,
            aspectRatio: request.aspectRatio,
            width: request.width,
            height: request.height,
            budget: request.budget,
            ratio: request.ratio
        )

        let refInputs = request.references.map(\.input)
        let result: GeneratedImage
        var fallbackNotes: [String] = []
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            if let router, !request.routes.isEmpty {
                let routed = try await router.generate(routes: request.routes, base: params, references: refInputs.isEmpty ? nil : refInputs)
                result = routed.image
                fallbackNotes = routed.fallbackNotes
            } else {
                result = try await provider.generate(params, references: refInputs.isEmpty ? nil : refInputs)
            }
        } catch ProviderError.chargedNoImage(let providerID, let modelID, let cost) {
            // Paid, and nothing came back: the charge is spend all the same.
            let actual = Double(truncating: cost as NSDecimalNumber)
            try await database.insertRefusedSpend(
                providerID: providerID, modelID: modelID, estimatedCost: actual, actualCost: actual,
                reason: Self.noImageReason, timestamp: now)
            throw GenerationServiceError.outputRefused(
                reason: Self.noImageReason, providerID: providerID, modelID: modelID,
                estimatedCost: actual, actualCost: actual)
        }
        let servedBy = result.providerUsed ?? provider.providerID
        // The image is paid for the moment it exists. Write the charge now, before the caller can
        // drop it (Discard, another Generate, quitting); Keep swaps this row for the asset's.
        let chargeID = UUID().uuidString
        let estimate = Double(truncating: (result.estimatedCostGBP ?? provider.estimateCost(params)) as NSDecimalNumber)
        try await database.insertRefusedSpend(
            id: chargeID, providerID: servedBy, modelID: result.modelUsed ?? request.model.id,
            estimatedCost: estimate, actualCost: result.actualCost.map { Double(truncating: $0 as NSDecimalNumber) },
            reason: Self.notKeptReason, timestamp: now)
        return Generated(image: result, fallbackNotes: fallbackNotes, providerID: servedBy, chargeID: chargeID)
    }

    /// Store a generated image and write its rows: asset, spend, tags, references, variant family,
    /// `index.json`. The one place bytes become a library asset, for the MCP and the panel alike.
    public func record(_ generated: Generated, for request: Request) async throws -> Outcome {
        let params = GenerationParams(
            prompt: request.prompt, negativePrompt: request.negativePrompt, model: request.model,
            aspectRatio: request.aspectRatio, width: request.width, height: request.height,
            budget: request.budget, ratio: request.ratio
        )
        let result = generated.image
        let fallbackNotes = generated.fallbackNotes
        let servedBy = generated.providerID

        let now = ISO8601DateFormatter().string(from: Date())
        // A provider that changed model mid-call (a 404 retry) says which, and what it costs.
        let modelID = result.modelUsed ?? request.model.id
        let estimatedCost = Double(truncating: (result.estimatedCostGBP ?? provider.estimateCost(params)) as NSDecimalNumber)
        let actualCost = result.actualCost.map { Double(truncating: $0 as NSDecimalNumber) }

        // The asset's ID is the charge's: a second Keep of the same answer (after a failed one
        // too) finds the asset already there and writes nothing.
        let assetID = generated.chargeID
        let assetsDir = libraryURL.appending(path: "assets")
        if let kept = try await database.fetchAsset(id: assetID) {
            return Outcome(
                assetID: kept.id, filename: kept.filename, fileURL: assetsDir.appending(path: kept.filename),
                modelID: kept.modelID, providerID: kept.providerID,
                estimatedCost: kept.estimatedCost ?? estimatedCost, actualCost: kept.actualCost ?? actualCost,
                seed: result.seed, mediaType: kept.effectiveMediaType?.rawValue ?? result.mimeType ?? "image/\(result.format)",
                fallbackNotes: fallbackNotes)
        }
        // The one place bytes become a file (pass C): stored as delivered and named for what
        // they are, so an `image/svg+xml` answer is an SVG asset (T15). A label the bytes
        // contradict is refused, not trusted. The provider has already charged by now, so a
        // refusal still records the spend and says so.
        let stored: StoredAssetFile
        do {
            stored = try AssetStore.store(
                result.data, mimeType: result.mimeType ?? "image/\(result.format)", assetID: assetID, libraryURL: libraryURL
            )
        } catch let refusal as AssetStoreError {
            // The charge row written at generation time stays the one row; it now says why.
            try await database.updateRefusedSpendReason(id: generated.chargeID, reason: refusal.localizedDescription)
            throw GenerationServiceError.outputRefused(
                reason: refusal.localizedDescription, providerID: servedBy, modelID: modelID,
                estimatedCost: estimatedCost, actualCost: actualCost
            )
        }
        let filename = stored.filename
        let fileURL = stored.fileURL

        let asset = Asset(
            id: assetID,
            filename: filename,
            fileHash: stored.fileHash,
            projectID: request.primaryProjectID,
            providerID: servedBy,
            modelID: modelID,
            prompt: request.prompt,
            negativePrompt: request.negativePrompt,
            width: stored.width ?? request.width,
            height: stored.height ?? request.height,
            aspectRatio: request.ratio ?? request.aspectRatio.rawValue,
            estimatedCost: estimatedCost,
            actualCost: actualCost,
            createdAt: now,
            mediaType: stored.mediaType.rawValue
        )
        // The asset and its spend row go in, and the "not kept" row comes out, in one transaction.
        do {
            try await database.keepCharge(chargeID: generated.chargeID, asset: asset, spend: SpendLog(
                id: generated.chargeID,
                assetID: assetID,
                providerID: servedBy,
                estimatedCost: estimatedCost,
                actualCost: actualCost,
                timestamp: now
            ))
        } catch {
            // Nothing was written; the file must not block a second Keep (it is stored without overwriting).
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }

        if !request.projectIDs.isEmpty {
            try await database.setProjectsForAsset(assetID: assetID, projectIDs: request.projectIDs)
        }

        for name in request.tags.map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            let tag = try await database.findOrCreateTag(name: name)
            try await database.attachTag(tagID: tag.id, assetID: assetID)
        }

        for ref in request.references {
            try await database.insertAssetReference(AssetReference(
                assetID: assetID,
                referenceSetID: ref.referenceSetID,
                referenceEntryID: ref.referenceEntryID,
                roleUsed: ref.input.role.rawValue,
                weightUsed: ref.input.weight.map { Double($0) },
                passedToAPI: true
            ))
        }

        try await database.attachToVariantFamily(
            assetID: assetID,
            projectID: request.primaryProjectID,
            familyName: request.variantFamilyName,
            prompt: request.prompt,
            filename: filename
        )

        let indexURL = libraryURL.appending(path: "index.json")
        try await IndexExporter.export(from: database, to: indexURL, assetsBaseURL: assetsDir)

        return Outcome(
            assetID: assetID,
            filename: filename,
            fileURL: fileURL,
            modelID: modelID,
            providerID: servedBy,
            estimatedCost: estimatedCost,
            actualCost: actualCost,
            seed: result.seed,
            mediaType: stored.mediaType.rawValue,
            fallbackNotes: fallbackNotes
        )
    }
}

public enum GenerationServiceError: Error, LocalizedError {
    /// The provider delivered, and charged for, an image the library would not store.
    case outputRefused(reason: String, providerID: String, modelID: String, estimatedCost: Double, actualCost: Double?)

    public var errorDescription: String? {
        switch self {
        case .outputRefused(let reason, let provider, let model, let estimated, let actual):
            let cost = actual ?? estimated
            return "\(provider) charged about £\(String(format: "%.4f", cost)) for \(model), but the image was refused and not saved (\(reason)). The charge is recorded in Spend."
        }
    }
}
