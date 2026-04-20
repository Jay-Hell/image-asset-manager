#if os(macOS)
import Foundation
import Network
import ImageAssetManagerCore

actor MCPServer {
    static let port: UInt16 = 47821

    private var listener: NWListener?
    let database: AppDatabase
    let libraryURL: URL

    init(database: AppDatabase, libraryURL: URL) {
        self.database = database
        self.libraryURL = libraryURL
    }

    func start() {
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
            let (method, path, body) = try await readRequest(conn)
            let responseData: Data
            if method == "GET", path == "/health" {
                responseData = Data(#"{"status":"ok"}"#.utf8)
            } else if method == "POST", path == "/tool" {
                responseData = await dispatchTool(body: body)
            } else {
                responseData = encodeError("Not found: \(method) \(path)")
            }
            await send(responseData, to: conn)
        } catch {
            await send(encodeError(error.localizedDescription), to: conn)
        }
        conn.cancel()
    }

    private func readRequest(_ conn: NWConnection) async throws -> (String, String, Data) {
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

        var contentLength = 0
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        var body = Data(buffer[sepRange.upperBound...])
        while body.count < contentLength {
            let needed = contentLength - body.count
            let extra = try await chunk(from: conn, min: 1, max: needed)
            if extra.isEmpty { break }
            body.append(extra)
        }

        return (method, path, body.prefix(contentLength))
    }

    private func chunk(from conn: NWConnection, min: Int, max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: min, maximumLength: max) { data, _, _, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: data ?? Data()) }
            }
        }
    }

    private func send(_ json: Data, to conn: NWConnection) async {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
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
                collection: args["collection"] as? String,
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

        case "list_collections":
            let cols = try await database.mcpListCollections(projectID: args["project_id"] as? String)
            return try encode(cols)

        case "get_collection":
            let id = try require(args["id"], name: "id")
            guard let detail = try await database.mcpGetCollection(id: id, libraryURL: libraryURL) else {
                throw MCPToolError.notFound("collection '\(id)'")
            }
            return try encode(detail)

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

    var errorDescription: String? {
        switch self {
        case .missingParam(let p): return "Missing required parameter: \(p)"
        case .notFound(let what):  return "Not found: \(what)"
        case .unknownTool(let n):  return "Unknown tool: \(n)"
        }
    }
}
#endif
