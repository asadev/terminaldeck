import Foundation
import TerminalDeckNativeCore

public enum BackendServersSetupStep: String, Codable, Sendable { case idle, installing, installed; case signingIn = "signing-in"; case done, failed }
public struct BackendServersSetupState: Codable, Equatable, Sendable {
    public var serverId: String; public var agentId: BackendServersAgentID; public var step: BackendServersSetupStep
    public var line: String; public var detail: String; public var byHand: Bool; public var code: String
    public var weInstalled: Bool; public var version: String?
    public init(serverId: String, agentId: BackendServersAgentID, step: BackendServersSetupStep = .idle,
                line: String = "", detail: String = "", byHand: Bool = false, code: String = "", weInstalled: Bool = false, version: String? = nil) {
        self.serverId = serverId; self.agentId = agentId; self.step = step; self.line = line; self.detail = detail
        self.byHand = byHand; self.code = code; self.weInstalled = weInstalled; self.version = version
    }
    public var wireValue: NativeRPCValue { .object([
        .init("serverId", .string(serverId)), .init("agentId", .string(agentId.rawValue)), .init("step", .string(step.rawValue)),
        .init("line", .string(line)), .init("detail", .string(detail)), .init("byHand", .bool(byHand)), .init("code", .string(code)),
        .init("weInstalled", .bool(weInstalled)), .init("version", BackendServersSetupWire.text(version))
    ]) }
}

