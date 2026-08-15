#if os(macOS)
import Foundation
import Network
import ImageAssetManagerCore

actor MCPServer {
    static let port: UInt16 = 47821

    private var listener: NWListener?
    private var authToken: String = ""
    let database: AppDatabase
    let libraryURL: URL

    /// Requests larger than this are rejected outright (413) before buffering.
    private static let maxBodyBytes = 50_000_000

    init(database: AppDatabase, libraryURL: URL) {
        self.database = database
        self.libraryURL = libraryURL
    }

    /// Where the bearer token lives. App Support, NOT the library folder — the
    /// library syncs to iCloud and the token must never leave this Mac.
    static func tokenFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ImageAssetManager")
            .appending(path: "mcp-token")
    }

    /// Mint a fresh random token on every server start and write it 0600 for
    /// the Node proxy to pick up. Loopback alone is not an auth boundary: any
    /// local process — or a web page POSTing text/plain, which needs no CORS
    /// preflight — can reach this port. The token is what makes /tool private.
    private func prepareAuthToken() {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        authToken = bytes.map { String(format: "%02x", $0) }.joined()
        let url = MCPServer.tokenFileURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(authToken.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            print("[MCPServer] Failed to write mcp-token: \(error)")
        }
    }

    func start() {
        prepareAuthToken()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .init("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: MCPServer.port)!
        )
        let lsn: NWListener
        do {
            lsn = try NWListener(using: params)
        } catch {
            print("[MCPServer] Failed to create listener on port \(MCPServer.port): \(error)")
            return
        }
        lsn.stateUpdateHandler = { state in
            switch state {
            case .ready:   print("[MCPServer] Listening on localhost:\(MCPServer.port)")
            case .failed(let e): print("[MCPServer] Listener failed: \(e)")
            default: break
            }
        }
        lsn.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .utility))
            Task { await self?.handle(conn) }
        }
        lsn.start(queue: .global(qos: .utility))
        listener = lsn
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) async {
        do {
            let (method, path, headers, body) = try await readRequest(conn)
            if method == "GET", path == "/health" {
                await send(Data(#"{"status":"ok"}"#.utf8), to: conn)
            } else if method == "POST", path == "/tool" {
                if let rejection = gate(headers: headers) {
                    await send(rejection.body, status: rejection.status, to: conn)
                } else {
                    await send(await dispatchTool(body: body), to: conn)
                }
            } else {
                await send(encodeError("Not found: \(method) \(path)"), status: 404, to: conn)
            }
        } catch {
            await send(encodeError(error.localizedDescription), status: 500, to: conn)
        }
        conn.cancel()
    }

    /// Auth + origin gates for /tool. Returns nil when the request may proceed.
    private func gate(headers: [String: String]) -> (status: Int, body: Data)? {
        // Bearer token — the actual auth boundary (see prepareAuthToken).
        let supplied = (headers["authorization"] ?? "")
            .replacingOccurrences(of: "Bearer ", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !authToken.isEmpty, constantTimeEquals(supplied, authToken) else {
            return (401, encodeError("unauthorized"))
        }
        // Host allowlist — DNS-rebinding defence.
        let host = headers["host"] ?? ""
        guard host == "127.0.0.1:\(MCPServer.port)" || host == "localhost:\(MCPServer.port)" else {
            return (403, encodeError("forbidden: bad Host header"))
        }
        // Content-Type must be JSON — a text/plain POST is the no-preflight
        // browser drive-by shape; a legitimate caller never sends it.
        let contentType = (headers["content-type"] ?? "").lowercased()
        guard contentType.hasPrefix("application/json") else {
            return (415, encodeError("Content-Type must be application/json"))
        }
        return nil
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    private func readRequest(_ conn: NWConnection) async throws -> (String, String, [String: String], Data) {
        var buffer = Data()
        let sep = Data("\r\n\r\n".utf8)

        while buffer.range(of: sep) == nil {
            let chunk = try await chunk(from: conn, min: 1, max: 8192)
            if chunk.isEmpty { throw CocoaError(.fileReadUnknown) }
            buffer.append(chunk)
        }

        guard let sepRange = buffer.range(of: sep) else {
            throw CocoaError(.fileReadUnknown)
        }

        let headerStr = String(decoding: buffer[..<sepRange.lowerBound], as: UTF8.self)
        let lines = headerStr.components(separatedBy: "\r\n")
        let reqParts = lines[0].components(separatedBy: " ")
        let method = reqParts.count > 0 ? reqParts[0] : "GET"
        let path   = reqParts.count > 1 ? reqParts[1] : "/"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        guard contentLength <= MCPServer.maxBodyBytes else {
            throw MCPToolError.requestTooLarge(contentLength)
        }

        var body = Data(buffer[sepRange.upperBound...])
        while body.count < contentLength {
            let needed = contentLength - body.count
            let extra = try await chunk(from: conn, min: 1, max: needed)
            if extra.isEmpty { break }
            body.append(extra)
        }

        return (method, path, headers, body.prefix(contentLength))
    }

    private func chunk(from conn: NWConnection, min: Int, max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: min, maximumLength: max) { data, _, _, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: data ?? Data()) }
            }
        }
    }

    private func send(_ json: Data, status: Int = 200, to conn: NWConnection) async {
        let reasons: [Int: String] = [200: "OK", 401: "Unauthorized", 403: "Forbidden",
                                      404: "Not Found", 413: "Payload Too Large",
                                      415: "Unsupported Media Type", 500: "Internal Server Error"]
        let header = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(json)
        await withCheckedContinuation { cont in
            conn.send(content: response, completion: .contentProcessed { _ in cont.resume() })
        }
    }

    // MARK: - Tool dispatch

    private func dispatchTool(body: Data) async -> Data {
        guard
            let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let name = obj["name"] as? String
        else { return encodeError("Request must be JSON object with 'name' field") }

        let args = (obj["arguments"] as? [String: Any]) ?? [:]
        do {
            let result = try await callTool(name: name, args: args)
            guard let responseData = try? JSONSerialization.data(withJSONObject: ["result": result]) else {
                return encodeError("Failed to serialize result for tool '\(name)'")
            }
            return responseData
        } catch {
            return encodeError(error.localizedDescription)
        }
    }

    private func callTool(name: String, args: [String: Any]) async throws -> Any {
        switch name {
        case "search_assets":
            let results = try await database.mcpSearchAssets(
                query: args["query"] as? String,
                tags: args["tags"] as? [String],
                project: args["project"] as? String,
                projects: args["projects"] as? [String],
                provider: args["provider"] as? String,
                aspectRatio: args["aspect_ratio"] as? String,
                dateFrom: args["date_from"] as? String,
                dateTo: args["date_to"] as? String,
                limit: args["limit"] as? Int ?? 50,
                libraryURL: libraryURL
            )
            return try encode(results)

        case "get_asset":
            let id = try require(args["id"], name: "id")
            guard let detail = try await database.mcpGetAssetDetail(id: id, libraryURL: libraryURL) else {
                throw MCPToolError.notFound("asset '\(id)'")
            }
            return try encode(detail)

        case "get_asset_lineage":
            let id = try require(args["id"], name: "id")
            let lineage = try await database.mcpGetAssetLineage(id: id, libraryURL: libraryURL)
            return try encode(lineage)

        case "list_projects":
            return try encode(try await database.fetchProjects())

        case "search_prompts":
            let prompts = try await database.searchPrompts(
                text: args["query"] as? String,
                sector: args["sector"] as? String
            )
            return try encode(prompts)

        case "get_prompt":
            let id = try require(args["id"], name: "id")
            guard let detail = try await database.mcpGetPrompt(id: id, libraryURL: libraryURL) else {
                throw MCPToolError.notFound("prompt '\(id)'")
            }
            return try encode(detail)

        case "get_spend":
            let summary = try await database.mcpGetSpend(
                project: args["project"] as? String,
                dateFrom: args["date_from"] as? String,
                dateTo: args["date_to"] as? String
            )
            return try encode(summary)

        case "mark_asset_used":
            let id = try require(args["id"], name: "id")
            let usedIn = (args["used_in"] as? String) ?? "claude_code"
            try await database.mcpMarkAssetUsed(assetID: id, usedIn: usedIn)
            try? await IndexExporter.export(
                from: database,
                to: libraryURL.appending(path: "index.json"),
                assetsBaseURL: libraryURL.appending(path: "assets")
            )
            return ["success": true, "assetID": id] as [String: Any]

        case "upload_asset":
            let id = try require(args["id"], name: "id")
            let uploadURL = try require(args["upload_url"], name: "upload_url")
            guard let detail = try await database.mcpGetAssetDetail(id: id, libraryURL: libraryURL) else {
                throw MCPToolError.notFound("asset '\(id)'")
            }
            // The app reads its own container and PUTs the bytes itself — they never travel back
            // through the proxy, and therefore never through the calling model's context.
            let receipt = try await AssetUploader().upload(
                fileAt: URL(filePath: detail.asset.filePath),
                to: uploadURL
            )
            return [
                "success": true,
                "assetID": id,
                "filename": detail.asset.filename,
                "bytes": receipt.bytes,
                "contentType": receipt.contentType,
                "status": receipt.status,
                "host": receipt.host,
            ] as [String: Any]

        case "generate_image":
            return try await handleGenerateImage(args: args)

        default:
            throw MCPToolError.unknownTool(name)
        }
    }

    // MARK: - Helpers

    private func require(_ value: Any?, name: String) throws -> String {
        guard let s = value as? String else { throw MCPToolError.missingParam(name) }
        return s
    }

    private func encode<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func encodeError(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
    }
}

private enum MCPToolError: Error, LocalizedError {
    case missingParam(String)
    case notFound(String)
    case unknownTool(String)
    case requestTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .missingParam(let p): return "Missing required parameter: \(p)"
        case .notFound(let what):  return "Not found: \(what)"
        case .unknownTool(let n):  return "Unknown tool: \(n)"
        case .requestTooLarge(let n): return "Request body too large: \(n) bytes"
        }
    }
}
#endif
