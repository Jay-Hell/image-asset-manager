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

    public init(database: AppDatabase, libraryURL: URL, provider: any ImageProvider) {
        self.database = database
        self.libraryURL = libraryURL
        self.provider = provider
    }

    public struct Request: @unchecked Sendable {
        public let prompt: String
        public let negativePrompt: String?
        public let model: ImageModel
        public let aspectRatio: AspectRatio
        public let width: Int
        public let height: Int
        public let references: [GenerationReference]
        public let projectID: String?
        public let collectionID: String?
        public let tags: [String]
        public let variantFamilyName: String?

        public init(
            prompt: String,
            negativePrompt: String? = nil,
            model: ImageModel,
            aspectRatio: AspectRatio,
            width: Int,
            height: Int,
            references: [GenerationReference] = [],
            projectID: String? = nil,
            collectionID: String? = nil,
            tags: [String] = [],
            variantFamilyName: String? = nil
        ) {
            self.prompt = prompt
            self.negativePrompt = negativePrompt
            self.model = model
            self.aspectRatio = aspectRatio
            self.width = width
            self.height = height
            self.references = references
            self.projectID = projectID
            self.collectionID = collectionID
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
    }

    /// Generate one image, save it as a library asset, and return the outcome.
    /// `index.json` is re-exported once per call. For batch generation, loop
    /// and accept the repeated export cost (it's milliseconds per pass).
    public func generate(_ request: Request) async throws -> Outcome {
        let params = GenerationParams(
            prompt: request.prompt,
            negativePrompt: request.negativePrompt,
            model: request.model,
            aspectRatio: request.aspectRatio,
            width: request.width,
            height: request.height
        )

        let refInputs = request.references.map(\.input)
        let result = try await provider.generate(params, references: refInputs.isEmpty ? nil : refInputs)

        let assetID = UUID().uuidString
        let filename = "\(assetID).\(result.format)"
        let assetsDir = libraryURL.appending(path: "assets")
        let fileURL = assetsDir.appending(path: filename)

        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try result.data.write(to: fileURL)

        let now = ISO8601DateFormatter().string(from: Date())
        let estimatedCost = Double(truncating: provider.estimateCost(params) as NSDecimalNumber)
        let actualCost = result.actualCost.map { Double(truncating: $0 as NSDecimalNumber) }

        let asset = Asset(
            id: assetID,
            filename: filename,
            fileHash: result.data.sha256,
            projectID: request.projectID,
            collectionID: request.collectionID,
            providerID: provider.providerID,
            modelID: request.model.id,
            prompt: request.prompt,
            negativePrompt: request.negativePrompt,
            width: request.width,
            height: request.height,
            aspectRatio: request.aspectRatio.rawValue,
            estimatedCost: estimatedCost,
            actualCost: actualCost,
            createdAt: now
        )
        try await database.insertAsset(asset)

        try await database.insertSpendLog(SpendLog(
            assetID: assetID,
            providerID: provider.providerID,
            estimatedCost: estimatedCost,
            actualCost: actualCost,
            timestamp: now
        ))

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

        if let vfName = request.variantFamilyName?.trimmingCharacters(in: .whitespaces),
           !vfName.isEmpty,
           let projectID = request.projectID {
            let variant = try await database.findOrCreateVariant(name: vfName, projectID: projectID)
            let seq = try await database.variantMemberCount(variantID: variant.id)
            try await database.insertVariantMember(
                VariantMember(variantID: variant.id, assetID: assetID, sequence: seq + 1, isSelected: seq == 0)
            )
        }

        let indexURL = libraryURL.appending(path: "index.json")
        try await IndexExporter.export(from: database, to: indexURL, assetsBaseURL: assetsDir)

        return Outcome(
            assetID: assetID,
            filename: filename,
            fileURL: fileURL,
            modelID: request.model.id,
            providerID: provider.providerID,
            estimatedCost: estimatedCost,
            actualCost: actualCost,
            seed: result.seed
        )
    }
}
