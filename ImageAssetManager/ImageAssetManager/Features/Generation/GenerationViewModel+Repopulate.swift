import Foundation
import ImageAssetManagerCore

extension GenerationViewModel {
    func prePopulate(from prompt: Prompt) {
        promptText = prompt.body
        let neg = prompt.negativePrompt ?? ""
        negativePromptText = neg
        showNegativePrompt = !neg.isEmpty
    }

    func prePopulate(from asset: Asset) {
        if let pid = asset.projectID {
            selectedProjectID = pid
        }
        if let prompt = asset.prompt {
            promptText = prompt
        }
        if let neg = asset.negativePrompt, !neg.isEmpty {
            negativePromptText = neg
            showNegativePrompt = true
        }
        if asset.providerID != "imported" {
            selectedProviderID = asset.providerID
            selectedModelID = asset.modelID
        }
        if let ratioStr = asset.aspectRatio, let ar = AspectRatio(rawValue: ratioStr) {
            aspectRatio = ar
        } else if let w = asset.width, let h = asset.height {
            aspectRatio = .custom
            customWidth = w
            customHeight = h
        }
    }
}
