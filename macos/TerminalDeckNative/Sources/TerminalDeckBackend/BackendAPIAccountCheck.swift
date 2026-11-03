import Foundation
import TerminalDeckNativeCore

private final class BackendAPINoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public enum BackendAPIAccountCheck {
    public static func request(_ record: BackendAPIAccountRecord, key: String?) throws -> URLRequest {
        var endpoint = try record.endpoint()
        if [.anthropic, .anthropicToken].contains(record.kind), endpoint.lastPathComponent != "v1" { endpoint.appendPathComponent("v1") }
        endpoint.appendPathComponent("models")
        var request = URLRequest(url: endpoint); request.httpMethod = "GET"; request.timeoutInterval = 10
        if let key { switch record.kind {
        case .anthropic: request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .gemini: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        default: request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        } }
        if [.anthropic, .anthropicToken].contains(record.kind) {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if let workspace = record.workspaceID { request.setValue(workspace, forHTTPHeaderField: "anthropic-workspace-id") }
        }
        return request
    }
    public static func classify(status: Int, body: Data) -> String {
        if (200...299).contains(status) {
            guard let value = try? NativeRPCValue.parseJSON(body), value["data"].elements != nil || value["models"].elements != nil else { return "no-access" }
            return "valid"
        }
        if status == 401 { return "invalid" }
        if status == 400, let value = try? NativeRPCValue.parseJSON(body),
           value["error"]["details"].elements?.contains(where: { $0["reason"].string == "API_KEY_INVALID" }) == true { return "invalid" }
        return "no-access"
    }
    /// #169: the provider's own sentence ("API key expired", "anthropic-workspace-id header is required"),
    /// so "no access" is never all the person learns. One line, bounded, secrets hidden.
    public static func detail(status: Int, body: Data) -> String? {
        guard !(200...299).contains(status) else { return nil }
        let value = try? NativeRPCValue.parseJSON(body)
        let said = value?["error"]["message"].string ?? value?["error"].string ?? value?["message"].string ?? ""
        let line = said.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? "The provider answered \(status)." : BackendSharedRedact.redact(String(line.prefix(300)))
    }
    public struct Outcome: Equatable, Sendable { public let state: String; public let detail: String? }
    public static func run(_ record: BackendAPIAccountRecord) async throws -> Outcome {
        let key = record.requiresKey ? try BackendAPIAccountKeychain.read(record) : nil
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config, delegate: BackendAPINoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request(record, key: key))
            guard let http = response as? HTTPURLResponse else { return .init(state: "no-access", detail: "The provider's answer was not a web reply.") }
            var body = Data()
            for try await byte in bytes {
                guard body.count < 1_048_576 else { return .init(state: "no-access", detail: "The provider's answer was too large to read.") }
                body.append(byte)
            }
            let state = classify(status: http.statusCode, body: body)
            return .init(state: state, detail: state == "valid" ? nil : detail(status: http.statusCode, body: body) ?? "The provider's answer did not list any models.")
        } catch { return .init(state: "no-access", detail: "The provider could not be reached: " + error.localizedDescription) }
    }
}
