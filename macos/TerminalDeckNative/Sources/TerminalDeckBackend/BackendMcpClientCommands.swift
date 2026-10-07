import Foundation
import TerminalDeckNativeCore

public enum BackendMcpClientCommands {
    public static func tokenize(_ line: String) throws -> [String] {
        let chars = Array(line); var i = 0, current = "", started = false; var quote: Character?; var out: [String] = []
        while i < chars.count {
            let ch = chars[i]; defer { i += 1 }
            if quote == "'" { if ch == "'" { quote = nil } else { current.append(ch) }; continue }
            if quote == "\"" {
                if ch == "\\", i + 1 < chars.count, chars[i + 1] == "\"" || chars[i + 1] == "\\" { i += 1; current.append(chars[i]); continue }
                if ch == "\"" { quote = nil } else { current.append(ch) }; continue
            }
            if ch == "'" || ch == "\"" { quote = ch; started = true; continue }
            if ch == "\\", i + 1 < chars.count { i += 1; current.append(chars[i]); started = true; continue }
            if ch.isWhitespace { if started { out.append(current); current = ""; started = false }; continue }
            current.append(ch); started = true
        }
        if quote != nil { throw BackendMcpClientValue.error("That command has an unclosed quote.") }
        if started { out.append(current) }; return out
    }
    public static func quoteArgv(_ args: [String]) -> String {
        args.map { token in
            if token.isEmpty { return "''" }
            if !token.contains(where: { $0.isWhitespace || $0 == "'" || $0 == "\"" || $0 == "\\" }) { return token }
            return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
    public static func validateAdd(_ raw: NativeRPCValue) throws -> NativeRPCValue {
        guard raw.fields != nil || raw.elements != nil else { throw BackendMcpClientValue.error("Nothing to add.") }
        let name = BackendMcpClientValue.text(raw["name"])
        guard !name.isEmpty else { throw BackendMcpClientValue.error("Give the server a name.") }
        guard validName(name) else { throw BackendMcpClientValue.error("A name may use letters, numbers, dots, dashes and underscores, and must start with a letter or number.") }
        guard let scope = raw["scope"].string, McpAddScope(rawValue: scope) != nil else { throw BackendMcpClientValue.error("Choose where to save the server.") }
        guard let transport = raw["transport"].string, McpAddTransport(rawValue: transport) != nil else { throw BackendMcpClientValue.error("Choose how the server is reached.") }
        let command = BackendMcpClientValue.text(raw["command"]), url = BackendMcpClientValue.text(raw["url"])
        if transport == "stdio" && command.isEmpty { throw BackendMcpClientValue.error("Give the command that starts the server.") }
        if transport != "stdio" && url.isEmpty { throw BackendMcpClientValue.error("Give the server’s URL.") }
        let extras = (raw["extras"].elements ?? []).map(BackendMcpClientValue.text).filter { !$0.isEmpty }
        for extra in extras {
            if transport == "stdio" && !extra.contains("=") { throw BackendMcpClientValue.error("Environment variables are written KEY=value — “\(extra)” is not.") }
            if transport != "stdio" && !extra.contains(":") { throw BackendMcpClientValue.error("Headers are written Name: value — “\(extra)” is not.") }
        }
        let project = raw["projectPath"].string.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0).standardizedFileURL.path : nil }
        if scope != "user" && project == nil { throw BackendMcpClientValue.error("Open a project first — only a user-scope server can be added without one.") }
        return .object([.init("name", .string(name)), .init("scope", .string(scope)), .init("transport", .string(transport)), .init("command", .string(command)), .init("url", .string(url)), .init("extras", BackendMcpClientValue.strings(extras)), .init("projectPath", BackendMcpClientValue.optional(project))])
    }
    public static func validName(_ name: String) -> Bool { name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil }
    public static func addArguments(_ request: NativeRPCValue) throws -> [String] {
        let transport = request["transport"].string ?? "stdio"
        var args = ["mcp", "add", "--scope", request["scope"].string ?? "user"]
        if transport != "stdio" { args += ["--transport", transport] }; args.append(request["name"].string ?? "")
        if transport == "stdio" {
            let argv = try tokenize(request["command"].string ?? "")
            if argv.isEmpty { throw BackendMcpClientValue.error("Give the command that starts the server.") }
            for extra in (request["extras"].elements ?? []).compactMap(\.string) { args += ["-e", extra] }; args += ["--"] + argv
        } else {
            args.append(request["url"].string ?? "")
            for extra in (request["extras"].elements ?? []).compactMap(\.string) { args += ["-H", extra] }
        }
        return args
    }
    public static func validateRemove(_ raw: NativeRPCValue) throws -> NativeRPCValue {
        guard raw.fields != nil || raw.elements != nil else { throw BackendMcpClientValue.error("Nothing to remove.") }
        let name = BackendMcpClientValue.text(raw["name"])
        guard !name.isEmpty else { throw BackendMcpClientValue.error("Name the server to remove.") }
        guard validName(name) else { throw BackendMcpClientValue.error("That is not a server name this app wrote.") }
        guard let scope = raw["scope"].string, McpAddScope(rawValue: scope) != nil else { throw BackendMcpClientValue.error("Say which scope the server is in.") }
        let project = raw["projectPath"].string.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0).standardizedFileURL.path : nil }
        if scope != "user" && project == nil { throw BackendMcpClientValue.error("Open the project this server belongs to first.") }
        return .object([.init("name", .string(name)), .init("scope", .string(scope)), .init("projectPath", BackendMcpClientValue.optional(project))])
    }
    public static func mergeEnvironment(_ typed: [String], saved: NativeRPCValue) throws -> [String] {
        try typed.compactMap { entry in
            let at = entry.firstIndex(of: "=")
            let key = (at.map { String(entry[..<$0]) } ?? entry).trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { return nil }
            let value = at.map { String(entry[entry.index(after: $0)...]) } ?? ""
            if !value.isEmpty { return key + "=" + value }
            guard let kept = saved[key].string, !kept.isEmpty else { throw BackendMcpClientValue.error("\(key) has no saved value to keep. Give it one, or delete the line to drop the variable.") }
            return key + "=" + kept
        }
    }
}

