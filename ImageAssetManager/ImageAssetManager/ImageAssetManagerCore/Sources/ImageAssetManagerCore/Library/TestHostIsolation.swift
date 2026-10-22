import Foundation

/// Keeps the app's own tests away from the real library. The macOS app tests launch the app as
/// their host, and a host that opened its usual library would open John's live iCloud library —
/// backing it up, migrating it and starting a second MCP listener. Under XCTest the app opens a
/// fresh temporary library instead, and never reads the bookmark, UserDefaults or iCloud.
public enum TestHostIsolation {
    /// Variables XCTest sets when it launches an app as a test host. Any one is enough.
    static let markers = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier", "XCInjectBundleInto"]

    public static func isTestHost(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if markers.contains(where: { environment[$0] != nil }) { return true }
        return environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTestBundleInject") == true
    }

    /// A new, empty folder under the temporary directory, unique to this call.
    public static func makeTemporaryLibrary() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ImageAssetManager-TestHost-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Whether `url` lies inside the temporary directory, symlinks resolved (`/var` is
    /// `/private/var` on macOS) and compared by path component, so `/tmp-lookalike` is outside.
    public static func isInsideTemporaryDirectory(_ url: URL) -> Bool {
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let path = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return path.count > temp.count && Array(path.prefix(temp.count)) == temp
    }
}
