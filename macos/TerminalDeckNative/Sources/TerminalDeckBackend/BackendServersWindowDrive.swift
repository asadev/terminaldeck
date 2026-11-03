import Foundation
import TerminalDeckNativeCore

public struct BackendServersWindowScouted: Sendable, Equatable {
    public var dir: String, shell: String, curl: String; public var openers: [String: String]
}
public enum BackendServersWindowDriveScripts {
    public static let mcpFlag = "--mcp-config", scratchPrefix = "/tmp/td-drive-", scoutMark = "TD_SCOUTED"
    public static func honoursMcpConfig(_ help: String) -> Bool { help.contains(mcpFlag) }
    public static func subcommandsFrom(_ help: String) -> [String] {
        let lines = help.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { BackendServersSetupWire.trim($0).range(of: #"^commands:\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil }) else { return [] }
        var result: Set<String> = []
        for line in lines.dropFirst(start + 1) {
            if !BackendServersSetupWire.trim(line).isEmpty, line.first?.isWhitespace != true { break }
            guard let words = BackendServersSetupWire.capture(#"^\s{1,4}([a-z][a-z0-9|-]*)(?:\s|$)"#, line) else { continue }
            for word in words.components(separatedBy: "|") where word.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil { result.insert(word) }
        }
        return result.sorted()
    }
    public static func takesAnExportLine(_ shell: String) -> Bool {
        let name = shell.components(separatedBy: "/").last ?? ""
        return name.isEmpty || ["sh", "bash", "zsh", "ksh", "ksh93", "mksh", "dash", "ash", "busybox"].contains(name)
    }
    public static let scoutScript = #"""
    umask 077
    d=$(mktemp -d /tmp/td-drive-XXXXXX) || exit 1
    chmod 700 "$d" || exit 1
    mkdir "$d/bin" || exit 1
    found() {
      v=$(command -v "$1" 2>/dev/null) || v=
      case "$v" in /*) ;; *) v= ;; esac
      case "$v" in *"'"*) v= ;; esac
      printf '%s\n' "$v"
    }
    printf '%s\n' 'TD_SCOUTED' "$d" "${SHELL:-}"
    found curl
    found open
    found xdg-open
    found sensible-browser
    """#
    public static func readScouted(_ stdout: String) -> BackendServersWindowScouted {
        let lines = stdout.components(separatedBy: "\n").map(BackendServersSetupWire.trim)
        let at = lines.lastIndex(of: scoutMark)
        func take(_ offset: Int) -> String { guard let at, at + offset < lines.count else { return "" }; return lines[at + offset] }
        var openers: [String: String] = [:]
        for (index, name) in BackendServersWindowBelong.openerNames.enumerated() { openers[name] = take(4 + index) }
        return .init(dir: take(1), shell: take(2), curl: take(3), openers: openers)
    }
    public static func armScript(dir: String, files: [BackendServersWindowScratchFile]) throws -> String {
        var lines = ["d=" + BackendServersSetupWire.quote(dir), #"case "$d" in /tmp/td-drive-??????) ;; *) exit 1 ;; esac"#, "umask 077"]
        var folders: Set<String> = []
        for file in files {
            guard file.path.range(of: #"^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$"#, options: .regularExpression) != nil else { throw BackendServersSetupFailure.invalid("window-drive: refusing to write \(file.path)") }
            if let slash = file.path.lastIndex(of: "/") { folders.insert(String(file.path[..<slash])) }
        }
        for folder in folders.sorted() { lines.append(#"mkdir -p "$d/\#(folder)" || exit 1"#) }
        for (index, file) in files.enumerated() {
            let tag = "TD_FILE_\(index)", body = file.body.replacingOccurrences(of: #"\n+$"#, with: "", options: .regularExpression)
            guard !body.components(separatedBy: "\n").contains(tag) else { throw BackendServersSetupFailure.invalid("window-drive: \(file.path) contains \(tag)") }
            lines += [#"cat > "$d/\#(file.path)" <<'\#(tag)' || exit 1"#, body, tag]
            if file.executable { lines.append(#"chmod 700 "$d/\#(file.path)" || exit 1"#) }
        }
        return (lines + ["exit 0"]).joined(separator: "\n")
    }
    public static func wrapperScript(real: String, subcommands: [String], config: String, settings: String?) -> String {
        let safe = subcommands.filter { $0.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil }
        var lines = ["#!/bin/sh", "# Written by this app for this terminal only, and removed when it closes.",
                     "# REAL is an absolute literal, never a PATH lookup into this wrapper.", "REAL=" + BackendServersSetupWire.quote(real), "CONFIG=" + BackendServersSetupWire.quote(config)]
        if let settings { lines.append("SETTINGS=" + BackendServersSetupWire.quote(settings)) }
        lines += ["", #"case "${1:-}" in"#]
        if !safe.isEmpty { lines.append("  " + safe.joined(separator: "|") + #") exec "$REAL" "$@" ;;"#) }
        lines += ["  *) ;;", "esac", ""]
        if settings != nil { lines += [#"if [ -f "$SETTINGS" ]; then"#, #"  exec "$REAL" --mcp-config "$CONFIG" --settings "$SETTINGS" "$@""#, "fi"] }
        lines.append(#"exec "$REAL" --mcp-config "$CONFIG" "$@""#)
        return lines.joined(separator: "\n")
    }
    public static func pathLine(_ dir: String) -> String {
        "export PATH=" + BackendServersSetupWire.quote(dir + "/bin") + ":$PATH # so what runs here can reach the browser windows you attach to this terminal\n"
    }
    public static func disarmScript(_ dir: String) -> String {
        ["p=" + BackendServersSetupWire.quote(dir), #"case "$p" in /tmp/td-drive-??????) ;; *) exit 1 ;; esac"#, #"rm -rf "$p""#, "exit 0"].joined(separator: "\n")
    }
}

public enum BackendServersWindowReachKind: String, Sendable, Hashable { case control, hooks }
public struct BackendServersWindowBelonging: Sendable, Equatable {
    public let map: String?; public let opensInApp: Bool
    public var wireValue: NativeRPCValue { .object([.init("map", BackendServersSetupWire.text(map)), .init("opensInApp", .bool(opensInApp))]) }
}
public struct BackendServersWindowRemoteContext: Sendable {
    public let pages: [String: String]; public let mapFor: @Sendable (String) -> String
    public init(pages: [String: String], mapFor: @escaping @Sendable (String) -> String) { self.pages = pages; self.mapFor = mapFor }
}
public enum BackendServersWindowArmOutcome: Sendable, Equatable {
    case armed(line: String), refused(why: String)
    public var wireValue: NativeRPCValue {
        switch self { case .armed(let line): .object([.init("ok", .bool(true)), .init("line", .string(line))]); case .refused(let why): .object([.init("ok", .bool(false)), .init("why", .string(why))]) }
    }
}
public struct BackendServersWindowDriveDependencies: Sendable {
    public let allowed: @Sendable (String) -> Bool
    public let claudeOn: @Sendable (String) async throws -> BackendServersAgentFact?
    public let run: @Sendable (String, [String]) async throws -> BackendServersRunResult
    public let runScript: @Sendable (String, String) async throws -> BackendServersRunResult
    public let reach: @Sendable (String, BackendServersWindowReachKind) async -> BackendServersWindowReachResult
    public let letGo: @Sendable (String, BackendServersWindowReachKind) async -> Void
    public let mint: @Sendable (@escaping @Sendable () async -> Bool) async throws -> BackendDeckToolsSessionsPreparedElsewhere?
    public let hookEndpoint: @Sendable () -> String?
    public let remoteContext: @Sendable (String, Bool) -> BackendServersWindowRemoteContext?
    public init(allowed: @escaping @Sendable (String) -> Bool,
                claudeOn: @escaping @Sendable (String) async throws -> BackendServersAgentFact?,
                run: @escaping @Sendable (String, [String]) async throws -> BackendServersRunResult,
                runScript: @escaping @Sendable (String, String) async throws -> BackendServersRunResult,
                reach: @escaping @Sendable (String, BackendServersWindowReachKind) async -> BackendServersWindowReachResult,
                letGo: @escaping @Sendable (String, BackendServersWindowReachKind) async -> Void,
                mint: @escaping @Sendable (@escaping @Sendable () async -> Bool) async throws -> BackendDeckToolsSessionsPreparedElsewhere?,
                hookEndpoint: @escaping @Sendable () -> String? = { nil },
                remoteContext: @escaping @Sendable (String, Bool) -> BackendServersWindowRemoteContext? = { _, _ in nil }) {
        self.allowed = allowed; self.claudeOn = claudeOn; self.run = run; self.runScript = runScript; self.reach = reach
        self.letGo = letGo; self.mint = mint; self.hookEndpoint = hookEndpoint; self.remoteContext = remoteContext
    }
}
public enum BackendServersWindowDriveReasons {
    public static let notAllowed = "acting on browser windows here has been turned off for this server. The switch is under Advanced on its page — it is on for every server you add unless somebody unticks it."
    public static let agent = "this app can only add its browser verbs to Claude Code, and this server has no `claude` this sign-in can run. Codex and Gemini have no per-run setting that could be added to a command line somebody types themselves."
    public static let flag = "the `claude` on this server is too old to take the setting this needs (`--mcp-config`). Updating it on that machine is the only way in."
    public static let endpoint = "this app’s control endpoint is not running here yet."
    public static let shell = "this app can only add its browser verbs to a terminal running a Bourne shell — `sh`, `bash`, `zsh` and their relatives. The sign-in on this server lands in a shell that spells things differently, and a line written the wrong way would print an error into the terminal rather than do anything."
}
public actor BackendServersWindowDrives {
    private struct Armed: Sendable {
        let serverId: String, dir: String; let minted: BackendDeckToolsSessionsPreparedElsewhere
        let hooks: Bool; let belonging: BackendServersWindowBelonging?
    }
    private let deps: BackendServersWindowDriveDependencies
    private var armed: [String: Armed] = [:]; private var withheld: [String: String] = [:]
    private var pending: [String: UUID] = [:]
    public init(_ dependencies: BackendServersWindowDriveDependencies) { deps = dependencies }
    private func refuse(_ shellId: String, _ why: String) -> BackendServersWindowArmOutcome { withheld[shellId] = why; return .refused(why: why) }
    public func arm(_ serverId: String, shellId: String) async -> BackendServersWindowArmOutcome {
        await disarm(shellId)
        guard deps.allowed(serverId) else { return refuse(shellId, BackendServersWindowDriveReasons.notAllowed) }
        let ticket = UUID(); pending[shellId] = ticket
        defer { if pending[shellId] == ticket { pending[shellId] = nil } }
        guard let claude = try? await deps.claudeOn(serverId), !claude.path.isEmpty else { return refuse(shellId, BackendServersWindowDriveReasons.agent) }
        let help: String
        do { let answer = try await deps.run(serverId, [claude.path, "--help"]); help = answer.stdout + "\n" + answer.stderr }
        catch { return refuse(shellId, BackendServersWindowDriveReasons.agent) }
        guard BackendServersWindowDriveScripts.honoursMcpConfig(help) else { return refuse(shellId, BackendServersWindowDriveReasons.flag) }
        let allowed = deps.allowed
        let minted: BackendDeckToolsSessionsPreparedElsewhere
        do { guard let token = try await deps.mint({ allowed(serverId) }) else { return refuse(shellId, BackendServersWindowDriveReasons.endpoint) }; minted = token }
        catch { return refuse(shellId, BackendServersWindowDriveReasons.endpoint) }
        let control: BackendServersWindowReach
        switch await deps.reach(serverId, .control) {
        case .opened(let reach): control = reach
        case .refused(let message): await minted.drop(); return refuse(shellId, message)
        }
        let scouted: BackendServersWindowScouted
        do { scouted = BackendServersWindowDriveScripts.readScouted(try await deps.runScript(serverId, BackendServersWindowDriveScripts.scoutScript).stdout) }
        catch { await minted.drop(); await deps.letGo(serverId, .control); return refuse(shellId, "this app could not make a folder of its own on that server.") }
        let dir = scouted.dir
        var holdingHooks = false
        func undo(_ why: String) async -> BackendServersWindowArmOutcome {
            await minted.drop(); await deps.letGo(serverId, .control)
            if holdingHooks { await deps.letGo(serverId, .hooks) }
            if dir.hasPrefix(BackendServersWindowDriveScripts.scratchPrefix) { _ = try? await deps.runScript(serverId, BackendServersWindowDriveScripts.disarmScript(dir)) }
            return refuse(shellId, why)
        }
        guard dir.hasPrefix(BackendServersWindowDriveScripts.scratchPrefix) else { return await undo("that server did not answer with a folder this app could use.") }
        guard BackendServersWindowDriveScripts.takesAnExportLine(scouted.shell) else { return await undo(BackendServersWindowDriveReasons.shell) }
        var belonging: BackendServersWindowBelonging?, settingsPath: String?, extras: [BackendServersWindowScratchFile] = []
        if !scouted.curl.isEmpty, let endpoint = deps.hookEndpoint(), case .opened(let hooks) = await deps.reach(serverId, .hooks) {
            holdingHooks = true
            let withHooks = BackendServersWindowBelong.honoursSettings(help), remote = withHooks ? deps.remoteContext(serverId, true) : nil
            extras = BackendServersWindowBelong.files(.init(dir: dir, curl: scouted.curl, port: hooks.port, sessionId: shellId, token: endpoint, openers: scouted.openers, pages: remote?.pages, hooks: withHooks))
            if extras.isEmpty { await deps.letGo(serverId, .hooks); holdingHooks = false }
            else {
                if withHooks { settingsPath = dir + "/" + BackendServersWindowBelong.settingsFileName }
                belonging = .init(map: remote?.mapFor(dir + "/" + BackendServersWindowBelong.contextSubdir), opensInApp: true)
            }
        }
        guard pending[shellId] == ticket, deps.allowed(serverId) else { return await undo(BackendServersWindowDriveReasons.notAllowed) }
        do {
            let config = dir + "/deck-control.json"
            let files: [BackendServersWindowScratchFile] = [.init(path: "deck-control.json", body: try minted.configFor("http://127.0.0.1:\(control.port)/mcp"))] + extras +
                [.init(path: "bin/claude", body: BackendServersWindowDriveScripts.wrapperScript(real: claude.path, subcommands: BackendServersWindowDriveScripts.subcommandsFrom(help), config: config, settings: settingsPath), executable: true)]
            let result = try await deps.runScript(serverId, BackendServersWindowDriveScripts.armScript(dir: dir, files: files))
            guard result.code == 0 else { return await undo("this app could not put the files it needs on that server.") }
            guard pending[shellId] == ticket, deps.allowed(serverId) else { return await undo(BackendServersWindowDriveReasons.notAllowed) }
            try await minted.started(shellId, serverId)
        } catch { return await undo("this app could not put the files it needs on that server.") }
        guard pending[shellId] == ticket, deps.allowed(serverId) else { return await undo(BackendServersWindowDriveReasons.notAllowed) }
        armed[shellId] = .init(serverId: serverId, dir: dir, minted: minted, hooks: holdingHooks, belonging: belonging); withheld[shellId] = nil
        return .armed(line: BackendServersWindowDriveScripts.pathLine(dir))
    }
    public func belonging(_ shellId: String) -> BackendServersWindowBelonging? { armed[shellId]?.belonging }
    public func disarm(_ shellId: String) async {
        pending[shellId] = nil; withheld[shellId] = nil
        guard let entry = armed.removeValue(forKey: shellId) else { return }
        await entry.minted.drop(); await deps.letGo(entry.serverId, .control)
        if entry.hooks { await deps.letGo(entry.serverId, .hooks) }
        _ = try? await deps.runScript(entry.serverId, BackendServersWindowDriveScripts.disarmScript(entry.dir))
    }
    public func revoke(_ serverId: String) async {
        for (id, entry) in armed where entry.serverId == serverId { await disarm(id); withheld[id] = BackendServersWindowDriveReasons.notAllowed }
    }
    public func whyNot(_ shellId: String) -> String? { withheld[shellId] }
    public func stop() async { for id in Array(pending.keys) { pending[id] = nil }; for id in Array(armed.keys) { await disarm(id) }; withheld.removeAll() }
}
