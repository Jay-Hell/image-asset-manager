import Testing
import Foundation
@testable import ImageAssetManagerCore

private actor Recorder {
    private(set) var request: URLRequest?
    private(set) var body: Data?
    private(set) var callCount = 0

    func record(_ request: URLRequest, _ body: Data) {
        self.request = request
        self.body = body
        callCount += 1
    }
}

private struct MockTransport: AssetUploadTransport {
    let recorder: Recorder
    var status: Int = 200
    var responseBody: String = #"{"ok":true}"#

    func send(_ request: URLRequest, body: Data) async throws -> (status: Int, body: String) {
        await recorder.record(request, body)
        return (status, responseBody)
    }
}

private func makeTempFile(named name: String, bytes: Data) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "asset-uploader-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: name)
    try bytes.write(to: url)
    return url
}

private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])

@Suite("AssetUploader — destination validation")
struct AssetUploaderValidationTests {

    @Test("accepts the portal host over https")
    func acceptsPortalHost() throws {
        let url = try AssetUploader.validate("https://portal.ionicconsulting.co.uk/artefact-asset/abc.def")
        #expect(url.host() == "portal.ionicconsulting.co.uk")
    }

    @Test("accepts a presigned R2 host")
    func acceptsR2Host() throws {
        let url = try AssetUploader.validate(
            "https://56842702d8e1e7af63c95373e0cd6d57.r2.cloudflarestorage.com/bucket/key?X-Amz-Expires=900"
        )
        #expect(url.host()?.hasSuffix(".r2.cloudflarestorage.com") == true)
    }

    @Test("host match is case-insensitive")
    func hostCaseInsensitive() throws {
        let url = try AssetUploader.validate("https://Portal.IonicConsulting.co.UK/x")
        #expect(url.absoluteString.isEmpty == false)
    }

    @Test("rejects plain http")
    func rejectsHTTP() {
        #expect(throws: AssetUploadError.schemeNotHTTPS("http")) {
            try AssetUploader.validate("http://portal.ionicconsulting.co.uk/x")
        }
    }

    @Test("rejects an unrelated host")
    func rejectsUnknownHost() {
        #expect(throws: AssetUploadError.hostNotAllowed("evil.example")) {
            try AssetUploader.validate("https://evil.example/x")
        }
    }

    // The leading dot in the suffix is what makes this fail. Without it, `hasSuffix` would match
    // any host merely ending in the string.
    @Test("rejects a host that only looks like an R2 endpoint")
    func rejectsLookalikeR2Host() {
        #expect(throws: AssetUploadError.hostNotAllowed("notr2.cloudflarestorage.com")) {
            try AssetUploader.validate("https://notr2.cloudflarestorage.com/bucket/key")
        }
    }

    @Test("rejects the allowed host used as a subdomain of an attacker domain")
    func rejectsSuffixedImposter() {
        #expect(throws: AssetUploadError.hostNotAllowed("portal.ionicconsulting.co.uk.evil.example")) {
            try AssetUploader.validate("https://portal.ionicconsulting.co.uk.evil.example/x")
        }
    }

    @Test("rejects credentials smuggled into the authority")
    func rejectsCredentials() {
        #expect(throws: AssetUploadError.credentialsInURL) {
            try AssetUploader.validate("https://portal.ionicconsulting.co.uk@evil.example/x")
        }
    }

    @Test("rejects a non-default port")
    func rejectsOddPort() {
        #expect(throws: AssetUploadError.portNotAllowed(8080)) {
            try AssetUploader.validate("https://portal.ionicconsulting.co.uk:8080/x")
        }
    }

    @Test("rejects a malformed URL")
    func rejectsMalformed() {
        #expect(throws: AssetUploadError.malformedURL("not a url")) {
            try AssetUploader.validate("not a url")
        }
    }
}

@Suite("AssetUploader — content type")
struct AssetUploaderContentTypeTests {

    @Test("maps known image extensions", arguments: [
        ("logo.png", "image/png"),
        ("photo.JPG", "image/jpeg"),
        ("photo.jpeg", "image/jpeg"),
        ("loop.gif", "image/gif"),
        ("shot.webp", "image/webp"),
        ("mark.svg", "image/svg+xml"),
    ])
    func mapsKnownExtensions(name: String, expected: String) {
        #expect(AssetUploader.contentType(forFilename: name) == expected)
    }

