import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// Finding 28 proof aid, DEBUG BUILDS ONLY (G2): when `TD_CLOUD_TRACE_FILE` names a file in a scratch debug launch,
/// every Cloud account construction, protected-store read and network request appends one line there. A release
/// (shipped) build compiles none of this, and a debug build of the shipped flavour (ShippedHost trait) never reads the
/// variable: `note` does nothing there.
public enum BackendCloudTrace {
    /// The build flavour that ships: release, or debug with the ShippedHost trait; both define TD_HOST_INTEGRATED
    /// (Package.swift `hostReleaseSettings`), a plain debug build does not. The shipped flavour never traces.
    public static let shippedFlavour: Bool = {
        #if TD_HOST_INTEGRATED
        return true
        #else
        return false
        #endif
    }()
    /// The trace file for this environment: an absolute path in a plain debug build, nil in the shipped flavour.
    public static func traceFile(_ environment: [String: String], shipped: Bool = shippedFlavour) -> String? {
        #if DEBUG
        guard !shipped else { return nil }
        return environment[NativeLaunchSwitches.cloudTraceFile].flatMap { $0.hasPrefix("/") ? $0 : nil }
        #else
        return nil
        #endif
    }
    private static let file: String? = traceFile(ProcessInfo.processInfo.environment)
    public static func note(_ event: String) {
        guard let file else { return }
        let line = Data((event + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: file) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: line) }
        else { FileManager.default.createFile(atPath: file, contents: line) }
    }
}

public struct BackendCloudAccountRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data
    public init(url: URL, method: String, headers: [String: String], body: Data) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
    }
}
public struct BackendCloudAccountResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}
public protocol BackendCloudAccountHTTP: Sendable {
    func send(_ request: BackendCloudAccountRequest) async throws -> BackendCloudAccountResponse
}
public final class BackendCloudAccountURLSession: BackendCloudAccountHTTP, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config, delegate: BackendCloudNoRedirect(), delegateQueue: nil)
    }
    public func send(_ input: BackendCloudAccountRequest) async throws -> BackendCloudAccountResponse {
        BackendCloudTrace.note("http " + (input.url.host ?? ""))
        var request = URLRequest(url: input.url)
        request.httpMethod = input.method
        request.httpBody = input.body.isEmpty ? nil : input.body
        input.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 409_600,
              response.url?.host == input.url.host else { throw CloudFailure.invalidRequest }
        return .init(status: response.statusCode, body: data)
    }
}

/// Existing scoped Keychain owner, not a new encryption format or a file fallback.
public struct BackendCloudAccountProtectedStore: Sendable {
    public let read: @Sendable () throws -> String?
    public let write: @Sendable (String) throws -> Void
    public let remove: @Sendable () throws -> Void
    public init(read: @escaping @Sendable () throws -> String?, write: @escaping @Sendable (String) throws -> Void,
                remove: @escaping @Sendable () throws -> Void) {
        self.read = read; self.write = write; self.remove = remove
    }
    public static func keychain(appName: String, instanceId: String) -> Self {
        let owner = BackendConnectedTasksKeychain(appName: appName, namespace: "Cloud", devFile: "cloud-identity")
        return .init(read: {
            BackendCloudTrace.note("protected-read")
            // "Nothing saved" only when the item truly does not exist; every read failure throws (V's recovery relies on this).
            if let folder = BackendAccountDevKey.devFile(named: "cloud-identity") {
                let file = folder.appendingPathComponent(SHA256.hash(data: Data(instanceId.utf8)).map { String(format: "%02x", $0) }.joined())
                guard FileManager.default.fileExists(atPath: file.path) else { return nil }
                return String(decoding: try Data(contentsOf: file), as: UTF8.self)
            }
            return try owner.read(instanceId)
        }, write: { try owner.write(instanceId, token: $0) }, remove: { try owner.remove(instanceId) })
    }
}

extension BackendCloudAccountResponse {
    func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        guard (200...299).contains(status) else {
            // Two answer shapes (G1): Cloud's `{error:{code}}`, and the Store's `{code, error_code, msg}`
            // (store/cloudflare/src/auth.ts, e.g. session_not_found, refresh_token_not_found).
            if let envelope = try? CloudWire.decode(CloudValue.self, from: body),
               let code = envelope.raw["error"]["code"].string ?? envelope.raw["error_code"].string {
                throw CloudFailure.remote(.init(code: code, message: "Cloud could not finish this request.", retryable: status >= 500 || status == 429, requestId: ""))
            }
            throw CloudFailure.unavailable
        }
        return try CloudWire.decode(type, from: body)
    }
}

private final class BackendCloudNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
