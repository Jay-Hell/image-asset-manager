import Foundation

public enum LibrarySetup {
    public static func initialise(at containerURL: URL) throws {
        let fm = FileManager.default

        for folder in ["assets", "prompts"] {
            try fm.createDirectory(
                at: containerURL.appending(path: folder),
                withIntermediateDirectories: true
            )
        }

        let indexURL = containerURL.appending(path: "index.json")
        if !fm.fileExists(atPath: indexURL.path(percentEncoded: false)) {
            try Data("[]".utf8).write(to: indexURL, options: .atomic)
        }

        let providersURL = containerURL.appending(path: "providers.json")
        if !fm.fileExists(atPath: providersURL.path(percentEncoded: false)) {
            try Data(initialProvidersJSON.utf8).write(to: providersURL, options: .atomic)
        }
    }

    private static let initialProvidersJSON = """
    {
      "schemaVersion": 1,
      "providers": [
        {
          "id": "nano_banana",
          "displayName": "Nano Banana",
          "supportsReferenceImages": true,
          "maxReferenceImages": 3,
          "supportedRoles": ["style_anchor", "subject_anchor"],
          "costModel": {
            "type": "per_image",
            "ratePerImage": 0.02
          }
        }
      ]
    }
    """
}
