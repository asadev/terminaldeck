import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// Current credentials.ts: local host credentials for mine sessions only.
/// Legacy credential.ack/answer/deny frames intentionally have no side effects.
public actor BackendRemoteServeCredentials {
    public struct Login: Sendable { public let username: String; public let password: String
        public init(username: String, password: String) { self.username = username; self.password = password } }
    public struct Grant: Sendable {
        public let key: String
        public let environment: BackendRemoteServeGitGuest.Environment
    }
    public static let credentialHeader = "x-terminaldeck-credential"
    public static let pidHeader = "x-terminaldeck-pid"
    public static let path = "/credential"
    public static let reachTimeoutMilliseconds = 4_000
    public static let decideTimeoutMilliseconds = 60_000
    public static let silentTimeoutMilliseconds = 10_000
    public static let maximumRequestBytes = 16 * 1024
    private struct Row { let device: String; var session: String? }
    private let root: URL
    private let hostCredential: @Sendable () async -> Login?
    private let bind: @Sendable (BackendRemoteServeCredentialHTTP) async throws -> Int
    private var ownDevice: (@Sendable (String) async -> Bool)?
    private var grants: [String: Row] = [:]
    private var bySession: [String: String] = [:]
    private var endpoint: BackendRemoteServeCredentialHTTP?
    private var opening: Task<Int, Error>?
    private var addressValue: String?
    private var stopped = false
    public init(directory: URL, hostCredential: @escaping @Sendable () async -> Login? = { nil },
                bind: @escaping @Sendable (BackendRemoteServeCredentialHTTP) async throws -> Int = { try await $0.start() }) {
        root = directory; self.hostCredential = hostCredential; self.bind = bind
    }
    public func serve(ownDevice: (@Sendable (String) async -> Bool)?) { self.ownDevice = ownDevice }
    public func start() async -> String? {
        guard !stopped else { return nil }
        if let opening {
            guard let port = try? await opening.value, !stopped else { return nil }
            return "http://127.0.0.1:\(port)/credential"
        }
        if endpoint != nil { return addressValue }
        let server = BackendRemoteServeCredentialHTTP(headerHandler: { [weak self] method, path, headers in
            guard let self else { return .init(status: 500, body: "that did not work") }
            return await self.headerFailure(method: method, path: path, headers: headers)
        }) { [weak self] request in
            guard let self else { return .init(status: 500, body: "that did not work") }
            return await self.handleHTTP(method: request.method, path: request.path, headers: request.headers, body: request.body)
        }
        endpoint = server
        let task = Task { try await bind(server) }; opening = task
        do {
            let port = try await task.value
            opening = nil
            guard !stopped else { await server.stop(); endpoint = nil; return nil }
            addressValue = "http://127.0.0.1:\(port)/credential"; return addressValue
        } catch { opening = nil; await server.stop(); endpoint = nil; addressValue = nil; return nil }
    }
    public func address() -> String? { addressValue }
    public func openGuestSession(deviceID: String) async throws -> Grant {
        let url = await start()
        let key = try BackendRemoteTrustStorage.random(32).map { String(format: "%02x", $0) }.joined()
        grants[key] = Row(device: deviceID, session: nil)
        let directory = BackendRemoteServeGitGuest.directory(root: root, deviceKey: Self.deviceKey(deviceID))
        let link = url.map { BackendRemoteServeGitGuest.Link(url: $0, key: key, helper: root.appendingPathComponent(BackendRemoteServeGitGuest.helperFile).path) }
        do { return Grant(key: key, environment: try BackendRemoteServeGitGuest.prepare(.init(directory: directory, link: link))) }
        catch { grants[key] = nil; throw error }
    }
    public func started(key: String, sessionID: String) { guard var row = grants[key] else { return }; row.session = sessionID; grants[key] = row; bySession[sessionID] = key }
    public func close(key: String) { if let session = grants.removeValue(forKey: key)?.session { bySession[session] = nil } }
    public func sessionEnded(_ sessionID: String) { if let key = bySession.removeValue(forKey: sessionID) { grants[key] = nil } }
    public func forget(_ deviceID: String) { for (key, row) in grants where row.device == deviceID { close(key: key) } }
    public func connectionClosed(_ deviceID: String) {} // no pending phone requests since the host-login flip
    public func handle(deviceID: String, message: BackendRemoteClientMessage) {} // legacy frames are deliberately ignored
    /// Register routing without advertising the retired credential capability.
    public func legacyFeature() -> BackendRemoteHostFeature {
        .init(capability: "credential.legacy", messageTypes: ["credential.ack", "credential.answer", "credential.deny"], policy: .grantedDevice) { [self] message, context in
            await handle(deviceID: context.deviceID, message: message); return []
        }
    }
    public func stop() async {
        stopped = true; grants = [:]; bySession = [:]
        let pending = opening; if let pending { _ = try? await pending.value }
        await endpoint?.stop(); endpoint = nil; opening = nil; addressValue = nil
    }
    public func handleHTTP(method: String, path: String, headers: [String: String], body: Data) async -> BackendRemoteServeCredentialHTTP.Response {
        if let failure = headerFailure(method: method, path: path, headers: headers) { return failure }
        let key = headers[Self.credentialHeader] ?? ""
        guard body.count <= Self.maximumRequestBytes else { return .init(status: 413, body: "that request was too large") }
        let answer = await request(key: key, text: String(decoding: body, as: UTF8.self))
        return .init(status: 200, body: answer, nosniff: true)
    }
    public func headerFailure(method: String, path: String, headers: [String: String]) -> BackendRemoteServeCredentialHTTP.Response? {
        if method != "POST" { return .init(status: 405, body: "that is not how to ask") }
        if path.components(separatedBy: "?").first != Self.path { return .init(status: 404, body: "nothing here") }
        let host = (headers["host"] ?? "").replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression)
        guard ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host) else { return .init(status: 403, body: "not for you") }
        let key = headers[Self.credentialHeader] ?? ""
        guard !key.isEmpty, grants[key] != nil else { return .init(status: 403, body: "not for you") }
        return nil
    }
    public func request(key: String, text: String) async -> String {
        guard let grant = grants[key], !stopped else { return "!This session is not set up to use a GitHub account." }
        guard BackendRemoteServeCredentialParser.parse(text) != nil else { return "!That request did not say which host it needed a login for." }
        let own = await ownDevice?(grant.device) ?? true
        guard own else { return "!This machine's GitHub account is not shared with other devices. Push with a token scoped to that one repository." }
        guard let credential = await hostCredential() else { return "!No GitHub account is connected on this machine. Connect one on the host, then try again." }
        // Async native adapters may yield; never answer a grant revoked while reading.
        guard !stopped, grants[key]?.device == grant.device else { return "!This session is not set up to use a GitHub account." }
        return BackendRemoteServeCredentialParser.format(username: credential.username, password: credential.password) ?? "!That answer was not usable."
    }
    public static func deviceKey(_ deviceID: String) -> String { String(SHA256.hash(data: Data(deviceID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)) }
}

