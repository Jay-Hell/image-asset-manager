import Testing
import Foundation
@testable import ImageAssetManagerCore

@Suite("Test host isolation")
struct TestHostIsolationTests {
    /// Each variable XCTest sets when it launches an app as a test host is enough on its own.
    @Test(arguments: [
        ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"],
        ["XCTestBundlePath": "/tmp/ImageAssetManagerTests.xctest"],
        ["XCTestSessionIdentifier": "6A1B"],
        ["XCInjectBundleInto": "/tmp/ImageAssetManager.app/Contents/MacOS/ImageAssetManager"],
        ["DYLD_INSERT_LIBRARIES": "/Applications/Xcode.app/usr/lib/libXCTestBundleInject.dylib"],
    ])
    func anyXCTestMarkerMeansATestHost(_ environment: [String: String]) {
        #expect(TestHostIsolation.isTestHost(environment: environment))
    }

    /// An ordinary launch, by Finder, Xcode's Run or the command line, is not a test host.
    @Test func anOrdinaryLaunchIsNotATestHost() {
        #expect(!TestHostIsolation.isTestHost(environment: [:]))
        #expect(!TestHostIsolation.isTestHost(environment: [
            "HOME": "/Users/someone", "PATH": "/usr/bin:/bin", "__CFBundleIdentifier": "com.apple.dt.Xcode",
            "DYLD_INSERT_LIBRARIES": "/usr/lib/libgmalloc.dylib",
        ]))
    }

    @Test func theTestLibraryIsNewEmptyAndUnderTheTemporaryDirectory() throws {
        let first = try TestHostIsolation.makeTemporaryLibrary()
        let second = try TestHostIsolation.makeTemporaryLibrary()
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path(percentEncoded: false)

        #expect(TestHostIsolation.isInsideTemporaryDirectory(first))
        #expect(first.resolvingSymlinksInPath().path(percentEncoded: false).hasPrefix(temp))
        #expect(first != second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.path(percentEncoded: false)).isEmpty)
    }

    /// The check the app test relies on must be able to fail.
    @Test func aLibraryOutsideTheTemporaryDirectoryIsCaught() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(!TestHostIsolation.isInsideTemporaryDirectory(
            home.appending(path: "Library/Mobile Documents/iCloud~Ionic~ImageAssetManager/Documents")))
        #expect(!TestHostIsolation.isInsideTemporaryDirectory(URL(filePath: "/tmp-lookalike/library")))
    }
}
