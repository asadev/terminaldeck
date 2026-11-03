import Foundation
import TerminalDeckNativeCore

/// Ephemeral, bounded HTTP. Redirects are returned to the service rather than
/// followed, so an authenticated request can never forward its token elsewhere.
public struct BackendGHHTTP: BackendGitHubHTTPFetching {
    public init() {}
    public func fetch(url: String, method: String, headers: [String: String], body: String?, timeoutMilliseconds: Int) async throws -> BackendGitHubHTTPResponse {
        guard let url = URL(string: url), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host, !host.isEmpty else {
            throw NativeRPCError.invalidArguments("GitHub requests need a secure web address.")
        }
        let timeout = Double(max(1_000, min(timeoutMilliseconds, 60_000))) / 1000
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: BackendGHNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method; request.allHTTPHeaderFields = headers; request.httpBody = body.map { Data($0.utf8) }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw NativeRPCError(code: "network-down", message: "GitHub returned no web response.") }
        let maximum = headers["Accept"] == "text/plain" ? BackendGHAPIValidation.maximumLogBytes : BackendGHAPIValidation.maximumJSONBytes
        if response.expectedContentLength > Int64(maximum) { throw NativeRPCError(code: "response-too-large", message: "GitHub returned more data than this view can show. Open a smaller page or job.") }
        var data = Data(); data.reserveCapacity(min(maximum, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximum else { throw NativeRPCError(code: "response-too-large", message: "GitHub returned more data than this view can show. Open a smaller page or job.") }
            data.append(byte)
        }
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { $0[String(describing: $1.key).lowercased()] = String(describing: $1.value) }
        return .init(status: response.statusCode, body: String(decoding: data, as: UTF8.self), headers: fields)
    }
}
private final class BackendGHNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
