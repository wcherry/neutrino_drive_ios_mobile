import Foundation

/// A `URLProtocol` stub that lets tests intercept `URLSession` traffic without touching the
/// network, so `DriveService`/`UploadService` methods that make real HTTP calls can be
/// exercised end-to-end (including request-body capture) in unit tests.
///
/// Usage:
/// ```swift
/// let session = MockURLProtocol.makeSession()
/// MockURLProtocol.requestHandler = { request in
///     let body = MockURLProtocol.body(for: request)
///     let response = HTTPURLResponse(url: request.url!, statusCode: 200,
///                                    httpVersion: nil, headerFields: nil)!
///     return (response, someJSONData)
/// }
/// let sut = DriveService(session: session)
/// ```
final class MockURLProtocol: URLProtocol {

    /// Set per-test. Receives the outgoing request and returns the response to hand back.
    /// Throwing simulates a network error.
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Captures the body of the most recent request (multipart bodies arrive via
    /// `uploadTask(withStreamedRequest:)`'s `httpBodyStream` when using `URLSession.upload`,
    /// so this is populated from `startLoading` regardless of which entry point was used).
    private(set) static var lastRequestBody: Data?

    static func makeSession() -> URLSession {
        URLSession(configuration: configuration())
    }

    /// `AuthService` takes a configuration rather than a session — it builds two, one of which
    /// suppresses redirects — so the stub has to be installed a level down.
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return config
    }

    static func reset() {
        requestHandler = nil
        lastRequestBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let stream = request.httpBodyStream {
            Self.lastRequestBody = Self.drain(stream)
        } else if let body = request.httpBody {
            Self.lastRequestBody = body
        }

        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
