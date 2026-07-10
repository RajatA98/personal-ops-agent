import Foundation
@testable import Integrations

/// A `URLProtocol` that intercepts every request on a session and answers it from a
/// test-controlled handler — the "mocked transport" the Phase 2 acceptance criteria require.
/// Requests are recorded (URL, method, decoded JSON body) so tests can assert exact request
/// bodies (e.g. that a retried create reuses the same event ID).
final class MockURLProtocol: URLProtocol {

    struct Recorded {
        let url: URL
        let method: String
        let body: Data?

        var json: [String: Any]? {
            guard let body else { return nil }
            return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }

        var bodyString: String? { body.flatMap { String(data: $0, encoding: .utf8) } }
    }

    /// Serial, process-wide handler (SwiftPM XCTest runs test methods serially).
    nonisolated(unsafe) static var handler: ((Recorded) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private(set) static var requests: [Recorded] = []
    static let lock = NSLock()

    static func reset() {
        lock.withLock {
            handler = nil
            requests = []
        }
    }

    static func recorded() -> [Recorded] { lock.withLock { requests } }

    /// Build a `URLSession` wired to this protocol.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Build an `HTTPTransport` over the mocked session.
    static func transport() -> HTTPTransport { URLSessionTransport(session: session()) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Recorded(
            url: request.url!,
            method: request.httpMethod ?? "GET",
            body: Self.bodyData(from: request))
        Self.lock.withLock { Self.requests.append(recorded) }

        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(recorded)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// `URLProtocol` moves `httpBody` into `httpBodyStream`; read whichever is present.
    static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Convenience for building responses in handlers.
extension HTTPURLResponse {
    static func make(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
    }
}