public enum BackendServersSetupRules {
    public static let setupAgents: [BackendServersAgentID] = [.claude, .codex, .gemini]
    public static let removeLabel = "Remove what was installed"
    public static let done = "__terminaldeck_setup"
    public static let installCeilingMilliseconds = 10 * 60 * 1000
    public static let deviceCeilingMilliseconds = 16 * 60 * 1000
    public static func label(_ id: BackendServersAgentID) -> String { switch id { case .claude: "Claude Code"; case .codex: "Codex CLI"; case .gemini: "Gemini CLI" } }
    public static func deviceURL(_ id: BackendServersAgentID) -> String? { id == .codex ? "https://auth.openai.com/codex/device" : nil }
    public static func whyNotInstall(_ id: BackendServersAgentID, room: BackendServersAgentInstallRoom) -> String? {
        if id == .claude {
            if room.downloader.isEmpty { return "This server has no way to download files. Someone will need to add one first." }
            if let memory = room.memoryAvailableKb, memory < 512 * 1024 {
                return "This server has \(Int(floor(memory / 1024 + 0.5))) MB of memory free and the download needs about 512 MB. It would be stopped part-way."
            }
        } else if room.npm.isEmpty { return "This server has no npm, which is what installs \(label(id)). Someone will need to add Node first." }
        let needed = id == .claude ? 350 : id == .codex ? 330 : 130
        if let free = room.homeFreeKb, free < Double(needed * 1024) {
            return "There is \(Int(floor(free / 1024 + 0.5))) MB free in your home folder on this server and this needs about \(needed) MB."
        }
        return nil
    }
    public static func installCommand(_ id: BackendServersAgentID, room: BackendServersAgentInstallRoom) -> String? {
        switch id {
        case .claude:
            if room.downloader == "curl" { return "curl -fsSL https://claude.ai/install.sh | bash" }
            if room.downloader == "wget" { return "wget -qO- https://claude.ai/install.sh | bash" }; return nil
        case .codex: return room.npm.isEmpty ? nil : #"npm install -g --prefix "$HOME/.local" @openai/codex"#
        case .gemini: return room.npm.isEmpty ? nil : #"npm install -g --prefix "$HOME/.local" @google/gemini-cli"#
        }
    }
    public static func installConsequence(_ id: BackendServersAgentID, serverName: String) -> String {
        switch id {
        case .claude: return "This downloads Claude Code (about 320 MB) into your own home folder on \(serverName). It takes about a minute. It does not need administrator access and does not change anything else on the server. You can remove it again from here."
        case .codex: return "This installs Codex CLI (about 300 MB) into your own home folder on \(serverName), using the npm that is already there. It takes a few seconds. It does not need administrator access and does not change anything else on the server. You can remove it again from here."
        case .gemini: return "This installs Gemini CLI (about 100 MB) into your own home folder on \(serverName), using the npm that is already there. It takes a few seconds. It does not need administrator access and does not change anything else on the server. You can remove it again from here."
        }
    }
    public static func whyNoSignOut(_ id: BackendServersAgentID) -> String? {
        id == .gemini ? "Gemini CLI has no way to be signed out from outside its own screen, so this has to be done in the terminal here." : nil
    }
    public static func signOutConsequence(_ id: BackendServersAgentID, serverName: String) -> String {
        "This asks \(label(id)) on \(serverName) to forget the login it is holding. Nothing else on the server changes and it stays installed. You can sign in again from this row."
    }
    public static func authPortOf(_ address: String) -> Int? {
        guard let encoded = BackendServersSetupWire.capture(#"[?&]redirect_uri=([^&\s]+)"#, address),
              let raw = encoded.removingPercentEncoding, let url = URLComponents(string: raw),
              ["localhost", "127.0.0.1"].contains(url.host ?? ""), let port = url.port, (1...65_535).contains(port) else { return nil }
        return port
    }
    public static func oneTimeCodeIn(_ output: String, deviceURL: String?) -> String? {
        let plain = output.replacingOccurrences(of: #"\x{001B}\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        let anchor = plain.range(of: #"one[- ]?time code"#, options: [.regularExpression, .caseInsensitive])
        guard anchor != nil || (deviceURL.map { !$0.isEmpty && plain.contains($0) } ?? false) else { return nil }
        let tail = anchor.map { String(plain[$0.lowerBound...]) } ?? plain
        return tail.components(separatedBy: .newlines).map(BackendServersSetupWire.trim).first {
            $0.range(of: #"^[A-Z0-9]{3,8}-[A-Z0-9]{3,8}$"#, options: .regularExpression) != nil
        }
    }
    public static func agentOn(_ facts: BackendServersFacts, id: BackendServersAgentID) -> BackendServersAgentFact? {
        facts.agents.value?.first { $0.id == id }
    }
    public static func accountLine(_ id: BackendServersAgentID, agent: BackendServersAgentFact) -> String {
        let label = "\(label(id)) \(agent.version)"
        return agent.account.map { "\(label), signed in as \($0)." } ?? "\(label), signed in."
    }
    public static let scratchScript = #"""
    d=$(mktemp -d /tmp/td-signin-XXXXXX) || exit 1
    chmod 700 "$d" || exit 1
    echo '#!/bin/sh' > "$d/open"
    echo 'umask 077' >> "$d/open"
    echo 'echo "$1" > "$0.url"' >> "$d/open"
    echo 'exit 0' >> "$d/open"
    chmod 700 "$d/open" || exit 1
    printf %s "$d"
    """#
    public static func waitScript(_ dir: String) -> String {
        #"""
        f=\#(BackendServersSetupWire.quote(dir + "/open.url"))
        end=$(( $(date +%s) + 20 ))
        while [ "$(date +%s)" -lt "$end" ]; do
          if [ -s "$f" ]; then cat "$f"; exit 0; fi
          sleep 0.2 2>/dev/null || sleep 1
        done
        exit 1
        """#
    }
    public static func removeScript(_ path: String, id: BackendServersAgentID) -> String {
        let leaves = id == .claude ? [".local/share/claude/versions"] :
            id == .codex ? [".local/lib/node_modules/@openai/codex"] : [".local/lib/node_modules/@google/gemini-cli"]
        return (["p=" + BackendServersSetupWire.quote(path), #"case "$p" in "$HOME"/*) ;; *) echo "not ours to remove" >&2; exit 1 ;; esac"#,
                 #"rm -f "$p""#] + leaves.map { #"rm -rf "$HOME/\#($0)""# } + ["exit 0"]).joined(separator: "\n")
    }
    public static func findScript(_ id: BackendServersAgentID) -> String {
        let binary = id.rawValue
        return #"""
        W="$PATH"
        for d in "$HOME/.local/bin" "$HOME/bin" "$HOME/.claude/local" "$HOME/.npm-global/bin" "$HOME/.volta/bin" "$HOME/.bun/bin" "$HOME/.asdf/shims" "$HOME/.local/share/mise/shims" /usr/local/bin /opt/homebrew/bin /snap/bin; do
          [ -d "$d" ] && W="$W:$d"
        done
        ND="$NVM_DIR"
        [ -n "$ND" ] || ND="$HOME/.nvm"
        for d in "$ND"/versions/node/*/bin; do [ -d "$d" ] && W="$W:$d"; done
        LS="$SHELL"
        [ -n "$LS" ] || LS=/bin/sh
        LOGIN=$("$LS" -lc 'command -v \#(binary); \#(BackendServersAgentSignin.agentEnvProbe)' 2>/dev/null)
        \#(BackendServersAgentSignin.readAgentEnv(from: "LOGIN", codexHome: "CXH", geminiEnv: "GENV"))
        b=$(PATH="$W" command -v \#(binary) 2>/dev/null)
        [ -n "$b" ] || b=$(printf '%s\n' "$LOGIN" | grep '/\#(binary)$' | head -n 1)
        [ -n "$b" ] || exit 1
        v=$("$b" --version 2>/dev/null | head -n 1 | awk '\#(BackendServersAgentSignin.agentVersionAWK)')
        i=unknown
        e=
        \#(BackendServersAgentSignin.signInSnippet(id, binary: "b", state: "i", account: "e", codexHome: "CXH", geminiEnv: "GENV"))
        printf '%s\t%s\t%s\t%s\n' "$b" "$v" "$i" "$e"
        """#
    }
}

public struct BackendServersSetupDependencies: Sendable {
    public var runScript: @Sendable (String, String) async throws -> BackendServersRunResult
    public var openTunnel: (@Sendable (String, Int) async -> BackendServersSetupTunnelResult)?
    public var openInBrowser: (@Sendable (String) async throws -> Void)?
    public var broadcast: @Sendable (BackendServersSetupState) -> Void
    public init(runScript: @escaping @Sendable (String, String) async throws -> BackendServersRunResult,
                openTunnel: (@Sendable (String, Int) async -> BackendServersSetupTunnelResult)? = nil,
                openInBrowser: (@Sendable (String) async throws -> Void)? = nil,
                broadcast: @escaping @Sendable (BackendServersSetupState) -> Void = { _ in }) {
        self.runScript = runScript; self.openTunnel = openTunnel; self.openInBrowser = openInBrowser; self.broadcast = broadcast
    }
}

public actor BackendServersSetups {
    private let deps: BackendServersSetupDependencies
    private var attempts: [String: BackendServersSetupAttempt] = [:]
    private var states: [String: BackendServersSetupState] = [:]
    public init(_ dependencies: BackendServersSetupDependencies) { deps = dependencies }
    public func stateOf(_ serverId: String, agentId: BackendServersAgentID) -> BackendServersSetupState {
        states[serverId + "\t" + agentId.rawValue] ?? .init(serverId: serverId, agentId: agentId)
    }
    @discardableResult private func say(_ next: BackendServersSetupState) -> BackendServersSetupState {
        states[next.serverId + "\t" + next.agentId.rawValue] = next; deps.broadcast(next); return next
    }
    public func install(_ serverId: String, agentId: BackendServersAgentID, shell: any BackendServersShell,
                        room: BackendServersAgentInstallRoom, serverName: String) async -> BackendServersSetupState {
        let label = BackendServersSetupRules.label(agentId)
        if let refusal = BackendServersSetupRules.whyNotInstall(agentId, room: room) {
            return say(.init(serverId: serverId, agentId: agentId, step: .failed, line: refusal))
        }
        guard let command = BackendServersSetupRules.installCommand(agentId, room: room) else {
            return say(.init(serverId: serverId, agentId: agentId, step: .failed, line: "This server cannot install \(label)."))
        }
        await cancel(serverId)
        let attempt = BackendServersSetupAttempt(serverId: serverId, agentId: agentId); attempts[serverId] = attempt
        say(.init(serverId: serverId, agentId: agentId, step: .installing, line: "Installing \(label) on \(serverName)."))
        let code = await typeAndWait(shell, command + "; echo \(BackendServersSetupRules.done) $?", attempt: attempt,
                                     ceiling: BackendServersSetupRules.installCeilingMilliseconds)
        guard !attempt.cancelled else { return stateOf(serverId, agentId: agentId) }
        if code != 0 {
            await finish(serverId, attempt: attempt, interrupt: false)
            return say(.init(serverId: serverId, agentId: agentId, step: .failed, line: "\(label) could not be installed on this server.", detail: "The install ended with \(code)."))
        }
        let found = try? await lookForAgent(serverId, agentId)
        guard !attempt.cancelled else { return stateOf(serverId, agentId: agentId) }
        await finish(serverId, attempt: attempt, interrupt: false)
        guard let found else {
            return say(.init(serverId: serverId, agentId: agentId, step: .failed, line: "The install finished but \(label) will not start.", weInstalled: true))
        }
        say(.init(serverId: serverId, agentId: agentId, step: .installed, line: "\(label) \(found.version) is installed. Signing in…", weInstalled: true, version: found.version))
        return await signIn(serverId, agentId: agentId, shell: shell, binary: found.path, weInstalled: true)
    }
    public func signIn(_ serverId: String, agentId: BackendServersAgentID, shell: any BackendServersShell,
                       binary: String, weInstalled: Bool = false) async -> BackendServersSetupState {
        await cancel(serverId)
        let attempt = BackendServersSetupAttempt(serverId: serverId, agentId: agentId); attempts[serverId] = attempt
        if agentId == .gemini {
            shell.write(binary + "\n")
            return say(.init(serverId: serverId, agentId: agentId, step: .signingIn,
                             line: "Gemini CLI signs in inside its own screen. Choose the Google sign-in below, open the address it prints, and paste the code back at its prompt.", byHand: true, weInstalled: weInstalled))
        }
        if agentId == .codex { return await deviceSignIn(serverId, shell, binary, weInstalled, attempt) }
        return await tunnelSignIn(serverId, shell, binary, weInstalled, attempt)
    }
    private func deviceSignIn(_ serverId: String, _ shell: any BackendServersShell, _ binary: String,
                              _ installed: Bool, _ attempt: BackendServersSetupAttempt) async -> BackendServersSetupState {
        let url = BackendServersSetupRules.deviceURL(.codex)!
        let watcher = BackendServersSetupCodeWatch(shell: shell, url: url) { [weak self] code in
            Task { await self?.codeFound(serverId, code: code, installed: installed, attempt: attempt) }
        }
        defer { watcher.close() }
        do {
            if let open = deps.openInBrowser {
                try await open(url)
                guard !attempt.cancelled else { return stateOf(serverId, agentId: .codex) }
                say(.init(serverId: serverId, agentId: .codex, step: .signingIn, line: "Codex CLI is showing a one-time code in the terminal below. Enter it on the page that just opened in your browser.", weInstalled: installed))
            } else {
                say(.init(serverId: serverId, agentId: .codex, step: .signingIn, line: "Open the address Codex CLI prints below, and enter the code it shows there.", weInstalled: installed))
            }
            let code = await typeAndWait(shell, binary + " login --device-auth; echo \(BackendServersSetupRules.done) $?", attempt: attempt,
                                         ceiling: BackendServersSetupRules.deviceCeilingMilliseconds)
            guard !attempt.cancelled else { return stateOf(serverId, agentId: .codex) }
            let after = try await lookForAgent(serverId, .codex)
            guard !attempt.cancelled else { return stateOf(serverId, agentId: .codex) }
            await finish(serverId, attempt: attempt, interrupt: false)
            if code == 0, let after, after.signedIn != .no {
                return say(.init(serverId: serverId, agentId: .codex, step: .done, line: BackendServersSetupRules.accountLine(.codex, agent: after), weInstalled: installed, version: after.version))
            }
            return say(.init(serverId: serverId, agentId: .codex, step: .failed, line: "The sign-in was not finished.", weInstalled: installed))
        } catch {
            guard !attempt.cancelled else { return stateOf(serverId, agentId: .codex) }
            await finish(serverId, attempt: attempt)
            return say(.init(serverId: serverId, agentId: .codex, step: .failed, line: "The sign-in stopped before it finished.", detail: error.localizedDescription, weInstalled: installed))
        }
    }
    private func codeFound(_ serverId: String, code: String, installed: Bool, attempt: BackendServersSetupAttempt) {
        guard attempts[serverId]?.id == attempt.id, !attempt.cancelled else { return }
        say(.init(serverId: serverId, agentId: .codex, step: .signingIn,
                  line: deps.openInBrowser == nil ? "Codex CLI is waiting for this code. Open https://auth.openai.com/codex/device and enter it." : "Codex CLI is waiting for this code on the page that just opened in your browser.", code: code, weInstalled: installed))
    }
    private func tunnelSignIn(_ serverId: String, _ shell: any BackendServersShell, _ binary: String,
                              _ installed: Bool, _ attempt: BackendServersSetupAttempt) async -> BackendServersSetupState {
        say(.init(serverId: serverId, agentId: .claude, step: .signingIn, line: "Opening the sign-in page in your browser.", weInstalled: installed))
        do {
            for _ in 0..<3 {
                let scratch = try await deps.runScript(serverId, BackendServersSetupRules.scratchScript)
                let dir = BackendServersSetupWire.trim(scratch.stdout)
                if attempt.cancelled {
                    if dir.hasPrefix("/tmp/td-signin-") { _ = try? await deps.runScript(serverId, "rm -rf " + BackendServersSetupWire.quote(dir)) }
                    return stateOf(serverId, agentId: .claude)
                }
                guard scratch.code == 0, dir.hasPrefix("/tmp/td-signin-") else {
                    await finish(serverId, attempt: attempt)
                    return say(.init(serverId: serverId, agentId: .claude, step: .failed, line: "This server would not let the sign-in start.", detail: BackendServersSetupWire.trim(scratch.stderr), weInstalled: installed))
                }
                let run = deps.runScript
                attempt.addUndo { _ = try? await run(serverId, "rm -rf " + BackendServersSetupWire.quote(dir)) }
                shell.write("BROWSER=\(BackendServersSetupWire.quote(dir + "/open")) \(binary) auth login --claudeai\n")
                attempt.setStop { shell.write("\u{03}") }
                let captured = try await deps.runScript(serverId, BackendServersSetupRules.waitScript(dir))
                guard !attempt.cancelled else { return stateOf(serverId, agentId: .claude) }
                let url = BackendServersSetupWire.trim(captured.stdout)
                guard captured.code == 0, let port = BackendServersSetupRules.authPortOf(url), let openTunnel = deps.openTunnel else {
                    return await byHand(serverId, installed, attempt)
                }
                let result = await openTunnel(serverId, port)
                if attempt.cancelled {
                    if case .opened(let tunnel) = result { tunnel.close() }
                    return stateOf(serverId, agentId: .claude)
                }
                switch result {
                case .taken:
                    await attempt.clean(interrupt: true, markCancelled: false); continue
                case .refused: return await byHand(serverId, installed, attempt)
                case .opened(let tunnel):
                    attempt.addUndo { tunnel.close() }
                    guard let open = deps.openInBrowser else { return await byHand(serverId, installed, attempt) }
                    try await open(url)
                    let carried = await tunnel.waitForCarried()
                    guard !attempt.cancelled else { return stateOf(serverId, agentId: .claude) }
                    let after: BackendServersAgentFact?
                    if carried { after = try await lookForAgent(serverId, .claude) } else { after = nil }
                    guard !attempt.cancelled else { return stateOf(serverId, agentId: .claude) }
                    await finish(serverId, attempt: attempt)
                    if let after, after.signedIn == .yes {
                        return say(.init(serverId: serverId, agentId: .claude, step: .done, line: BackendServersSetupRules.accountLine(.claude, agent: after), weInstalled: installed, version: after.version))
                    }
                    return say(.init(serverId: serverId, agentId: .claude, step: .failed, line: "The sign-in was not finished.", weInstalled: installed))
                }
            }
            return await byHand(serverId, installed, attempt)
        } catch {
            guard !attempt.cancelled else { return stateOf(serverId, agentId: .claude) }
            await finish(serverId, attempt: attempt)
            return say(.init(serverId: serverId, agentId: .claude, step: .failed, line: "The sign-in stopped before it finished.", detail: error.localizedDescription, weInstalled: installed))
        }
    }
    private func byHand(_ serverId: String, _ installed: Bool, _ attempt: BackendServersSetupAttempt) async -> BackendServersSetupState {
        attempt.setStop(nil)
        await finish(serverId, attempt: attempt, interrupt: false)
        return say(.init(serverId: serverId, agentId: .claude, step: .signingIn, line: "Finish signing in in the terminal below — it prints an address to open and waits for the code.", byHand: true, weInstalled: installed))
    }
    public func cancel(_ serverId: String) async {
        guard let attempt = attempts.removeValue(forKey: serverId) else { return }
        await attempt.clean()
        if let id = attempt.agentId { say(.init(serverId: serverId, agentId: id)) }
    }
    public func cancelAll() async { for id in Array(attempts.keys) { await cancel(id) } }
    private func finish(_ serverId: String, attempt: BackendServersSetupAttempt, interrupt: Bool = true) async {
        guard attempts[serverId]?.id == attempt.id else { return }; attempts[serverId] = nil; await attempt.clean(interrupt: interrupt)
    }
    public func signOut(_ serverId: String, agentId: BackendServersAgentID, shell: any BackendServersShell, binary: String) async -> BackendServersSetupState {
        await cancel(serverId)
        if let reason = BackendServersSetupRules.whyNoSignOut(agentId) { return say(.init(serverId: serverId, agentId: agentId, step: .failed, line: reason)) }
        let label = BackendServersSetupRules.label(agentId)
        let attempt = BackendServersSetupAttempt(serverId: serverId, agentId: agentId); attempts[serverId] = attempt
        say(.init(serverId: serverId, agentId: agentId, step: .signingIn, line: "Asking \(label) to forget its login."))
        let command = binary + (agentId == .claude ? " auth logout" : " logout")
        let code = await typeAndWait(shell, command + "; echo \(BackendServersSetupRules.done) $?", attempt: attempt, ceiling: BackendServersSetupRules.installCeilingMilliseconds)
        guard !attempt.cancelled else { return stateOf(serverId, agentId: agentId) }
        let after = try? await lookForAgent(serverId, agentId)
        guard !attempt.cancelled else { return stateOf(serverId, agentId: agentId) }
        await finish(serverId, attempt: attempt, interrupt: false)
        if let after, after.signedIn == .no { return say(.init(serverId: serverId, agentId: agentId, line: "\(label) is signed out on this server.", version: after.version)) }
        return say(.init(serverId: serverId, agentId: agentId, step: .failed, line: "\(label) is still signed in on this server.", detail: code == 0 ? "" : "The command ended with \(code)."))
    }
    public func remove(_ serverId: String, agentId: BackendServersAgentID, binary: String) async -> BackendServersSetupState {
        await cancel(serverId)
        do {
            let result = try await deps.runScript(serverId, BackendServersSetupRules.removeScript(binary, id: agentId))
            if result.code != 0 { return say(.init(serverId: serverId, agentId: agentId, step: .failed, line: "That could not be removed from this server.", detail: BackendServersSetupWire.trim(result.stderr))) }
            return say(.init(serverId: serverId, agentId: agentId, line: "\(BackendServersSetupRules.label(agentId)) was removed from this server."))
        } catch { return say(.init(serverId: serverId, agentId: agentId, step: .failed, line: "That could not be removed from this server.", detail: error.localizedDescription)) }
    }
    private func typeAndWait(_ shell: any BackendServersShell, _ line: String, attempt: BackendServersSetupAttempt, ceiling: Int) async -> Int {
        let tape = BackendServersSetupTape(shell); defer { tape.close() }
        attempt.setStop { shell.write("\u{03}") }; attempt.setWake { tape.close() }
        shell.write(line + "\n")
        let answer = await tape.next(BackendServersSetupRules.done + #" (\d+)"#, milliseconds: ceiling)
        attempt.setStop(nil); attempt.setWake(nil)
        return answer.flatMap(Int.init) ?? -1
    }
    private func lookForAgent(_ serverId: String, _ id: BackendServersAgentID) async throws -> BackendServersAgentFact? {
        let result = try await deps.runScript(serverId, BackendServersSetupRules.findScript(id))
        guard result.code == 0 else { return nil }
        let fields = BackendServersSetupWire.trim(result.stdout).components(separatedBy: "\t")
        guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
        return .init(id: id, path: fields[0], version: fields[1], signedIn: fields.count > 2 ? BackendServersSigninState(rawValue: fields[2]) ?? .unknown : .unknown,
                     account: fields.count > 3 && !fields[3].isEmpty ? fields[3] : nil)
    }
}

private final class BackendServersSetupCodeWatch: @unchecked Sendable {
    private let lock = NSLock(); private var seen = ""; private var found = false
    private var stop: (@Sendable () -> Void)?
    init(shell: any BackendServersShell, url: String, onFound: @escaping @Sendable (String) -> Void) {
        stop = shell.onData { [weak self] chunk in
            guard let self else { return }
            let code = self.lock.withLock { () -> String? in
                guard !self.found else { return nil }
                self.seen = String(decoding: (self.seen + chunk).utf16.suffix(64 * 1024), as: UTF16.self)
                let code = BackendServersSetupRules.oneTimeCodeIn(self.seen, deviceURL: url)
                if code != nil { self.found = true }; return code
            }
            if let code { self.close(); onFound(code) }
        }
    }
    func close() { let old = lock.withLock { let old = stop; stop = nil; return old }; old?() }
}
