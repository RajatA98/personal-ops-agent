import Foundation
import Integrations

/// A `URLProtocol` that intercepts requests on a test session and answers them from a
/// test-controlled handler — the mocked transport the Phase 5 Gemini tests use to exercise the
/// real request-building / response-parsing path without hitting the network. Requests are
/// recorded (URL, method, body) so tests can assert the exact request shape.
final class MockURLProtocol: URLProtocol {

    struct Recorded {
        let url: URL
        let method: String
        let body: Data?

        var json: [String: Any]? {
            guard let body else { return nil }
            return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
    }

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

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func transport() -> HTTPTransport { URLSessionTransport(session: session()) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Recorded(url: request.url!, method: request.httpMethod ?? "GET",
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

extension HTTPURLResponse {
    static func make(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
    }
}
