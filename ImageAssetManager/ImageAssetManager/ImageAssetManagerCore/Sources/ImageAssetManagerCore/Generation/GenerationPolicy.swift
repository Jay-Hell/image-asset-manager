import Foundation

/// Pure decision logic for the generation pipeline — budget gating, reference
/// merging, and quality → model routing. Lives in Core (not the MCP handler)
/// so it's unit-testable without mocking the HTTP server or the Keychain.
public enum GenerationPolicy {

    // MARK: - Budget

    public struct BudgetLimits: Sendable, Equatable {
        public let maxImages: Int
        public let maxCostGBP: Decimal

        public init(maxImages: Int, maxCostGBP: Decimal) {
            self.maxImages = maxImages
            self.maxCostGBP = maxCostGBP
        }

        /// 20 images / £2.50 per call — matches the user-facing policy.
        public static let defaults = BudgetLimits(maxImages: 20, maxCostGBP: Decimal(string: "2.50")!)
    }

    public enum BudgetViolation: Error, Equatable, Sendable {
        case tooManyImages(count: Int, max: Int)
        case tooCostly(subtotal: Decimal, max: Decimal)
    }

    /// Validate that `count × unitCost` fits inside the budget. Returns the
    /// subtotal on success, throws `BudgetViolation` otherwise.
    public static func checkBudget(count: Int, unitCost: Decimal, limits: BudgetLimits) throws -> Decimal {
        if count > limits.maxImages {
            throw BudgetViolation.tooManyImages(count: count, max: limits.maxImages)
        }
        let subtotal = unitCost * Decimal(count)
        if subtotal > limits.maxCostGBP {
            throw BudgetViolation.tooCostly(subtotal: subtotal, max: limits.maxCostGBP)
        }
        return subtotal
    }

    // MARK: - Reference merging

    public struct MergedReferences: Sendable {
        public let references: [GenerationReference]
        public let truncated: Bool
    }

    /// Merge project-derived refs with explicit refs, cap at the provider's
    /// reference limit (default 3). Project refs win precedence when over-cap.
    public static func mergeReferences(
        project: [GenerationReference],
        explicit: [GenerationReference],
        maxReferences: Int = 3
    ) -> MergedReferences {
        let combined = project + explicit
        if combined.count > maxReferences {
            return MergedReferences(references: Array(combined.prefix(maxReferences)), truncated: true)
        }
        return MergedReferences(references: combined, truncated: false)
    }

    // MARK: - Quality → model routing

    public enum Quality: String, Sendable {
        case fast, standard, pro, withReferences = "with_references", auto
    }

    public enum QualityError: Error, Equatable, Sendable {
        case unknown(String)
    }

    public struct ModelRoute: Sendable, Equatable {
        public let modelID: String
        public let autoRouted: Bool
    }

    /// Resolve the target model ID from a requested quality tier and whether
    /// references are attached. When references are attached but the requested
    /// tier can't use them, silently reroute to the reference-capable model
    /// and mark the route as `autoRouted` so the caller can surface a note.
    public static func chooseModel(
        quality: String,
        hasReferences: Bool
    ) throws -> ModelRoute {
        guard let q = Quality(rawValue: quality.lowercased()) else {
            throw QualityError.unknown(quality)
        }

        let target: String
        switch q {
        case .fast:           target = NanaBananaProvider.ModelID.imagenFast
        case .standard:       target = NanaBananaProvider.ModelID.imagenStandard
        case .pro:            target = NanaBananaProvider.ModelID.imagenUltra
        case .withReferences: target = NanaBananaProvider.ModelID.geminiWithRefs
        case .auto:
            target = hasReferences
                ? NanaBananaProvider.ModelID.geminiWithRefs
                : NanaBananaProvider.ModelID.imagenStandard
        }

        if hasReferences && !NanaBananaProvider.supportsReferences(modelID: target) {
            return ModelRoute(modelID: NanaBananaProvider.ModelID.geminiWithRefs, autoRouted: true)
        }
        return ModelRoute(modelID: target, autoRouted: false)
    }
}
