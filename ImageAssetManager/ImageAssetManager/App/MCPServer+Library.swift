#if os(macOS)
import Foundation
import ImageAssetManagerCore

/// Transport for the library tools (`create_client`, `create_project`, `list_projects`,
/// `file_assets`, `import_asset`, `list_tags`). What they do lives in Core (`LibraryTools`), where
/// the tests drive it; this file only hands the request over and the JSON back.
extension MCPServer {

    func handleLibraryTool(name: String, args: [String: Any]) async throws -> Any {
        let tools = LibraryTools(database: database, libraryURL: libraryURL)
        let body = try JSONSerialization.data(withJSONObject: args)
        let result = try await tools.call(name, arguments: body)
        return try JSONSerialization.jsonObject(with: result)
    }
}
#endif
