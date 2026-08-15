import Testing
import Foundation
@testable import ImageAssetManagerCore

@Suite("GenerationPolicy.Budget")
struct BudgetTests {

    @Test func acceptsWhenWithinBothLimits() throws {
        let subtotal = try GenerationPolicy.checkBudget(
            count: 4,
            unitCost: Decimal(string: "0.03")!,
            limits: .defaults
        )
        #expect(subtotal == Decimal(string: "0.12"))
    }

    @Test func rejectsWhenCountExceedsMaxImages() {
        #expect(throws: GenerationPolicy.BudgetViolation.self) {
            try GenerationPolicy.checkBudget(
                count: 21,
                unitCost: Decimal(string: "0.01")!,
                limits: .defaults
            )
        }
    }

    @Test func rejectsWhenSubtotalExceedsMaxCost() {
        #expect(throws: GenerationPolicy.BudgetViolation.self) {
            try GenerationPolicy.checkBudget(
                count: 20,
                unitCost: Decimal(string: "0.20")!,   // 20 × 0.20 = 4.00 > 2.50
                limits: .defaults
            )
        }
    }

    @Test func rejectsCountViolationEvenWhenCostWouldBeFine() {
        #expect(throws: GenerationPolicy.BudgetViolation.self) {
            try GenerationPolicy.checkBudget(
                count: 21,
                unitCost: Decimal(string: "0.001")!,
                limits: .defaults
            )
        }
    }

    @Test func customLimitsOverrideDefaults() throws {
        // 50 images at £0.05 = £2.50 exactly, should pass a 50/£3.00 limit.
        let custom = GenerationPolicy.BudgetLimits(maxImages: 50, maxCostGBP: Decimal(string: "3.00")!)
        let subtotal = try GenerationPolicy.checkBudget(
            count: 50,
            unitCost: Decimal(string: "0.05")!,
            limits: custom
        )
        #expect(subtotal == Decimal(string: "2.50"))
    }

    @Test func defaultsAre20AndTwoFiftyGBP() {
        #expect(GenerationPolicy.BudgetLimits.defaults.maxImages == 20)
        #expect(GenerationPolicy.BudgetLimits.defaults.maxCostGBP == Decimal(string: "2.50"))
    }
}

@Suite("GenerationPolicy.References")
struct ReferenceMergeTests {

    private func makeRef(_ id: String) -> GenerationReference {
        GenerationReference(
            input: ReferenceInput(
                assetID: id,
                imageData: Data(),
                role: .subjectAnchor,
                weight: nil
            )
        )
    }

    @Test func emptyInputsProduceEmptyOutput() {
        let merged = GenerationPolicy.mergeReferences(project: [], explicit: [])
        #expect(merged.references.isEmpty)
        #expect(!merged.truncated)
    }

    @Test func projectOnlyPassesThrough() {
        let merged = GenerationPolicy.mergeReferences(
            project: [makeRef("a"), makeRef("b")],
            explicit: []
        )
        #expect(merged.references.map(\.input.assetID) == ["a", "b"])
        #expect(!merged.truncated)
    }

    @Test func explicitOnlyPassesThrough() {
        let merged = GenerationPolicy.mergeReferences(
            project: [],
            explicit: [makeRef("x"), makeRef("y")]
        )
        #expect(merged.references.map(\.input.assetID) == ["x", "y"])
        #expect(!merged.truncated)
    }

    @Test func projectComesBeforeExplicit() {
        let merged = GenerationPolicy.mergeReferences(
            project: [makeRef("p1"), makeRef("p2")],
            explicit: [makeRef("e1")]
        )
        #expect(merged.references.map(\.input.assetID) == ["p1", "p2", "e1"])
        #expect(!merged.truncated)
    }

    @Test func truncatesAtThreeWithProjectPriority() {
        let merged = GenerationPolicy.mergeReferences(
            project: [makeRef("p1"), makeRef("p2")],
            explicit: [makeRef("e1"), makeRef("e2")]
        )
        #expect(merged.references.map(\.input.assetID) == ["p1", "p2", "e1"])
        #expect(merged.truncated)
    }
}

@Suite("GenerationPolicy.Routing")
struct QualityRoutingTests {

    @Test func fastMapsToImagenFast() throws {
        let r = try GenerationPolicy.chooseModel(quality: "fast", hasReferences: false)
        #expect(r.modelID == NanaBananaProvider.ModelID.imagenFast)
        #expect(!r.autoRouted)
    }

    @Test func standardMapsToImagenStandard() throws {
        let r = try GenerationPolicy.chooseModel(quality: "standard", hasReferences: false)
        #expect(r.modelID == NanaBananaProvider.ModelID.imagenStandard)
        #expect(!r.autoRouted)
    }

