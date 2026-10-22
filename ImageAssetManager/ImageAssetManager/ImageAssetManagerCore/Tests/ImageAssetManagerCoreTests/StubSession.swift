import Foundation

/// What left the process: the request as the network layer saw it.
struct SentRequest: @unchecked Sendable {
    let url: URL
    let method: String
    let headers: [String: String]   // lower-cased names
    let body: Data

    var bodyJSON: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

/// A URLSession whose every request is answered by a closure and recorded. State is
/// keyed by a per-session token header, so tests in different suites can run in
/// parallel without sharing a handler.
final class StubSession: @unchecked Sendable {
    typealias Handler = @Sendable (SentRequest) throws -> (Int, Data, [String: String])

    static let tokenHeader = "X-Stub-Token"

    private let id = UUID().uuidString
    let session: URLSession

    init(_ handler: @escaping Handler) {
        StubProtocol.register(id: id, handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        config.httpAdditionalHeaders = [Self.tokenHeader: id]
        session = URLSession(configuration: config)
    }

    convenience init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
        self.init { _ in (status, body, headers) }
    }

    var requests: [SentRequest] { StubProtocol.requests(id: id) }

    deinit { StubProtocol.unregister(id: id) }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: StubSession.Handler] = [:]
    nonisolated(unsafe) private static var log: [String: [SentRequest]] = [:]

    static func register(id: String, handler: @escaping StubSession.Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[id] = handler
        log[id] = []
    }

    static func unregister(id: String) {
        lock.lock(); defer { lock.unlock() }
        handlers[id] = nil
        log[id] = nil
    }

    static func requests(id: String) -> [SentRequest] {
        lock.lock(); defer { lock.unlock() }
        return log[id] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: StubSession.tokenHeader) ?? ""
        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] where k.lowercased() != StubSession.tokenHeader.lowercased() {
            headers[k.lowercased()] = v
        }
        let sent = SentRequest(
            url: request.url!,
            method: request.httpMethod ?? "GET",
            headers: headers,
            body: Self.bodyData(of: request)
        )
        Self.lock.lock()
        let handler = Self.handlers[id]
        Self.log[id, default: []].append(sent)
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (status, data, extra) = try handler(sent)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: extra)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// URLSession hands the body to a protocol as a stream, not `httpBody`.
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