    @Test("falls back for anything unrecognised")
    func fallsBack() {
        #expect(AssetUploader.contentType(forFilename: "notes.txt") == "application/octet-stream")
        #expect(AssetUploader.contentType(forFilename: "noextension") == "application/octet-stream")
    }
}

@Suite("AssetUploader — upload")
struct AssetUploaderUploadTests {

    @Test("sends a PUT carrying the file's bytes and returns a receipt")
    func happyPath() async throws {
        let file = try makeTempFile(named: "brand.png", bytes: pngBytes)
        let recorder = Recorder()
        let uploader = AssetUploader(transport: MockTransport(recorder: recorder))

        let receipt = try await uploader.upload(
            fileAt: file,
            to: "https://portal.ionicconsulting.co.uk/artefact-asset/tok.en"
        )

        #expect(receipt.bytes == pngBytes.count)
        #expect(receipt.status == 200)
        #expect(receipt.contentType == "image/png")
        #expect(receipt.host == "portal.ionicconsulting.co.uk")

        let request = await recorder.request
        #expect(request?.httpMethod == "PUT")
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(await recorder.body == pngBytes)
    }

    // Ordering matters: a refused destination must not cause the file to be read at all. The file
    // here does not exist, so if validation ran second this would surface as .fileUnreadable.
    @Test("refuses a disallowed destination before touching the file")
    func validatesBeforeReading() async {
        let recorder = Recorder()
        let uploader = AssetUploader(transport: MockTransport(recorder: recorder))
        let missing = URL(filePath: "/nonexistent/never-read.png")

        await #expect(throws: AssetUploadError.hostNotAllowed("evil.example")) {
            try await uploader.upload(fileAt: missing, to: "https://evil.example/x")
        }
        #expect(await recorder.callCount == 0)
    }

    @Test("reports an unreadable file")
    func missingFile() async {
        let recorder = Recorder()
        let uploader = AssetUploader(transport: MockTransport(recorder: recorder))
        let missing = URL(filePath: "/nonexistent/missing.png")

        await #expect(throws: AssetUploadError.fileUnreadable(path: "/nonexistent/missing.png")) {
            try await uploader.upload(fileAt: missing, to: "https://portal.ionicconsulting.co.uk/x")
        }
        #expect(await recorder.callCount == 0)
    }

    @Test("refuses an asset over the size cap without uploading it")
    func tooLarge() async throws {
        let oversize = Data(repeating: 0x41, count: AssetUploader.maxBytes + 1)
        let file = try makeTempFile(named: "huge.png", bytes: oversize)
        let recorder = Recorder()
        let uploader = AssetUploader(transport: MockTransport(recorder: recorder))

        await #expect(throws: AssetUploadError.tooLarge(
            bytes: AssetUploader.maxBytes + 1,
            maxBytes: AssetUploader.maxBytes
        )) {
            try await uploader.upload(fileAt: file, to: "https://portal.ionicconsulting.co.uk/x")
        }
        #expect(await recorder.callCount == 0)
    }

    @Test("surfaces a non-2xx from the destination")
    func refusedByDestination() async throws {
        let file = try makeTempFile(named: "brand.png", bytes: pngBytes)
        let recorder = Recorder()
        let transport = MockTransport(recorder: recorder, status: 404, responseBody: #"{"error":"invalid_ticket"}"#)
        let uploader = AssetUploader(transport: transport)

        await #expect(throws: AssetUploadError.refused(status: 404, body: #"{"error":"invalid_ticket"}"#)) {
            try await uploader.upload(fileAt: file, to: "https://portal.ionicconsulting.co.uk/artefact-asset/bad")
        }
    }

    @Test("accepts any 2xx, not just 200")
    func accepts204() async throws {
        let file = try makeTempFile(named: "brand.png", bytes: pngBytes)
        let recorder = Recorder()
        let uploader = AssetUploader(transport: MockTransport(recorder: recorder, status: 204, responseBody: ""))

        let receipt = try await uploader.upload(
            fileAt: file,
            to: "https://portal.ionicconsulting.co.uk/artefact-asset/tok.en"
        )
        #expect(receipt.status == 204)
    }
}