/// Reuses the fleet's actual process executor and provider login PATH. The
/// injected run closure is also the deterministic test seam; construction does no IO.
public struct BackendMcpClientWriter: Sendable {
    public typealias Run = @Sendable (String, [String], [String: String], String, Int) async throws -> BackendGitOutcome
    public let configuration: BackendMcpClientConfiguration
    public let loginPath: @Sendable () async throws -> String
    public let run: Run
    public init(configuration: BackendMcpClientConfiguration, loginPath: @escaping @Sendable () async throws -> String, run: @escaping Run) { self.configuration = configuration; self.loginPath = loginPath; self.run = run }
    public init(configuration: BackendMcpClientConfiguration, providers: BackendNativeProviders, executor: BackendDevProcessExecutor = .init()) {
        self.init(configuration: configuration, loginPath: { try await providers.loginPath() }, run: { command, args, env, cwd, timeout in
            guard let plan = Self.executionPlan(command: command, arguments: args, environment: env, cwd: cwd) else {
                return BackendGitOutcome(ok: false, stdout: "", stderr: "", missing: true, exitCode: 127, timedOut: false)
            }
            return try await executor.run(command: plan.command, arguments: plan.arguments, environment: plan.environment, cwd: plan.cwd, timeoutMilliseconds: timeout)
        })
    }
    public static func executionPlan(command: String, arguments: [String], environment: [String: String], cwd: String) -> BackendGitExecutionPlan? {
        guard let executable = BackendNativeProviders.lookup(command, path: environment["PATH"] ?? "") else { return nil }
        return BackendGitExecutionPlan(command: executable, arguments: arguments, environment: environment, cwd: cwd)
    }
    public func add(_ raw: NativeRPCValue) async -> NativeRPCValue {
        do { let request = try BackendMcpClientCommands.validateAdd(raw); return await execute(try BackendMcpClientCommands.addArguments(request), project: request["projectPath"].string, quiet: "Added \(request["name"].string!).") }
        catch { return BackendMcpClientValue.failure(error.localizedDescription) }
    }
    public func remove(_ raw: NativeRPCValue) async -> NativeRPCValue {
        do { let request = try BackendMcpClientCommands.validateRemove(raw); return await execute(["mcp", "remove", "--scope", request["scope"].string!, request["name"].string!], project: request["projectPath"].string, quiet: "Removed \(request["name"].string!).") }
        catch { return BackendMcpClientValue.failure(error.localizedDescription) }
    }
    private func execute(_ args: [String], project: String?, quiet: String) async -> NativeRPCValue {
        do {
            let path = try await loginPath(); var env = configuration.environment; env["PATH"] = path
            let output = try await run("claude", args, env, project ?? configuration.home, 30_000)
            if output.missing { return BackendMcpClientValue.failure("Claude Code’s command line tool could not be found, and it is what writes this configuration. Install it, then try again.") }
            let said = (output.ok ? [output.stdout, output.stderr] : [output.stderr, output.stdout]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
            return BackendMcpClientValue.result(output.ok, said.isEmpty ? output.ok ? quiet : output.timedOut ? "Command timed out after 30000ms" : "Command failed" : said)
        } catch { return BackendMcpClientValue.failure(error.localizedDescription) }
    }
    public func edit(_ raw: NativeRPCValue) async -> NativeRPCValue {
        do {
            guard raw.fields != nil || raw.elements != nil else { throw BackendMcpClientValue.error("Nothing to change.") }
            let name = BackendMcpClientValue.text(raw["name"])
            guard !name.isEmpty else { throw BackendMcpClientValue.error("Name the server to change.") }
            guard let scope = raw["scope"].string, McpAddScope(rawValue: scope) != nil else { throw BackendMcpClientValue.error("Say which scope the server is in.") }
            var target = try BackendMcpClientCommands.validateAdd(raw["next"])
            let project = target["projectPath"].string
            if scope != "user" && project == nil { throw BackendMcpClientValue.error("Open the project this server belongs to first.") }
            guard let existing = configuration.load(project: project).first(where: { $0["name"].string == name && $0["scope"].string == scope }) else { return BackendMcpClientValue.failure("\(name) is not in your configuration any more. Nothing was changed.") }
            if target["transport"].string == "stdio" {
                target = target.setting("extras", BackendMcpClientValue.strings(try BackendMcpClientCommands.mergeEnvironment((target["extras"].elements ?? []).compactMap(\.string), saved: existing["env"])))
            }
            // Ensure a broken command cannot delete the original first.
            _ = try BackendMcpClientCommands.addArguments(target)
            let gone = await remove(.object([.init("name", .string(name)), .init("scope", .string(scope)), .init("projectPath", BackendMcpClientValue.optional(project))]))
            if gone["ok"].bool != true { return BackendMcpClientValue.failure("\(name) was not changed. \(gone["message"].string ?? "")") }
            let written = await add(target), newName = target["name"].string!, newScope = target["scope"].string!
            if written["ok"].bool == true { return BackendMcpClientValue.result(true, "\(newName) was changed." + (name == newName ? "" : " It was called \(name) and is now \(newName).") + (scope == newScope ? "" : " It moved from \(scope) to \(newScope).")) }
            let configured = BackendMcpClientConfiguration.configured(existing)
            let restore = NativeRPCValue.object([.init("name", .string(name)), .init("scope", .string(scope)), .init("transport", .string(configured.transport.rawValue)), .init("command", .string(configured.transport == .stdio ? configured.command : "")), .init("url", .string(configured.transport == .stdio ? "" : configured.command)), .init("extras", BackendMcpClientValue.strings((existing["env"].fields ?? []).map { $0.key + "=" + ($0.value.string ?? "") })), .init("projectPath", BackendMcpClientValue.optional(project))])
            let back = await add(restore)
            return BackendMcpClientValue.failure("\(newName) was not saved. \(written["message"].string ?? "") " + (back["ok"].bool == true ? "\(name) has been put back exactly as it was." : "Putting \(name) back also failed — \(back["message"].string ?? "") — so it is not in your configuration right now."))
        } catch { return BackendMcpClientValue.failure(error.localizedDescription) }
    }
}
