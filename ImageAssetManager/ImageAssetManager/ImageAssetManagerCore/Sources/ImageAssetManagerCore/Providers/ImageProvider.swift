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

    public init(id: String, displayName: String, supportedAspectRatios: [AspectRatio], costPerImage: Decimal) {
        self.id = id
        self.displayName = displayName
        self.supportedAspectRatios = supportedAspectRatios
        self.costPerImage = costPerImage
    }
}

public enum AspectRatio: String, CaseIterable, Sendable {
    case square = "1:1"
    case landscape = "16:9"
    case portrait = "9:16"
    case custom
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

    public init(
        prompt: String,
        negativePrompt: String? = nil,
        model: ImageModel,
        aspectRatio: AspectRatio,
        width: Int,
        height: Int,
        seed: String? = nil,
        additionalParams: [String: Any] = [:]
    ) {
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

    public init(data: Data, format: String, actualCost: Decimal? = nil, seed: String? = nil, rawResponse: [String: Any] = [:]) {
        self.data = data
        self.format = format
        self.actualCost = actualCost
        self.seed = seed
        self.rawResponse = rawResponse
    }
}
