#if os(macOS)
import Foundation
import ImageAssetManagerCore

/// Transport for the generation tools. What `generate`, `generate_image` and `list_generation_options`
/// do lives in Core (`GenerateTools`), where the tests drive it; this file only hands the request
/// over and the JSON back, and supplies what only the app knows (the Keychain, the ceiling setting).
extension MCPServer {

    func handleGenerationTool(name: String, args: [String: Any]) async throws -> Any {
        let tools = GenerateTools(
            database: database,
            libraryURL: libraryURL,
            catalogue: { CatalogueStore.shared.snapshot() },
            live: .shared,
            providers: { GenerateTools.keychainProviders() },
            ceiling: { MCPServer.budgetCeiling() }
        )
        let body = try JSONSerialization.data(withJSONObject: args)
        let result = try await tools.call(name, arguments: body)
        return try JSONSerialization.jsonObject(with: result)
    }

    // MARK: - Budget ceiling

    /// The app-held hard ceiling for one MCP generate call. Overridable via
    /// `defaults write` (mcpMaxImagesPerCall / mcpMaxCostPerCallGBP) until a
    /// Settings surface ships; absent overrides use GenerationPolicy defaults
    /// (50 images / £5.00).
    static func budgetCeiling(defaults: UserDefaults = .standard) -> GenerationPolicy.BudgetLimits {
        let images = defaults.object(forKey: "mcpMaxImagesPerCall") as? Int
        let cost = defaults.object(forKey: "mcpMaxCostPerCallGBP") as? Double
        return GenerationPolicy.BudgetLimits(
            maxImages: images ?? GenerationPolicy.mcpCeilingDefaults.maxImages,
            maxCostGBP: cost.map { Decimal($0) } ?? GenerationPolicy.mcpCeilingDefaults.maxCostGBP
        )
    }
}
#endif