    @Test func proMapsToImagenUltra() throws {
        let r = try GenerationPolicy.chooseModel(quality: "pro", hasReferences: false)
        #expect(r.modelID == NanaBananaProvider.ModelID.imagenUltra)
        #expect(!r.autoRouted)
    }

    @Test func withReferencesMapsToGemini() throws {
        let r = try GenerationPolicy.chooseModel(quality: "with_references", hasReferences: true)
        #expect(r.modelID == NanaBananaProvider.ModelID.geminiWithRefs)
        #expect(!r.autoRouted)
    }

    @Test func autoPicksStandardWhenNoReferences() throws {
        let r = try GenerationPolicy.chooseModel(quality: "auto", hasReferences: false)
        #expect(r.modelID == NanaBananaProvider.ModelID.imagenStandard)
        #expect(!r.autoRouted)
    }

    @Test func autoPicksGeminiWhenReferencesPresent() throws {
        let r = try GenerationPolicy.chooseModel(quality: "auto", hasReferences: true)
        #expect(r.modelID == NanaBananaProvider.ModelID.geminiWithRefs)
        // auto is an explicit choice, not a rerouting
        #expect(!r.autoRouted)
    }

    @Test func proWithRefsAutoRoutesToGemini() throws {
        let r = try GenerationPolicy.chooseModel(quality: "pro", hasReferences: true)
        #expect(r.modelID == NanaBananaProvider.ModelID.geminiWithRefs)
        #expect(r.autoRouted)
    }

    @Test func fastWithRefsAutoRoutesToGemini() throws {
        let r = try GenerationPolicy.chooseModel(quality: "fast", hasReferences: true)
        #expect(r.modelID == NanaBananaProvider.ModelID.geminiWithRefs)
        #expect(r.autoRouted)
    }

    @Test func standardWithRefsAutoRoutesToGemini() throws {
        let r = try GenerationPolicy.chooseModel(quality: "standard", hasReferences: true)
        #expect(r.modelID == NanaBananaProvider.ModelID.geminiWithRefs)
        #expect(r.autoRouted)
    }

    @Test func unknownQualityThrows() {
        #expect(throws: GenerationPolicy.QualityError.self) {
            try GenerationPolicy.chooseModel(quality: "ultra-ultra", hasReferences: false)
        }
    }

    @Test func qualityIsCaseInsensitive() throws {
        let r = try GenerationPolicy.chooseModel(quality: "FAST", hasReferences: false)
        #expect(r.modelID == NanaBananaProvider.ModelID.imagenFast)
    }
}


@Suite("GenerationPolicy.ClampLimits")
struct ClampLimitsTests {

    @Test func withinCeilingPassesThroughUnclamped() {
        let requested = GenerationPolicy.BudgetLimits(maxImages: 10, maxCostGBP: Decimal(string: "1.00")!)
        let result = GenerationPolicy.clampLimits(requested: requested, ceiling: GenerationPolicy.mcpCeilingDefaults)
        #expect(result.limits == requested)
        #expect(!result.clampedImages && !result.clampedCost)
    }

    @Test func costAboveCeilingIsClamped() {
        let requested = GenerationPolicy.BudgetLimits(maxImages: 10, maxCostGBP: Decimal(999))
        let result = GenerationPolicy.clampLimits(requested: requested, ceiling: GenerationPolicy.mcpCeilingDefaults)
        #expect(result.limits.maxCostGBP == GenerationPolicy.mcpCeilingDefaults.maxCostGBP)
        #expect(result.clampedCost)
        #expect(!result.clampedImages)
    }

    @Test func imagesAboveCeilingIsClamped() {
        let requested = GenerationPolicy.BudgetLimits(maxImages: 1000, maxCostGBP: Decimal(string: "0.50")!)
        let result = GenerationPolicy.clampLimits(requested: requested, ceiling: GenerationPolicy.mcpCeilingDefaults)
        #expect(result.limits.maxImages == GenerationPolicy.mcpCeilingDefaults.maxImages)
        #expect(result.clampedImages)
        #expect(!result.clampedCost)
    }

    @Test func bothAboveCeilingBothClamped() {
        let requested = GenerationPolicy.BudgetLimits(maxImages: 1000, maxCostGBP: Decimal(999))
        let result = GenerationPolicy.clampLimits(requested: requested, ceiling: GenerationPolicy.mcpCeilingDefaults)
        #expect(result.limits == GenerationPolicy.mcpCeilingDefaults)
        #expect(result.clampedImages && result.clampedCost)
    }
}
