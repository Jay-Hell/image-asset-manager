import Foundation

// Uploads one library asset's bytes to a URL the caller supplies — the app-side half of the
// Deliverable Orchestration mint → upload → finalise flow.
//
// WHY THE APP DOES THIS AND NOT THE MCP PROXY. The Node proxy runs as a child of whatever launched
// it (Claude Code, typically), so reading files out of the iCloud container puts it behind macOS
// TCC and it is refused at open(). The app reaches its own ubiquity container by entitlement and is
// never prompted. The app is also the only party that knows the live library location — the proxy's
// LIBRARY_PATH is an offline fallback and can be stale.
//
// WHY THE URL IS SUPPLIED RATHER THAN BUILT. The portal mints a short-lived, single-object upload
// target and hands it over; that indirection is what lets the destination move from a Worker route
// to a presigned R2 URL without the app changing. The cost is that the caller — ultimately a model —
// chooses where bytes go, which is exactly why `validate` exists below.

public enum AssetUploadError: Error, Equatable, LocalizedError {
    case malformedURL(String)
    case schemeNotHTTPS(String)
    case credentialsInURL
    case portNotAllowed(Int)
    case hostNotAllowed(String)
    case fileUnreadable(path: String)
    case tooLarge(bytes: Int, maxBytes: Int)
    case refused(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .malformedURL(let raw):
            return "upload_url is not a valid URL: \(raw)"
        case .schemeNotHTTPS(let scheme):
            return "upload_url must use https, got '\(scheme)'"
        case .credentialsInURL:
            return "upload_url must not carry a username or password"
        case .portNotAllowed(let port):
            return "upload_url must use the default HTTPS port, got \(port)"
        case .hostNotAllowed(let host):
            return "upload_url host '\(host)' is not an allowed upload destination"
        case .fileUnreadable(let path):
            return "Asset file could not be read at \(path)"
        case .tooLarge(let bytes, let maxBytes):
            return "Asset is \(bytes) bytes, over the \(maxBytes) byte upload limit"
        case .refused(let status, let body):
            return "Upload destination returned HTTP \(status): \(body)"
        }
    }
}

public struct AssetUploadReceipt: Codable, Sendable, Equatable {
    public let bytes: Int
    public let status: Int
    public let contentType: String
    public let host: String

    public init(bytes: Int, status: Int, contentType: String, host: String) {
        self.bytes = bytes
        self.status = status
        self.contentType = contentType
        self.host = host
    }
}

/// Seam for tests — the real implementation is one `URLSession.upload` call.
public protocol AssetUploadTransport: Sendable {
    func send(_ request: URLRequest, body: Data) async throws -> (status: Int, body: String)
}

public struct URLSessionAssetUploadTransport: AssetUploadTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest, body: Data) async throws -> (status: Int, body: String) {
        let (data, response) = try await session.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Only enough of the body to make a failure legible in the tool result — never the whole
        // response, which for a rejected upload can be a full HTML error page.
        return (status, String(decoding: data.prefix(2048), as: UTF8.self))
    }
}

public struct AssetUploader: Sendable {
    /// Mirrors the portal's own MAX_ASSET_BYTES, so the app refuses locally what the far end would
    /// refuse anyway — and refuses it before spending the upload.
    public static let maxBytes = 10 * 1024 * 1024

    /// Exact hosts permitted as upload destinations.
    public static let allowedHosts: Set<String> = ["portal.ionicconsulting.co.uk"]

    /// Permitted host suffixes. The leading dot is load-bearing: it forces a label boundary, so
    /// `abc123.r2.cloudflarestorage.com` matches and `notr2.cloudflarestorage.com` does not. This
    /// entry is what the presigned-R2 destination will use once the portal swaps to it.
    public static let allowedHostSuffixes: [String] = [".r2.cloudflarestorage.com"]

    /// Generous — a multi-megabyte asset on a poor connection is the normal case, not the edge.
    public static let timeout: TimeInterval = 120

    private let transport: AssetUploadTransport

    public init(transport: AssetUploadTransport = URLSessionAssetUploadTransport()) {
        self.transport = transport
    }

    /// The guard on an attacker-influenced destination.
    ///
    /// This tool reads a file the user owns and PUTs it wherever it is told, and the "told" comes
    /// from a model that may have just read untrusted text. Without an allowlist that is an
    /// exfiltration primitive with a friendly tool description. Everything here fails closed.
    public static func validate(_ raw: String) throws -> URL {
        guard let components = URLComponents(string: raw),
              let url = components.url,
              let host = components.host?.lowercased(),
              !host.isEmpty
        else { throw AssetUploadError.malformedURL(raw) }

        let scheme = components.scheme?.lowercased() ?? ""
        guard scheme == "https" else { throw AssetUploadError.schemeNotHTTPS(scheme) }

        // https://portal.ionicconsulting.co.uk@evil.example/ parses with host "evil.example" — the
        // allowlist below already catches it, but a credential in an upload URL is never legitimate
        // here and a clear error beats a confusing one.
        guard components.user == nil, components.password == nil else {
            throw AssetUploadError.credentialsInURL
        }

        if let port = components.port, port != 443 {
            throw AssetUploadError.portNotAllowed(port)
        }

        let allowed = allowedHosts.contains(host)
            || allowedHostSuffixes.contains { host.hasSuffix($0) }
        guard allowed else { throw AssetUploadError.hostNotAllowed(host) }

        return url
    }

    /// Advisory only — the portal sniffs the real type from the bytes and stamps that. Sent so the
    /// object carries something sane if it is ever fetched straight from storage.
    public static func contentType(forFilename name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return typesByExtension[ext] ?? "application/octet-stream"
    }

    private static let typesByExtension: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "svg": "image/svg+xml",
    ]

    public func upload(fileAt fileURL: URL, to raw: String) async throws -> AssetUploadReceipt {
        // Destination first: never read a file for a target we would refuse.
        let url = try Self.validate(raw)

        guard let data = try? Data(contentsOf: fileURL) else {
            throw AssetUploadError.fileUnreadable(path: fileURL.path(percentEncoded: false))
        }
        guard data.count <= Self.maxBytes else {
            throw AssetUploadError.tooLarge(bytes: data.count, maxBytes: Self.maxBytes)
        }

        let contentType = Self.contentType(forFilename: fileURL.lastPathComponent)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = Self.timeout
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let (status, body) = try await transport.send(request, body: data)
        guard (200...299).contains(status) else {
            throw AssetUploadError.refused(status: status, body: body)
        }

        return AssetUploadReceipt(
            bytes: data.count,
            status: status,
            contentType: contentType,
            host: url.host() ?? ""
        )
    }
}
