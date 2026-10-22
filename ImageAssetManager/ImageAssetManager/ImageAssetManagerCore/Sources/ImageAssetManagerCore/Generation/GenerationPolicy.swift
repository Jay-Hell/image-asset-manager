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

    /// What a call was gated against: how many images and the limits. Carried into the
    /// provider so a mid-call model change is priced and checked again.
    public struct BudgetContext: Sendable, Equatable {
        public let count: Int
        public let limits: BudgetLimits
        /// What the batch has already spent (GBP). A re-check prices against the cap that is left.
        public let spentGBP: Decimal

        public init(count: Int, limits: BudgetLimits, spentGBP: Decimal = 0) {
            self.count = count
            self.limits = limits
            self.spentGBP = spentGBP
        }

        /// The limits a re-check (fallback route, 404 retry) holds the next price against:
        /// the cap less what has been spent.
        public var remainingLimits: BudgetLimits {
            BudgetLimits(maxImages: limits.maxImages, maxCostGBP: max(0, limits.maxCostGBP - spentGBP))
        }
    }

    // MARK: - Budget clamping (server-held ceiling)
    // (BudgetViolation's user-facing text is in the extension at the foot of this file.)

    /// The app-held hard ceiling for MCP calls. Caller-supplied `max_images` /
    /// `max_cost_gbp` are clamped to this — the server owns the guardrail, not
    /// the caller. 50 images / £5.00 unless overridden in app settings.
    public static let mcpCeilingDefaults = BudgetLimits(
        maxImages: 50, maxCostGBP: Decimal(string: "5.00")!)

    public struct ClampedLimits: Sendable, Equatable {
        public let limits: BudgetLimits
        public let clampedImages: Bool
        public let clampedCost: Bool

        public init(limits: BudgetLimits, clampedImages: Bool, clampedCost: Bool) {
            self.limits = limits
            self.clampedImages = clampedImages
            self.clampedCost = clampedCost
        }
    }

    /// Clamp caller-requested limits to the app-held ceiling. Pure — the MCP
    /// handler supplies the ceiling from settings and reports any clamp in the
    /// response notes so agents learn the real bound instead of guessing.
    public static func clampLimits(requested: BudgetLimits, ceiling: BudgetLimits) -> ClampedLimits {
        let images = min(requested.maxImages, ceiling.maxImages)
        let cost = min(requested.maxCostGBP, ceiling.maxCostGBP)
        return ClampedLimits(
            limits: BudgetLimits(maxImages: images, maxCostGBP: cost),
            clampedImages: images < requested.maxImages,
            clampedCost: cost < requested.maxCostGBP
        )
    }

    // MARK: - Reference merging

    public struct MergedReferences: Sendable {
        public let references: [GenerationReference]
        public let truncated: Bool
    }

    /// Merge project-derived refs with explicit refs, cap at the resolved model's
    /// `maxReferenceImages` (from the catalogue). Project refs win precedence when over-cap.
    public static func mergeReferences(
        project: [GenerationReference],
        explicit: [GenerationReference],
        maxReferences: Int
    ) -> MergedReferences {
        let combined = project + explicit
        if combined.count > maxReferences {
            return MergedReferences(references: Array(combined.prefix(maxReferences)), truncated: true)
        }
        return MergedReferences(references: combined, truncated: false)
    }

    // MARK: - Quality names

    /// The quality names callers use. Which model each means is `ModelResolver`'s
    /// decision, from the catalogue; nothing here names a model.
    public enum Quality: String, Sendable {
        case fast, standard, pro, withReferences = "with_references", auto
    }
}

extension GenerationPolicy.BudgetViolation: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tooManyImages(let count, let max):
            return "\(count) images is over the limit of \(max) per call."
        case .tooCostly(let subtotal, let max):
            return "This would cost about £\(subtotal.formatted(.number.precision(.fractionLength(2)))), over the £\(max.formatted(.number.precision(.fractionLength(2)))) limit per call. Pick a cheaper model or size."
        }
    }
}
