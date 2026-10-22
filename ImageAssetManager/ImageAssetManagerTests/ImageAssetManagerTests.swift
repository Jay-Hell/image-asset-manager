//
//  ImageAssetManagerTests.swift
//  ImageAssetManagerTests
//
//  Created by John Livingston on 17/04/2026.
//

import Testing
import Foundation
import ImageAssetManagerCore
@testable import ImageAssetManager

/// These tests run inside the app as their host. The host must never open the real library:
/// under XCTest `AppEnvironment.make()` opens a fresh library in the temporary directory.
@MainActor
struct ImageAssetManagerTests {

    @Test func theTestHostOpenedATemporaryLibraryNotTheRealOne() throws {
        #expect(AppEnvironment.isTestHost)
        let opened = try #require(AppEnvironment.openedLibraryURL, "the host app did not open a library")
        #expect(TestHostIsolation.isInsideTemporaryDirectory(opened), "host opened \(opened.path(percentEncoded: false))")
        #expect(opened.lastPathComponent.hasPrefix("ImageAssetManager-TestHost-"))
    }
}
