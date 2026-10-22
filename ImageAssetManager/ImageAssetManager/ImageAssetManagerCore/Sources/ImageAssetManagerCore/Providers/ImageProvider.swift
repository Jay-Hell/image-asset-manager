import Foundation

public protocol ImageProvider: Sendable {
    var providerID: String { get }
    var displayName: String { get }
    var availableModels: [ImageModel] { get }
    var supportedAspectRatios: [AspectRatio] { get }
    var supportsReferenceImages: Bool { get }
    var maxReferenceImages: Int { get }
    var supportedReferenceRoles: [ReferenceRole] { get }

    func estimateCost(_ params: GenerationParams) -> Decimal
    func generate(_ params: GenerationParams, references: [ReferenceInput]?) async throws -> GeneratedImage
}

public struct ImageModel: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let supportedAspectRatios: [AspectRatio]
    public let costPerImage: Decimal
    /// Per-model reference cap from the catalogue. 0 means the model takes none.
    public let maxReferenceImages: Int
    /// The `imageSize` the request should carry, when the model takes one.
    public let imageSize: String?

    public var supportsReferences: Bool { maxReferenceImages > 0 }

    public init(
        id: String,
        displayName: String,
        supportedAspectRatios: [AspectRatio],
        costPerImage: Decimal,
        maxReferenceImages: Int = 0,
        imageSize: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.supportedAspectRatios = supportedAspectRatios
        self.costPerImage = costPerImage
        self.maxReferenceImages = maxReferenceImages
        self.imageSize = imageSize
    }
}

public enum AspectRatio: String, CaseIterable, Sendable {
    case square = "1:1"
    case landscape = "16:9"
    case portrait = "9:16"
    case custom

    /// The ratio string the provider API takes. `custom` snaps to the nearest of
    /// the three the app offers. One definition, used by the panel and the MCP.
    public func apiRatio(width: Int, height: Int) -> String {
        guard self == .custom else { return rawValue }
        let ratio = Double(width) / Double(max(height, 1))
        return ratio > 1.2 ? "16:9" : ratio < 0.8 ? "9:16" : "1:1"
    }
}

public enum ReferenceRole: String, Sendable {
    case styleAnchor = "style_anchor"
    case subjectAnchor = "subject_anchor"
}

public struct ReferenceInput: Sendable {
    public let assetID: String
    public let imageData: Data
    public let role: ReferenceRole
    public let weight: Float?

    public init(assetID: String, imageData: Data, role: ReferenceRole, weight: Float? = nil) {
        self.assetID = assetID
        self.imageData = imageData
        self.role = role
        self.weight = weight
    }
}

public struct GenerationParams: @unchecked Sendable {
    public let prompt: String
    public let negativePrompt: String?
    public let model: ImageModel
    public let aspectRatio: AspectRatio
    public let width: Int
    public let height: Int
    public let seed: String?
    public let additionalParams: [String: Any]
    /// The budget this call was gated against. A provider that has to change the model
    /// mid-call (a 404 retry) checks the new price against it before the second request.
    public let budget: GenerationPolicy.BudgetContext?

    public init(
        prompt: String,
        negativePrompt: String? = nil,
        model: ImageModel,
        aspectRatio: AspectRatio,
        width: Int,
        height: Int,
        seed: String? = nil,
        additionalParams: [String: Any] = [:],
        budget: GenerationPolicy.BudgetContext? = nil
    ) {
        self.budget = budget
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.model = model
        self.aspectRatio = aspectRatio
        self.width = width
        self.height = height
        self.seed = seed
        self.additionalParams = additionalParams
    }
}

public struct GeneratedImage: @unchecked Sendable {
    public let data: Data
    public let format: String
    public let actualCost: Decimal?
    public let seed: String?
    public let rawResponse: [String: Any]
    /// The model that actually served the request, when the provider changed it mid-call.
    /// Nil means the model in the request.
    public let modelUsed: String?
    /// The GBP estimate for `modelUsed`, set with it.
    public let estimatedCostGBP: Decimal?

    public init(
        data: Data, format: String, actualCost: Decimal? = nil, seed: String? = nil, rawResponse: [String: Any] = [:],
        modelUsed: String? = nil, estimatedCostGBP: Decimal? = nil
    ) {
        self.modelUsed = modelUsed
        self.estimatedCostGBP = estimatedCostGBP
        self.data = data
        self.format = format
        self.actualCost = actualCost
        self.seed = seed
        self.rawResponse = rawResponse
    }
}
