import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The network boundary. Tests replace it with a stub; the app uses `URLSessionTransport`.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// - Parameter requestTimeout: max idle time between bytes. Opus at high effort can think for minutes.
    public init(requestTimeout: TimeInterval = 300, resourceTimeout: TimeInterval = 600) {
        let config = URLSessionConfiguration.ephemeral // no cookies, no disk cache of API responses
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        #if canImport(Darwin)
        config.waitsForConnectivity = false // fail fast offline instead of hanging
        #endif
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ShadeError(.claudeBadResponse, "Unexpected response from the Claude API.", detail: "not an HTTP response")
        }
        return (data, http)
    }
}
