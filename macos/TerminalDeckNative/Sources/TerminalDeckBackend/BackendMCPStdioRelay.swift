import Foundation
import TerminalDeckNativeCore

/// A real native stdio transport for a registered loopback MCP endpoint. The
/// app/helper main calls it before UI startup for its wired command prefix.
/// URL/token file are backend-generated argv, with the secret read only from
/// the app's own private lease directory. No token appears in argv/stdout/logs.
public enum BackendMCPStdioRelay {
    public static func run(endpoint: URL, tokenFile: URL, trustedUserData: URL) async throws {
        _ = try BackendMCPEndpointDescription(url: endpoint, implementation: .native)
        let root = trustedUserData.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("session-tools", isDirectory: true)
        let file = tokenFile.standardizedFileURL
        guard file.path.hasPrefix(root.path + "/native-"), file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/native-"),
              file.pathExtension == "token" else { throw BackendSessionFailure.invalidInput("The native MCP relay needs an app-owned pending token file.") }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == 64 else {
            throw BackendSessionFailure.invalidInput("The native MCP relay's private token file is invalid.")
        }
        let data = try Data(contentsOf: file)
        guard let token = String(data: data, encoding: .utf8), token.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw BackendSessionFailure.invalidInput("The native MCP relay's private token is invalid.")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 900
        configuration.timeoutIntervalForResource = 910
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let writer = Writer()
        let state = Calls()
        var pending = Data()
        defer { state.cancel() }
        while let bytes = try FileHandle.standardInput.read(upToCount: 64 * 1024), !bytes.isEmpty {
            pending.append(bytes)
            guard pending.count <= 256 * 1024 else { throw BackendSessionFailure.invalidInput("An MCP stdio frame exceeds the supported request size.") }
            while let newline = pending.firstIndex(of: 10) {
                let frame = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                if frame.isEmpty { continue }
                let envelope = try NativeRPCValue.parseJSON(frame, maximumBytes: 256 * 1024)
                let id = envelope["id"]
                let key = UUID().uuidString
                guard state.reserve(key) else { throw BackendSessionFailure.invalidInput("The MCP stdio relay has too many pending requests.") }
                let task = Task {
                    defer { state.finished(key) }
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"; request.httpBody = frame
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                    do {
                        let (body, response) = try await session.data(for: request)
                        guard let http = response as? HTTPURLResponse, response.url == endpoint,
                              body.count <= 16 * 1024 * 1024 else { throw BackendSessionFailure.invalidInput("The native MCP endpoint returned an invalid response.") }
                        if http.statusCode == 202 && id == .missing { return }
                        guard http.statusCode == 200 else { throw BackendSessionFailure.invalidInput("The registered MCP endpoint refused the request.") }
                        let reply: NativeRPCValue
                        if http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true {
                            reply = try Self.eventStreamReply(body, id: id)
                        } else { reply = try NativeRPCValue.parseJSON(body, maximumBytes: 16 * 1024 * 1024) }
                        await writer.write(try reply.encodedJSON())
                    } catch {
                        guard id != .missing, !Task.isCancelled else { return }
                        let reply = NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("id", id),
                            .init("error", .object([.init("code", .number(-32000)), .init("message", .string("The registered tool endpoint could not complete this request."))]))])
                        if let bytes = try? reply.encodedJSON() { await writer.write(bytes) }
                    }
                }
                state.register(key, task: task)
            }
        }
        // EOF means the parent CLI has gone. Cancel HTTP requests and consent
        // contexts before returning, rather than wait for their deadlines.
        state.cancel()
    }

    private static func eventStreamReply(_ bytes: Data, id: NativeRPCValue) throws -> NativeRPCValue {
        guard let text = String(data: bytes, encoding: .utf8) else { throw BackendSessionFailure.invalidInput("The supplied MCP endpoint returned an invalid event stream.") }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for event in normalized.components(separatedBy: "\n\n").reversed() {
            let payload = event.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }
                .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            if !payload.isEmpty, let value = try? NativeRPCValue.parseJSON(Data(payload.utf8)), value["id"] == id { return value }
        }
        throw BackendSessionFailure.invalidInput("The supplied MCP endpoint returned no reply for this request.")
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private actor Writer {
        func write(_ bytes: Data) { try? FileHandle.standardOutput.write(contentsOf: bytes + Data([10])) }
    }
    private final class Calls: @unchecked Sendable {
        private enum Slot { case pending, running(Task<Void, Never>) }
        private let lock = NSLock()
        private var tasks: [String: Slot] = [:]
        private var cancelled = false
        var count: Int { lock.withLock { tasks.count } }
        func reserve(_ id: String) -> Bool {
            lock.withLock {
                guard !cancelled, tasks.count < 64 else { return false }
                tasks[id] = .pending; return true
            }
        }
        func register(_ id: String, task: Task<Void, Never>) {
            let cancel = lock.withLock {
                if cancelled || tasks[id] == nil { return true }
                tasks[id] = .running(task); return false
            }
            if cancel { task.cancel() }
        }
        func finished(_ id: String) { lock.withLock { tasks[id] = nil } }
        func cancel() {
            let values = lock.withLock { cancelled = true; let values = Array(tasks.values); tasks.removeAll(); return values }
            for slot in values { if case .running(let task) = slot { task.cancel() } }
        }
    }
}
