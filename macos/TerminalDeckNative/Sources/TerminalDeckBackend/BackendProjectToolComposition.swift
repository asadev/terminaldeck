import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// The actual stdio implementation supplied by the project's engine owner.
/// Transitional Node handlers are labeled suppliedSourceBridge explicitly.
public struct BackendProjectMCPServerSpec: Sendable {
    public let name: String
    public let command: String
    public let arguments: [String]
    public let environment: [String: String]
    public let implementation: BackendMCPImplementation
    public init(name: String, command: String, arguments: [String], environment: [String: String],
                implementation: BackendMCPImplementation) throws {
        guard name.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil,
              command.hasPrefix("/"), !command.contains("\0"), arguments.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            throw BackendSessionFailure.invalidInput("A project MCP server needs its actual executable, argv and environment.")
        }
        self.name = name; self.command = command; self.arguments = arguments
        self.environment = environment; self.implementation = implementation
    }
    var wireValue: NativeRPCValue {
        .object([.init("type", .string("stdio")), .init("command", .string(command)),
            .init("args", .array(arguments.map(NativeRPCValue.string))),
            .init("env", .object(environment.keys.sorted().map { .init($0, .string(environment[$0]!)) }))])
    }
}

/// The app/helper's main must route this real prefix to BackendMCPStdioRelay
/// before opening windows. No unimplemented executable is assumed by default.
public struct BackendNativeMCPStdioLauncher: Sendable {
    public let command: String
    public let argumentsPrefix: [String]
    public init(command: String, argumentsPrefix: [String]) throws {
        guard command.hasPrefix("/"), !argumentsPrefix.isEmpty, !command.contains("\0"),
              argumentsPrefix.allSatisfy({ !$0.contains("\0") }) else {
            throw BackendSessionFailure.missingCapability("the wired native MCP stdio relay entrypoint")
        }
        self.command = command; self.argumentsPrefix = argumentsPrefix
    }
}

public enum BackendProjectMCPDefinition: Sendable {
    case stdio(root: String, server: BackendProjectMCPServerSpec)
    case registeredEndpoint(root: String, serverName: String, endpoint: any BackendMCPToolEndpoint,
                            toolNames: Set<String>, stdioLauncher: BackendNativeMCPStdioLauncher)
}
public protocol BackendProjectMCPSource: BackendLaunchCapability {
    /// Nil means not set up/off; a set-up project with an unavailable engine
    /// must throw so the launch report can say which capability was absent.
    func resolve(cwd: String, provider: String, loginPath: String) async throws -> BackendProjectMCPDefinition?
}

/// Source staysfixed/where.ts and prefs.ts. Reads existing settings only.
/// The definition factory is the actual engine/registered-handler owner, never
/// a guessed executable, empty successful server or invented tool inventory.
public struct BackendStaysFixedProjectSource: BackendProjectMCPSource, Sendable {
    public let readiness: BackendLaunchReadiness
    private let userData: URL
    private let home: String
    private let definition: @Sendable (String, String, String) async throws -> BackendProjectMCPDefinition
    public init(userData: URL, home: String, readiness: BackendLaunchReadiness,
                definition: @escaping @Sendable (String, String, String) async throws -> BackendProjectMCPDefinition) throws {
        guard userData.isFileURL, userData.path.hasPrefix("/"), home.hasPrefix("/") else {
            throw BackendSessionFailure.invalidInput("Project-tool discovery needs the actual app data root and account home.")
        }
        self.userData = userData; self.home = URL(fileURLWithPath: home).standardizedFileURL.path
        self.readiness = readiness; self.definition = definition
    }
    public func resolve(cwd: String, provider: String, loginPath: String) async throws -> BackendProjectMCPDefinition? {
        guard ["claude", "codex", "gemini"].contains(provider) else { return nil }
        guard readiness == .ready else { throw BackendSessionFailure.missingCapability("the project's actual MCP engine/handlers") }
        guard cwd.hasPrefix("/"), !cwd.contains("\0") else { throw BackendSessionFailure.invalidInput("Project-tool discovery needs an absolute working folder.") }
        var folder = URL(fileURLWithPath: cwd).standardizedFileURL
        var found: String?
        for _ in 0..<12 {
            if Self.configNames.contains(where: { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }) { found = folder.path; break }
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) || folder.path == home { break }
            let parent = folder.deletingLastPathComponent()
            if parent == folder { break }; folder = parent
        }
        guard let found else { return nil }
        let preferences = userData.appendingPathComponent("staysfixed.json")
        if FileManager.default.fileExists(atPath: preferences.path) {
            let size = try preferences.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 2 * 1024 * 1024 else { throw BackendSessionFailure.invalidInput("Project-tool preferences exceed the supported size.") }
            let data = try Data(contentsOf: preferences)
            guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BackendSessionFailure.invalidInput("Project-tool preferences are invalid.") }
            if ((state["projects"] as? [String: Any])?[found] as? [String: Any])?["agents"] as? Bool == false { return nil }
        }
        return try await definition(found, provider, loginPath)
    }
    private static let configNames = ["staysfixed.config.js", "staysfixed.config.mjs", "staysfixed.config.json", ".staysfixed/config.js", ".staysfixed/config.mjs", ".staysfixed/config.json"]
}

