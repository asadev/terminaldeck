import Foundation
import TerminalDeckNativeCore

/// Reads OpenSSH's effective configuration. It does not parse Host/Match rules,
/// open a server connection, read key bytes or carry proxy/hooks into a dialer.
public struct BackendDockerMCPServerSSHConfig: Sendable {
    public struct Resolution: Sendable, Equatable {
        public let hostname: String
        public let user: String
        public let port: Int
        /// Effective order from ssh -G. Existence/credential choice belongs to
        /// the existing server discovery/approval owner, never this resolver.
        public let identityFiles: [String]
    }
    public struct Evaluation: Sendable {
        public let executable: URL
        public let arguments: [String]
        public let environment: [String: String]
        public let workingDirectory: URL
        public let timeoutMilliseconds: Int
        public let maximumOutputBytes: Int
    }
    public typealias Evaluator = @Sendable (Evaluation) async throws -> BackendServersRunResult
    private let evaluate: Evaluator
    private static let maximumBytes = 65_536
    private static let maximumMilliseconds = 5_000

    public init(evaluate: Evaluator? = nil) {
        self.evaluate = evaluate ?? { try await Self.systemEvaluate($0) }
    }

    public func resolve(alias: String, home: URL, configurationFile: URL? = nil) async throws -> Resolution {
        try Task.checkCancellation()
        guard Self.validAlias(alias) else { throw NativeRPCError.invalidArguments("Choose one SSH alias without options, whitespace or shell syntax.") }
        let localHome = try Self.localFile(home, directory: true)
        let configuration = try Self.localFile(configurationFile ?? localHome.appendingPathComponent(".ssh", isDirectory: true).appendingPathComponent("config", isDirectory: false), directory: false)
        let deadline = ProcessInfo.processInfo.systemUptime + Double(Self.maximumMilliseconds) / 1000
        let output = try await run(Self.request(alias: alias, home: localHome, configuration: configuration, deadline: deadline))
        let parsed = try Self.parse(output)
        guard let hostname = parsed.hostname, let user = parsed.user, let port = parsed.port else {
            throw Self.unavailable("SSH did not report a complete effective host, user and port.")
        }
        var identities = try parsed.identities.map { try Self.identityPath($0, home: localHome) }
        if !parsed.hasIdentityDirective {
            // Ask OpenSSH for its defaults. Do not fabricate a credential path
            // or reinterpret IdentityFile none as permission to pick a key.
            let baseline = try await run(Self.request(alias: alias, home: localHome,
                configuration: URL(fileURLWithPath: "/dev/null"), deadline: deadline))
            let defaults = try Self.parse(baseline)
            // Every default ssh itself would try (RSA, ECDSA, Ed25519, ...): callers keep the ones on disk (#496).
            identities = try defaults.identities.map { try Self.identityPath($0, home: localHome) }
            guard !identities.isEmpty else { throw Self.unavailable("SSH did not report a default identity file.") }
        }
        try Task.checkCancellation()
        return Resolution(hostname: hostname, user: user, port: port, identityFiles: identities)
    }

