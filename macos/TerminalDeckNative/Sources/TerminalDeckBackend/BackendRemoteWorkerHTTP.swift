import Foundation
import TerminalDeckNativeCore

public struct BackendRemoteWorkerResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public enum BackendRemoteWorkerTransportFailure: Error, Equatable, Sendable {
    case timeout, unreachable, tooLarge, secureConnection
}

public protocol BackendRemoteWorkerTransport: Sendable {
    func send(method: String, url: URL, headers: [String: String], body: Data?, timeoutMilliseconds: Int) async throws -> BackendRemoteWorkerResponse
}

/// Ephemeral, bounded HTTP. Redirects are returned as 3xx answers and never followed
/// (so a bearer token can never be forwarded to another place); TLS is never relaxed.
public struct BackendRemoteWorkerURLSession: BackendRemoteWorkerTransport {
    public static let maximumResponseBytes = 256 * 1024
    private let protocolClasses: [AnyClass]?
    public init(protocolClasses: [AnyClass]? = nil) { self.protocolClasses = protocolClasses }

    public func send(method: String, url: URL, headers: [String: String], body: Data?, timeoutMilliseconds: Int) async throws -> BackendRemoteWorkerResponse {
        guard url.scheme == "https" || (url.scheme == "http" && url.host.map(RemoteWorkerContract.isLoopback) == true), url.user == nil, url.password == nil else {
            throw BackendRemoteWorkerTransportFailure.secureConnection
        }
        let timeout = Double(max(1_000, min(timeoutMilliseconds, 60_000))) / 1000
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let session = URLSession(configuration: configuration, delegate: BackendRemoteWorkerNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method; request.allHTTPHeaderFields = headers; request.httpBody = body
        request.httpShouldHandleCookies = false
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw BackendRemoteWorkerTransportFailure.unreachable }
            if response.expectedContentLength > Int64(Self.maximumResponseBytes) { throw BackendRemoteWorkerTransportFailure.tooLarge }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumResponseBytes else { throw BackendRemoteWorkerTransportFailure.tooLarge }
                data.append(byte)
            }
            return .init(status: response.statusCode, body: data)
        } catch let failure as BackendRemoteWorkerTransportFailure { throw failure }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            switch error.code {
            case .timedOut: throw BackendRemoteWorkerTransportFailure.timeout
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected, .appTransportSecurityRequiresSecureConnection:
                throw BackendRemoteWorkerTransportFailure.secureConnection
            case .cancelled: throw CancellationError()
            default: throw BackendRemoteWorkerTransportFailure.unreachable
            }
        } catch { throw BackendRemoteWorkerTransportFailure.unreachable }
    }
}

final class BackendRemoteWorkerNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