public struct BackendPreparedProjectTools: Sendable {
    public let id: UUID
    public let arguments: [String]
    public let environment: [String: String]
    public let readableFiles: [String]
    public let implementation: BackendMCPImplementation
}

/// Source per-provider launch forms: repeatable Claude --mcp-config, Codex -c
/// stdio overrides with the 900-second tool timeout, and Gemini's lowest system
/// defaults layer with all existing administrator defaults carried forward.
public actor BackendProjectToolComposition: BackendLaunchCapability {
    public nonisolated let readiness: BackendLaunchReadiness
    private let source: any BackendProjectMCPSource
    private let userData: URL
    private let inherited: [String: String]
    private let runID = UUID().uuidString.lowercased()
    private struct Lease: Sendable {
        let directory: URL
        let tools: BackendSessionToolLeases?
        let tokenLease: UUID?
        var sessionID: String?
        let deadline: Task<Void, Never>
    }
    private var leases: [UUID: Lease] = [:]
    private var stopped = false
    public init(source: any BackendProjectMCPSource, userData: URL, inheritedEnvironment: [String: String]) throws {
        guard userData.isFileURL, userData.path.hasPrefix("/") else { throw BackendSessionFailure.invalidInput("Project launch composition needs the app's own user-data root.") }
        self.source = source; self.userData = userData; inherited = inheritedEnvironment; readiness = source.readiness
    }
    public func prepare(provider: String, cwd: String, loginPath: String) async throws -> BackendPreparedProjectTools? {
        guard !stopped else { throw BackendSessionFailure.closed }
        guard let definition = try await source.resolve(cwd: cwd, provider: provider, loginPath: loginPath) else { return nil }
        guard !stopped else { throw BackendSessionFailure.closed }
        let id = UUID()
        let base = userData.appendingPathComponent("staysfixed/agents", isDirectory: true)
        let directory = base.appendingPathComponent("native-" + runID).appendingPathComponent(id.uuidString.lowercased())
        var tools: BackendSessionToolLeases?
        var tokenLease: UUID?
        let server: BackendProjectMCPServerSpec
        do {
            switch definition {
            case .stdio(_, let spec):
                guard BackendNativeProviders.lookup(spec.command, path: loginPath) != nil else { throw BackendSessionFailure.missingCapability("the project's actual MCP engine executable") }
                server = spec
            case let .registeredEndpoint(projectRoot, name, endpoint, names, launcher):
                let registry = try BackendSessionToolLeases(endpoint: endpoint, userData: userData)
                let prepared = try await registry.prepare(serverName: name, allowed: names, projectRoot: projectRoot)
                tools = registry; tokenLease = prepared.id
                server = try await registry.nativeStdioSpec(prepared, serverName: name, launcher: launcher)
            }
            guard !stopped else { throw BackendSessionFailure.closed }
            try BackendPrivateLaunchFiles.createDirectory(directory, under: base)
            var arguments: [String] = [], environment: [String: String] = [:], files: [String] = []
            if provider == "claude" {
                let file = directory.appendingPathComponent("claude.json")
                let value = NativeRPCValue.object([.init("mcpServers", .object([.init(server.name, server.wireValue)]))])
                try BackendPrivateLaunchFiles.write(try value.encodedJSON(pretty: true), to: file)
                arguments = ["--mcp-config", file.path]; files = [file.path]
            } else if provider == "codex" {
                let prefix = "mcp_servers." + server.name
                arguments = ["-c", prefix + ".command=" + BackendNativeInstructions.tomlString(server.command),
                    "-c", prefix + ".args=[" + server.arguments.map(BackendNativeInstructions.tomlString).joined(separator: ",") + "]",
                    "-c", prefix + ".env=" + Self.tomlTable(server.environment), "-c", prefix + ".tool_timeout_sec=900"]
            } else if provider == "gemini" {
                let defaults = Self.geminiDefaultsPath(inherited)
                var object = NativeRPCValue.object([])
                if FileManager.default.fileExists(atPath: defaults.path) {
                    // An unreadable defaults file is never hidden: give no tool setup at all and leave the launch intact.
                    func unreadable() async -> BackendPreparedProjectTools? {
                        if let tools, let tokenLease { await tools.abandon(tokenLease); await tools.stop() }
                        try? FileManager.default.removeItem(at: directory)
                        return nil
                    }
                    let size = (try? defaults.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
                    guard size <= 2 * 1024 * 1024 else { return await unreadable() }
                    guard let parsed = try? NativeRPCValue.parseJSON(Data(contentsOf: defaults), maximumBytes: 2 * 1024 * 1024), parsed.fields != nil else { return await unreadable() }
                    object = parsed
                }
                let current = object["mcpServers"].fields == nil ? NativeRPCValue.object([]) : object["mcpServers"]
                let value = object.setting("mcpServers", current.setting(server.name, server.wireValue.removing("type").setting("timeout", .number(900_000))))
                let file = directory.appendingPathComponent("gemini.json")
                try BackendPrivateLaunchFiles.write(try value.encodedJSON(pretty: true), to: file)
                environment["GEMINI_CLI_SYSTEM_DEFAULTS_PATH"] = file.path; files = [file.path]
            } else { throw BackendSessionFailure.unsupported("This provider has no measured per-launch project MCP configuration.") }
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await self?.expire(id)
            }
            leases[id] = Lease(directory: directory, tools: tools, tokenLease: tokenLease, deadline: deadline)
            return BackendPreparedProjectTools(id: id, arguments: arguments, environment: environment,
                readableFiles: files, implementation: server.implementation)
        } catch {
            if let tools, let tokenLease { await tools.abandon(tokenLease); await tools.stop() }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    public func bind(_ id: UUID, sessionID: String) async throws {
        guard var lease = leases[id], lease.sessionID == nil else { throw BackendSessionFailure.invalidInput("The pending project-tool launch expired.") }
        if let tools = lease.tools, let token = lease.tokenLease { try await tools.bind(token, sessionID: sessionID) }
        guard !stopped, leases[id] != nil else { throw BackendSessionFailure.closed }
        lease.deadline.cancel(); lease.sessionID = sessionID; leases[id] = lease
    }
    public func abandon(_ id: UUID) async { await forget(id) }
    public func release(sessionID: String) async {
        for id in leases.compactMap({ $0.value.sessionID == sessionID ? $0.key : nil }) { await forget(id) }
    }
    public func stop() async { stopped = true; for id in Array(leases.keys) { await forget(id) } }
    private func expire(_ id: UUID) async { if leases[id]?.sessionID == nil { await forget(id) } }
    private func forget(_ id: UUID) async {
        guard let lease = leases.removeValue(forKey: id) else { return }
        lease.deadline.cancel()
        if let tools = lease.tools { await tools.stop() }
        try? FileManager.default.removeItem(at: lease.directory)
    }
    private static func geminiDefaultsPath(_ environment: [String: String]) -> URL {
        if let given = environment["GEMINI_CLI_SYSTEM_DEFAULTS_PATH"], !given.isEmpty { return URL(fileURLWithPath: given) }
        let settings = environment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] ?? "/Library/Application Support/GeminiCli/settings.json"
        return URL(fileURLWithPath: settings).deletingLastPathComponent().appendingPathComponent("system-defaults.json")
    }
    private static func tomlTable(_ values: [String: String]) -> String {
        "{" + values.keys.sorted().map { key in
            let name = key.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) == nil ? BackendNativeInstructions.tomlString(key) : key
            return name + "=" + BackendNativeInstructions.tomlString(values[key]!)
        }.joined(separator: ",") + "}"
    }
}
