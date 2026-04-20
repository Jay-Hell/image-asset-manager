import Testing
import Foundation
@testable import ImageAssetManagerCore

@Suite("PromptFlattener")
struct PromptFlattenerTests {

    @Test func textInputIsPassedThroughUnchanged() {
        let result = PromptFlattener.flatten(.text("A golden retriever in a field at sunset."))
        #expect(result == "A golden retriever in a field at sunset.")
    }

    @Test func canonicalKeysRenderInSubjectContextStyleOrder() {
        let result = PromptFlattener.flatten(.structured([
            "style":   "photograph, 85mm lens",
            "subject": "a golden retriever",
            "context": "in a field at sunset",
        ]))
        // Subject must come before Context, which must come before Style.
        let subjIdx  = result.range(of: "Subject")!.lowerBound
        let ctxIdx   = result.range(of: "Context")!.lowerBound
        let styleIdx = result.range(of: "Style")!.lowerBound
        #expect(subjIdx < ctxIdx)
        #expect(ctxIdx < styleIdx)
    }

    @Test func nestedDictsAreFlattenedRecursively() {
        let result = PromptFlattener.flatten(.structured([
            "style": [
                "medium":   "oil painting",
                "lighting": "golden hour",
            ] as [String: Any],
        ]))
        #expect(result.contains("Medium: oil painting"))
        #expect(result.contains("Lighting: golden hour"))
    }

    @Test func arraysOfStringsJoinWithCommas() {
        let result = PromptFlattener.flatten(.structured([
            "palette": ["warm amber", "dusky purple", "muted gold"],
        ]))
        #expect(result.contains("Palette: warm amber, dusky purple, muted gold"))
    }

    @Test func extraArrayEmitsAsBareText() {
        let result = PromptFlattener.flatten(.structured([
            "subject": "a cat",
            "extra":   ["high detail", "sharp focus"],
        ]))
        // "extra" shouldn't prefix with "Extra:" when it's an array of strings.
        #expect(!result.contains("Extra:"))
        #expect(result.contains("high detail"))
        #expect(result.contains("sharp focus"))
    }

    @Test func nonPromptKeysAreDropped() {
        let result = PromptFlattener.flatten(.structured([
            "subject": "a cat",
            "seed":    42,
            "steps":   30,
            "sampler": "DPM++",
        ]))
        #expect(result.contains("Subject: a cat"))
        #expect(!result.contains("42"))
        #expect(!result.contains("30"))
        #expect(!result.contains("DPM++"))
    }

    @Test func emptyStringsAndWhitespaceAreOmitted() {
        let result = PromptFlattener.flatten(.structured([
            "subject": "a cat",
            "mood":    "   ",
            "style":   "",
        ]))
        #expect(result.contains("Subject: a cat"))
        #expect(!result.contains("Mood:"))
        #expect(!result.contains("Style:"))
    }

    @Test func arbitraryKeysGetTitleCasedLabels() {
        let result = PromptFlattener.flatten(.structured([
            "art_style":        "watercolor",
            "reference_source": "Studio Ghibli",
        ]))
        #expect(result.contains("Art style: watercolor"))
        #expect(result.contains("Reference source: Studio Ghibli"))
    }

    @Test func unknownKeysAppearAfterCanonicalOnes() {
        let result = PromptFlattener.flatten(.structured([
            "vibe":    "moody",
            "subject": "a cat",
        ]))
        let subjIdx = result.range(of: "Subject")!.lowerBound
        let vibeIdx = result.range(of: "Vibe")!.lowerBound
        #expect(subjIdx < vibeIdx)
    }
}