public enum BackendRemoteServeCredentialParser {
    public struct Query: Equatable, Sendable { public let protocolName: String; public let host: String; public let repo: String? }
    public struct PSRow: Equatable, Sendable { public let parent: Int; public let arguments: String }
    public static func parse(_ text: String) -> Query? {
        var values: [String: String] = [:]
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty { break }
            guard let equal = line.firstIndex(of: "="), equal != line.startIndex else { continue }
            let key = String(line[..<equal]); if ["protocol", "host", "path"].contains(key) { values[key] = String(line[line.index(after: equal)...]) }
        }
        let host = values["host"] ?? "", proto = values["protocol"] ?? "", path = values["path"] ?? ""
        guard !host.isEmpty, host.utf16.count <= 253 else { return nil }
        var repo: String?
        let scheme = proto.isEmpty ? "https" : proto
        if !path.isEmpty, path.utf16.count <= 256, scheme.range(of: #"^[a-z][a-z0-9+.-]*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            let cleanHost = host.components(separatedBy: "@").last!.replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression)
            let parts = path.split(separator: "/").map(String.init)
            if cleanHost.range(of: #"^[a-z0-9][a-z0-9.-]*$"#, options: [.regularExpression, .caseInsensitive]) != nil, parts.count == 2 {
                let owner = parts[0], name = parts[1].replacingOccurrences(of: #"\.git$"#, with: "", options: [.regularExpression, .caseInsensitive])
                func valid(_ value: String) -> Bool { !value.isEmpty && value != "." && value != ".." && value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil }
                if valid(owner), valid(name), !owner.hasPrefix("-") { repo = owner + "/" + name }
            }
        }
        return Query(protocolName: proto, host: host, repo: repo)
    }
    public static func format(username: String, password: String) -> String? {
        let banned: Set<UInt32> = [13, 10, 0]
        guard !username.unicodeScalars.contains(where: { banned.contains($0.value) }), !password.unicodeScalars.contains(where: { banned.contains($0.value) }) else { return nil }
        return "username=\(username)\npassword=\(password)\n"
    }
    public static func gitSubcommand(_ line: String) -> String? {
        let tokens = BackendRemoteServeText.words(line)
        for (i, token) in tokens.enumerated() {
            let name = token.components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? ""
            if name != "git" && name != "git.exe" { continue }
            var j = i + 1
            while j < tokens.count {
                if ["-c", "-C", "--git-dir", "--work-tree", "--namespace", "--exec-path"].contains(tokens[j]) { j += 2; continue }
                if tokens[j].hasPrefix("-") { j += 1; continue }; return tokens[j]
            }
            return nil
        }; return nil
    }
    public static func classifyOperation(_ ancestry: [String]) -> String {
        for line in ancestry {
            guard let verb = gitSubcommand(line) else { continue }
            if ["fetch", "pull", "clone", "ls-remote", "remote", "submodule", "archive", "upload-pack"].contains(verb) { return "read" }
            if ["push", "send-pack", "receive-pack"].contains(verb) { return "write" }
        }; return "write"
    }
    public static func parsePSTable(_ output: String) -> [Int: PSRow] {
        var result: [Int: PSRow] = [:]
        let regex = try! NSRegularExpression(pattern: #"^\s*(\d+)\s+(\d+)\s+(.*)$"#)
        for line in output.components(separatedBy: "\n") {
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let a = Range(match.range(at: 1), in: line), let b = Range(match.range(at: 2), in: line), let c = Range(match.range(at: 3), in: line),
                  let pid = Int(line[a]), let parent = Int(line[b]) else { continue }
            result[pid] = PSRow(parent: parent, arguments: String(line[c]))
        }; return result
    }
    public static func ancestry(_ table: [Int: PSRow], pid: Int) -> [String] {
        var at = pid, seen = Set<Int>(), result: [String] = []
        for _ in 0..<8 {
            guard seen.insert(at).inserted, let row = table[at] else { break }
            result.append(row.arguments); if row.parent <= 1 { break }; at = row.parent
        }; return result
    }
}
