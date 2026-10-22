import Foundation
import ImageAssetManagerCore

extension GenerationViewModel {
    func applyPrompt(_ prompt: Prompt) async {
        promptText = prompt.body
        negativePromptText = prompt.negativePrompt ?? ""
        showNegativePrompt = !(prompt.negativePrompt ?? "").isEmpty

        try? await database.incrementPromptUsage(promptID: prompt.id)
        allPrompts = (try? await database.fetchPrompts()) ?? []
    }
}