    private func run(_ request: Evaluation) async throws -> String {
        try Task.checkCancellation()
        let result: BackendServersRunResult
        do { result = try await evaluate(request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw Self.unavailable("SSH alias configuration could not be evaluated.")
        }
        try Task.checkCancellation()
        guard result.code == 0, result.signal == nil, !result.truncated,
              result.stdout.utf8.count + result.stderr.utf8.count <= request.maximumOutputBytes else {
            throw Self.unavailable("SSH alias configuration could not be evaluated within its limits.")
        }
        return result.stdout
    }

    private static func request(alias: String, home: URL, configuration: URL, deadline: Double) throws -> Evaluation {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining.isFinite, remaining > 0 else { throw unavailable("SSH alias configuration evaluation timed out.") }
        let timeout = min(maximumMilliseconds, max(1, Int((remaining * 1000).rounded(.up))))
        let options = ["BatchMode=yes", "ProxyCommand=none", "PermitLocalCommand=no", "LocalCommand=none",
                       "RemoteCommand=none", "ControlMaster=no", "IdentityAgent=none"]
        return Evaluation(executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: ["-G", "-F", configuration.path] + options.flatMap { ["-o", $0] } + ["--", alias],
            environment: ["HOME": home.path, "LANG": "C", "LC_ALL": "C", "PATH": "/usr/bin:/bin"],
            workingDirectory: home, timeoutMilliseconds: timeout, maximumOutputBytes: maximumBytes)
    }

    private static func systemEvaluate(_ request: Evaluation) async throws -> BackendServersRunResult {
        let child = BackendServersSSHProcess(executable: request.executable, arguments: request.arguments, environment: request.environment)
        child.process.currentDirectoryURL = request.workingDirectory
        defer { child.close() }
        try Task.checkCancellation()
        try child.start()
        return try await child.collect(stdin: nil, timeoutMilliseconds: request.timeoutMilliseconds,
                                       maximumOutputBytes: request.maximumOutputBytes)
    }

    private struct Parsed {
        var hostname: String?
        var user: String?
        var port: Int?
        var identities: [String] = []
        var hasIdentityDirective = false
    }
    private static func parse(_ output: String) throws -> Parsed {
        guard !output.contains("\0") else { throw unavailable("SSH returned invalid alias configuration.") }
        var result = Parsed()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let boundary = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let key = line[..<boundary].lowercased()
            let value = String(line[line.index(after: boundary)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "hostname":
                guard result.hostname == nil, validSingleValue(value), !value.hasPrefix("-") else { throw unavailable("SSH returned an invalid effective hostname.") }
                result.hostname = value
            case "user":
                guard result.user == nil, validSingleValue(value) else { throw unavailable("SSH returned an invalid effective user.") }
                result.user = value
            case "port":
                guard result.port == nil, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let port = Int(value), (1...65_535).contains(port) else { throw unavailable("SSH returned an invalid effective port.") }
                result.port = port
            case "identityfile":
                result.hasIdentityDirective = true
                guard !value.isEmpty, value.utf8.count <= 4096, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                      result.identities.count < 64 else { throw unavailable("SSH returned invalid identity file metadata.") }
                if value.lowercased() != "none" { result.identities.append(value) }
            default: continue // ProxyCommand, hooks, agents and all other fields stay out of Resolution.
            }
        }
        return result
    }

    private static func identityPath(_ raw: String, home: URL) throws -> String {
        guard !raw.contains("${") else { throw unavailable("SSH identity paths need a supported explicit home token.") }
        var expanded = "", index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            index = raw.index(after: index)
            if character != "%" { expanded.append(character); continue }
            guard index < raw.endIndex else { throw unavailable("SSH identity paths contain an unsupported token.") }
            let token = raw[index]; index = raw.index(after: index)
            switch token {
            case "d": expanded += home.path
            case "%": expanded += "%"
            default: throw unavailable("SSH identity paths contain an unsupported token.")
            }
        }
        if expanded == "~" { expanded = home.path }
        else if expanded.hasPrefix("~/") { expanded = home.path + String(expanded.dropFirst()) }
        else if expanded.hasPrefix("~") { throw unavailable("SSH identity paths must use the explicit user's home.") }
        let path = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : home.appendingPathComponent(expanded)
        return path.standardizedFileURL.path
    }
    /// Pure policy precheck; does not evaluate config or launch a process.
    public static func validAlias(_ alias: String) -> Bool {
        let bytes = Array(alias.utf8)
        return (1...255).contains(bytes.count) && bytes.first != 45 && bytes.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }
    private static func validSingleValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && !value.contains(where: \.isWhitespace)
            && !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }
    private static func localFile(_ url: URL, directory: Bool) throws -> URL {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost", url.path.hasPrefix("/"),
              !url.path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), url.path.utf8.count <= 4096 else {
            throw NativeRPCError.invalidArguments("SSH configuration requires explicit local home and config paths.")
        }
        return URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: directory)
    }
    private static func unavailable(_ message: String) -> NativeRPCError { .init(code: "unavailable", message: message) }
}
