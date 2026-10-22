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

    // MARK: - Budget clamping (server-held ceiling)

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
