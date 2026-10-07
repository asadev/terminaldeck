import Foundation
import TerminalDeckNativeCore

public enum BackendMcpClientStoreRules {
    public struct Install: Sendable { public let command: String; public let extras: [String]; public let inherited: [String] }
    public static func buildInstall(_ entry: NativeRPCValue, values: NativeRPCValue, available: Set<String>) throws -> Install {
        let name = entry["name"].string ?? ""; var command = entry["command"].string ?? "", extras: [String] = [], inherited: [String] = []
        for field in entry["inputs"].elements ?? [] {
            let key = field["key"].string ?? "", label = field["label"].string ?? "", typed = BackendMcpClientValue.text(values[key])
            let placeholder = "${" + key + "}"
            if field["into"].string == "arg" {
                if typed.isEmpty {
                    if field["required"].bool == true { throw BackendMcpClientValue.error("\(name) needs \(label.lowercased()).") }
                    command = command.replacingOccurrences(of: placeholder, with: "").replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines); continue
                }
                guard command.contains(placeholder) else { throw BackendMcpClientValue.error("This build cannot fill \(key) for \(name).") }
                if typed.contains("\"") { throw BackendMcpClientValue.error("\(label) cannot contain a double quote.") }
                command = command.replacingOccurrences(of: placeholder, with: "\"" + typed + "\""); continue
            }
            if !typed.isEmpty {
                if typed.contains("\r") || typed.contains("\n") { throw BackendMcpClientValue.error("\(label) cannot contain a line break.") }
                extras.append(key + "=" + typed); continue
            }
            if available.contains(key) { inherited.append(key); continue }
            if field["required"].bool == true { throw BackendMcpClientValue.error("\(name) needs \(label.lowercased()).") }
        }
        if command.contains("${") { throw BackendMcpClientValue.error("Something in \(name)’s command was not filled in.") }
        if try BackendMcpClientCommands.tokenize(command).isEmpty { throw BackendMcpClientValue.error("\(name) has no command.") }
        return .init(command: command, extras: extras, inherited: inherited)
    }
    public static func customBinary(_ server: BackendMcpClientConfigured) -> String {
        guard server.transport == .stdio else { return "" }; return (try? BackendMcpClientCommands.tokenize(server.command).first) ?? ""
    }
    public static func customBinaries(_ servers: [BackendMcpClientConfigured]) -> [String] { Set(servers.map(customBinary).filter { !$0.isEmpty }).sorted() }
    public static func customID(_ server: BackendMcpClientConfigured) -> String { "own:\(server.scope):\(server.name)" }
    public static func isCustomID(_ id: String) -> Bool { id.hasPrefix("own:") }
    public static func customRows(_ configured: [BackendMcpClientConfigured], claimed: Set<String>, binaries: [NativeRPCValue]) -> [NativeRPCValue] {
        configured.filter { !claimed.contains($0.scope + ":" + $0.name) }.map { customRow($0, binaries: binaries) }
    }
    public static func resolveInstall(_ raw: NativeRPCValue) throws -> NativeRPCValue {
        guard raw.fields != nil || raw.elements != nil, let id = raw["id"].string, !id.isEmpty else { throw BackendMcpClientValue.error("Nothing to install.") }
        let scope = ["project", "local"].contains(raw["scope"].string ?? "") ? raw["scope"].string! : "user"
        let project = raw["projectPath"].string.flatMap { $0.isEmpty ? nil : $0 }
        let values = NativeRPCValue.object((raw["values"].fields ?? []).compactMap { field in field.value.string.map { .init(field.key, .string($0.trimmingCharacters(in: .whitespacesAndNewlines))) } })
        return .object([.init("id", .string(id)), .init("scope", .string(scope)), .init("projectPath", BackendMcpClientValue.optional(project)), .init("values", values)])
    }
    public static func customRuntime(_ binary: String) -> String {
        let bare = (binary.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? binary).replacingOccurrences(of: #"\.(exe|cmd|bat)$"#, with: "", options: [.regularExpression, .caseInsensitive]).lowercased()
        if ["docker", "podman", "nerdctl"].contains(bare) { return "docker" }
        if bare.range(of: #"^(uvx?|python3?|pipx|pixi|poetry|conda)$"#, options: .regularExpression) != nil { return "python" }; return "node"
    }
    public static func customRow(_ server: BackendMcpClientConfigured, binaries: [NativeRPCValue]) -> NativeRPCValue {
        let binary = customBinary(server), report = binaries.first { $0["binary"].string == binary }
        var words: String
        if server.transport != .stdio { words = "An \(server.transport == .http ? "HTTP" : "SSE") server somewhere else. Nothing starts on this machine, so there is nothing here to look for." }
        else if binary.isEmpty { words = "A command on this machine. This app could not read which binary it starts." }
        else if let report { words = report["found"].bool == true ? "\(binary) on this machine — \(report["path"].string ?? "")" : "\(binary) on this machine, and it is not there." }
        else { words = "\(binary) on this machine. It was not looked for." }
        let missing = report?["found"].bool == false
        let caveat = missing ? "\(binary) is not on this machine, so this server cannot start here. It is still in your configuration — nothing was removed — and whatever runs it will fail until that binary is installed or the command is changed." : ""
        var row = NativeRPCValue.object([])
        for (key, value) in [
            ("id", customID(server)), ("name", server.name), ("summary", "You added this one. It is not in this app’s catalogue, nothing here was measured about what it does, and no fingerprint was checked against it — it is configured because you said so."),
            ("category", "your-own"), ("homepage", ""), ("registry", ""), ("licence", ""), ("version", ""), ("runtime", customRuntime(binary)), ("runtimeBinary", binary), ("origin", "third-party"), ("cost", "unknown"), ("costNote", ""), ("logo", ""), ("command", server.command), ("state", "installed"), ("scope", server.scope), ("transport", server.transport.rawValue), ("runsWords", words), ("taken", ""), ("blocked", ""), ("caveat", caveat)
        ] { row = row.setting(key, .string(value)) }
        return row.setting("tags", .array([])).setting("inputs", .array([])).setting("envKeys", BackendMcpClientValue.strings(server.envKeys)).setting("custom", .bool(true)).setting("runtimeMissing", .bool(missing))
    }
    public static func view(catalogue: [NativeRPCValue] = BackendMcpClientCatalogue.entries, configured: [BackendMcpClientConfigured], facts: NativeRPCValue, environment: Set<String>, project: String?, binaries: [NativeRPCValue]) -> NativeRPCValue {
        let runtimes = facts["runtimes"].elements ?? []; var claimed = Set<String>()
        var rows = catalogue.map { entry -> NativeRPCValue in
            let runtime = entry["runtime"].string ?? "node", name = entry["name"].string ?? "", token = entry["token"].string ?? ""
            let report = runtimes.first { $0["id"].string == runtime }, mine = configured.first { $0.name == name }
            let isMine = mine?.command.contains(token) == true, missing = report?["found"].bool != true
            if isMine, let mine { claimed.insert(mine.scope + ":" + mine.name) }
            var state = "available", blocked = ""
            if isMine { state = "installed" }
            else if mine != nil { state = "taken"; blocked = "A server called \(name) is already configured and it is not this one. Remove it, or add this under another name from “Add your own”." }
            else if missing { state = "unavailable"; blocked = "\(BackendMcpClientCatalogue.runtimeBinary[runtime] ?? "") is not on this machine. It needs \(BackendMcpClientCatalogue.runtimeNeeds[runtime] ?? "")" }
            else if facts["writer"]["found"].bool != true { blocked = "Claude Code’s command line tool is what writes this configuration, and it was not found on this machine." }
            let inputs = (entry["inputs"].elements ?? []).map { $0.setting("inEnvironment", .bool($0["into"].string == "env" && environment.contains($0["key"].string ?? ""))) }
            return entry.removing("token").setting("runtimeBinary", .string(BackendMcpClientCatalogue.runtimeBinary[runtime] ?? ""))
                .setting("command", .string(isMine ? mine?.command ?? "" : entry["command"].string ?? ""))
                .setting("inputs", .array(inputs)).setting("state", .string(state)).setting("scope", .string(isMine ? mine?.scope ?? "" : ""))
                .setting("custom", .bool(false)).setting("transport", .string("stdio")).setting("envKeys", .array([])).setting("runsWords", .string(""))
                .setting("runtimeMissing", .bool(missing)).setting("taken", .string(state == "taken" ? mine?.command ?? "" : ""))
                .setting("blocked", .string(blocked)).setting("caveat", .string(entry["caveat"].string ?? "")).setting("logo", .string(entry["logo"].string ?? ""))
        }
        rows += customRows(configured, claimed: claimed, binaries: binaries)
        return .object([.init("rows", .array(rows)), .init("runtimes", .array(runtimes)), .init("writer", facts["writer"]), .init("environmentSource", facts["environmentSource"]), .init("projectPath", .string(project ?? ""))])
    }
}

public actor BackendMcpClientStore {
    private let writer: BackendMcpClientWriter
    private let exists: @Sendable (String) -> Bool
    private var factsInFlight: Task<(NativeRPCValue, Set<String>), Never>?
    public init(writer: BackendMcpClientWriter, exists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) { self.writer = writer; self.exists = exists }
    public func probe(_ binary: String) async -> String {
        do {
            var env = writer.configuration.environment; env["PATH"] = try await writer.loginPath()
            let answer = try await writer.run("which", [binary], env, writer.configuration.home, 5_000)
            if !answer.ok { return "" }
            return answer.stdout.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
        } catch { return "" }
    }
    public func environmentNames(keys: [String] = BackendMcpClientCatalogue.environmentKeys()) async -> (Set<String>, String) {
        do {
            var env = writer.configuration.environment; env["PATH"] = try await writer.loginPath()
            let output = try await writer.run(env["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh", ["-lic", #"printenv | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p'"#], env, writer.configuration.home, 10_000)
            guard output.ok else { return ([], "unavailable") }
            let wanted = Set(keys)
            let names = output.stdout.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil }
            return (wanted.intersection(names), "login-shell")
        } catch { return ([], "unavailable") }
    }
    public func facts() async -> (NativeRPCValue, Set<String>) {
        if let factsInFlight { return await factsInFlight.value }
        let task = Task { await self.probeFacts() }; factsInFlight = task
        let value = await task.value; factsInFlight = nil; return value
    }
    private func probeFacts() async -> (NativeRPCValue, Set<String>) {
        async let writerPath = probe("claude"), names = environmentNames()
        let runtimes = await withTaskGroup(of: (Int, NativeRPCValue).self) { group in
            let wanted = BackendMcpClientCatalogue.requiredRuntimes()
            for (index, runtime) in wanted.enumerated() { group.addTask {
                let binary = BackendMcpClientCatalogue.runtimeBinary[runtime]!, path = await self.probe(BackendMcpClientCatalogue.runtimeBinary[runtime]!)
                return (index, .object([.init("id", .string(runtime)), .init("binary", .string(binary)), .init("found", .bool(!path.isEmpty)), .init("path", .string(path)), .init("needs", .string(BackendMcpClientCatalogue.runtimeNeeds[runtime]!))]))
            } }
            var found: [(Int, NativeRPCValue)] = []; for await answer in group { found.append(answer) }; return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let (environment, source) = await names, path = await writerPath
        return (.object([.init("runtimes", .array(runtimes)), .init("writer", .object([.init("found", .bool(!path.isEmpty)), .init("path", .string(path))])), .init("environmentSource", .string(source))]), environment)
    }
    public func binaries(_ configured: [BackendMcpClientConfigured]) async -> [NativeRPCValue] {
        let wanted = BackendMcpClientStoreRules.customBinaries(configured)
        return await withTaskGroup(of: (Int, NativeRPCValue).self) { group in
            for (index, binary) in wanted.enumerated() { group.addTask {
                let path: String
                if binary.contains("/") || binary.contains("\\") { path = self.exists(binary) ? binary : "" }
                else { path = await self.probe(binary) }
                return (index, .object([.init("binary", .string(binary)), .init("found", .bool(!path.isEmpty)), .init("path", .string(path))]))
            } }
            var values: [(Int, NativeRPCValue)] = []; for await value in group { values.append(value) }; return values.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
    public func view(project: String?) async -> NativeRPCValue {
        let configured = writer.configuration.load(project: project).map(BackendMcpClientConfiguration.configured)
        async let fact = facts(), probes = binaries(configured)
        let (value, env) = await fact
        return await BackendMcpClientStoreRules.view(configured: configured, facts: value, environment: env, project: project, binaries: probes)
    }
    public func install(_ raw: NativeRPCValue) async -> NativeRPCValue {
        let request: NativeRPCValue
        do { request = try BackendMcpClientStoreRules.resolveInstall(raw) } catch { return BackendMcpClientValue.failure(error.localizedDescription) }
        let id = request["id"].string!
        guard let entry = BackendMcpClientCatalogue.entry(id) else { return BackendMcpClientValue.failure("This build has no such server.") }
        do {
            let project = try BackendMcpClientConfiguration.projectPath(request["projectPath"]), name = entry["name"].string!, runtime = entry["runtime"].string!
            let scope = request["scope"].string!
            let configured = writer.configuration.load(project: project).map(BackendMcpClientConfiguration.configured)
            if let clash = configured.first(where: { $0.name == name }), !clash.command.contains(entry["token"].string!) { return BackendMcpClientValue.failure("A server called \(name) is already configured and it is not this one. Nothing was changed.") }
            let binary = BackendMcpClientCatalogue.runtimeBinary[runtime]!
            if await probe(binary).isEmpty { return BackendMcpClientValue.failure("\(binary) is not on this machine, so this server could not start. It needs \(BackendMcpClientCatalogue.runtimeNeeds[runtime]!)") }
            let (env, _) = await environmentNames(), built = try BackendMcpClientStoreRules.buildInstall(entry, values: request["values"], available: env)
            let result = await writer.add(.object([.init("name", .string(name)), .init("scope", .string(scope)), .init("transport", .string("stdio")), .init("command", .string(built.command)), .init("url", .string("")), .init("extras", BackendMcpClientValue.strings(built.extras)), .init("projectPath", BackendMcpClientValue.optional(project))]))
            if result["ok"].bool != true { return result }
            let inherited = built.inherited.isEmpty ? "" : " \(built.inherited.joined(separator: " and ")) was left to your login shell, so nothing was written down for it."
            let written = built.extras.isEmpty ? "" : " \(built.extras.map { $0.components(separatedBy: "=")[0] }.joined(separator: " and ")) was written into your \(scope) configuration in plain text."
            return BackendMcpClientValue.result(true, "Added \(name)." + inherited + written)
        } catch { return BackendMcpClientValue.failure(error.localizedDescription) }
    }
}
