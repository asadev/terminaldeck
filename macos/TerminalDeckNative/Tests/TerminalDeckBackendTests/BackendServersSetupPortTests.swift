import Foundation
import Testing
@testable import TerminalDeckBackend

@Suite("setup.test.ts individual case parity")
struct BackendServersSetupPortTests {
    private var room: BackendServersAgentInstallRoom { .init(downloader: "curl", npm: "/usr/bin/npm", memoryAvailableKb: 4_000_000, homeFreeKb: 4_000_000) }
    private var deviceURL: String { "https://auth.openai.com/codex/device" }
    private var measuredDeviceOutput: String {
        "Welcome to Codex [v\u{1b}[90m0.149.0\u{1b}[0m]\r\n" +
        "\u{1b}[90mOpenAI's command-line coding agent\u{1b}[0m\r\n\r\n" +
        "Follow these steps to sign in with ChatGPT using device code authorization:\r\n\r\n" +
        "1. Open this link in your browser and sign in to your account\r\n" +
        "   \u{1b}[94mhttps://auth.openai.com/codex/device\u{1b}[0m\r\n\r\n" +
        "2. Enter this one-time code \u{1b}[90m(expires in 15 minutes)\u{1b}[0m\r\n" +
        "   \u{1b}[94m519G-KS0UC\u{1b}[0m\r\n\r\n" +
        "\u{1b}[90mContinue only if you started this login in Codex.\u{1b}[0m\r\n"
    }
    @Test("knows three agents, and can install and sign in to each of them") func s125EveryAgent() {
        #expect(BackendServersSetupRules.setupAgents == [.claude, .codex, .gemini])
        for id in BackendServersSetupRules.setupAgents { #expect(BackendServersSetupRules.installCommand(id, room: room) != nil); #expect(BackendServersSetupRules.whyNotInstall(id, room: room) == nil); #expect(BackendServersSetupRules.installConsequence(id, serverName: "kiwi-vps").contains("kiwi-vps")) }
    }
    @Test("names each agent on its own row and nowhere else") func s136NeutralRows() {
        let labels = BackendServersSetupRules.setupAgents.map(BackendServersSetupRules.label)
        #expect(labels == ["Claude Code", "Codex CLI", "Gemini CLI"])
        for id in BackendServersSetupRules.setupAgents { for label in labels where label != BackendServersSetupRules.label(id) { #expect(!BackendServersSetupRules.installConsequence(id, serverName: "x").contains(label)) } }
    }
    @Test("says how each one signs in, and all three answers were measured") func s151SigninRoutesAndEvidence() async throws {
        let fixture = BackendServersSetupPortBox(), setups = BackendServersSetups(fixture.dependencies)
        _ = await setups.signIn("s", agentId: .claude, shell: fixture.shell, binary: "/c")
        #expect(fixture.shell.writes.contains { $0.contains("BROWSER=") && $0.contains("auth login --claudeai") })
        let codex = BackendServersSetupPortShell { line, shell in if line.contains("login --device-auth") { shell.emit("__terminaldeck_setup 0\n") } }
        _ = await setups.signIn("s", agentId: .codex, shell: codex, binary: "/x")
        #expect(codex.writes.contains { $0.contains("login --device-auth") })
        let gemini = await setups.signIn("s", agentId: .gemini, shell: fixture.shell, binary: "/g")
        #expect(gemini.byHand && fixture.shell.writes.last == "/g\n")
        #expect(BackendServersSetupRules.deviceURL(.codex) != nil); #expect(BackendServersSetupRules.deviceURL(.claude) == nil); #expect(BackendServersSetupRules.deviceURL(.gemini) == nil)
        // The measured provenance belongs to the canonical source, not a new
        // historical claim invented by a native test fixture.
        let source = try BackendServersSetupPortFixtures.read("src/main/servers/setup.ts")
        let notes = source.components(separatedBy: "verified:\n").dropFirst()
        #expect(notes.count == 3)
        for note in notes { #expect((note.components(separatedBy: "\n  },").first ?? "").split(whereSeparator: { $0.isWhitespace }).count > 20) }
        await setups.cancelAll()
    }
    @Test("never offers to remove the folder that holds somebody’s own logins") func s171RemovalLeaves() {
        for id in BackendServersSetupRules.setupAgents {
            let script = BackendServersSetupRules.removeScript("/home/account/.local/bin/" + id.rawValue, id: id)
            #expect(script.contains(#"rm -rf "$HOME/.local/"#))
            for folder in [".claude", ".codex", ".gemini"] { #expect(!script.contains(#"rm -rf "$HOME/\#(folder)""#)) }
        }
    }
    @Test("names the server in the sentence, so it is about their machine") func s184Consequence() {
        #expect(BackendServersSetupRules.installConsequence(.claude, serverName: "kiwi-vps").contains("kiwi-vps"))
        let s = BackendServersSetupRules.installConsequence(.claude, serverName: "x")
        for word in ["320 MB", "administrator access", "remove it again"] { #expect(s.contains(word)) }
    }
    @Test("refuses a server with no way to download, rather than installing one for it") func s192NoDownload() { var r = room; r.downloader = ""; #expect(BackendServersSetupRules.whyNotInstall(.claude, room: r)?.contains("no way to download") == true) }
    @Test("refuses the npm rows on a server with no npm, and says which part is missing") func s198NoNpm() { var r = room; r.npm = ""; for id in [BackendServersAgentID.codex, .gemini] { #expect(BackendServersSetupRules.whyNotInstall(id, room: r)?.contains("no npm") == true) }; #expect(BackendServersSetupRules.installCommand(.codex, room: r) == nil); #expect(BackendServersSetupRules.whyNotInstall(.claude, room: r) == nil) }
    @Test("says the memory figure before the download rather than after the kernel stops it") func s215Memory() { var r = room; r.memoryAvailableKb = 300 * 1024; let why = BackendServersSetupRules.whyNotInstall(.claude, room: r); #expect(why?.contains("300 MB") == true && why?.contains("512 MB") == true) }
    @Test("says the space figure the same way, with each agent’s own figure") func s221Disk() { var r = room; r.homeFreeKb = 100 * 1024; #expect(BackendServersSetupRules.whyNotInstall(.claude, room: r)?.contains("100 MB") == true); r.homeFreeKb = 200 * 1024; #expect(BackendServersSetupRules.whyNotInstall(.codex, room: r)?.contains("200 MB") == true); #expect(BackendServersSetupRules.whyNotInstall(.gemini, room: r) == nil) }
    @Test("gets out of the way when there is nothing in the way") func s229Healthy() { #expect(BackendServersSetupRules.whyNotInstall(.claude, room: room) == nil) }
    @Test("takes wget as well, because plenty of images ship exactly one of the two") func s233Downloaders() { var r = room; #expect(BackendServersSetupRules.installCommand(.claude, room: r)?.contains("curl") == true); r.downloader = "wget"; #expect(BackendServersSetupRules.installCommand(.claude, room: r)?.contains("wget") == true); r.downloader = ""; #expect(BackendServersSetupRules.installCommand(.claude, room: r) == nil) }
    @Test("installs the npm rows into the account’s own home, never as root") func s239UserPrefix() { for id in [BackendServersAgentID.codex, .gemini] { let s = BackendServersSetupRules.installCommand(id, room: room) ?? ""; #expect(s.contains(#"--prefix "$HOME/.local""#)); #expect(!s.contains("sudo")) } }
    @Test("finds the number that is baked into it") func s252Port() { #expect(BackendServersSetupRules.authPortOf("https://claude.ai/oauth/authorize?code_challenge=x&redirect_uri=http%3A%2F%2Flocalhost%3A36437%2Fcallback&state=y") == 36437) }
    @Test("refuses the other address claude prints, which goes somewhere else entirely") func s260OtherAddress() { #expect(BackendServersSetupRules.authPortOf("https://claude.ai/oauth/authorize?redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&state=y") == nil) }
    @Test("refuses anything that is not this machine") func s271RemoteAddress() { #expect(BackendServersSetupRules.authPortOf("https://x/?redirect_uri=http%3A%2F%2Fevil.example%3A80%2Fcallback") == nil); #expect(BackendServersSetupRules.authPortOf("https://x/?nothing=here") == nil) }
    @Test("picks out whichever row is being asked about") func s282AgentRow() { var facts = BackendServersFacts(serverId: "s", measuredAt: 1); facts.agents = .yes([.init(id: .gemini, path: "/g", version: "1"), .init(id: .claude, path: "/c", version: "2", signedIn: .yes, account: "a@b")], measuredAt: 1, how: "looked"); #expect(BackendServersSetupRules.agentOn(facts, id: .claude)?.path == "/c"); #expect(BackendServersSetupRules.agentOn(facts, id: .gemini)?.path == "/g"); #expect(BackendServersSetupRules.agentOn(facts, id: .codex) == nil) }
    @Test("answers nothing when the check itself could not run") func s294UnknownAgentFact() { let facts = BackendServersFacts(serverId: "s", measuredAt: 1, why: "could not look"); for id in BackendServersSetupRules.setupAgents { #expect(BackendServersSetupRules.agentOn(facts, id: id) == nil) } }
    @Test("removes the scratch folder and leaves the login alone on the by-hand path") func s304ByHandCleanup() async { let f = BackendServersSetupPortBox(); let state = await BackendServersSetups(f.dependencies).signIn("s1", agentId: .claude, shell: f.shell, binary: "/home/asad/.local/bin/claude"); #expect(state.byHand); #expect(f.scripts.values.contains { $0.contains("rm -rf") && $0.contains("/tmp/td-signin-") }); #expect(!f.shell.writes.contains { $0.contains("\u{03}") }); #expect(f.shell.writes.contains { $0.contains("auth login --claudeai") }) }
    @Test("stops the login and removes the folder when it is cancelled part-way") func s318CancelDuringCapture() async { let f = BackendServersSetupPortBox(); let arrived = BackendServersSetupPortSignal(), release = BackendServersSetupPortSignal(); let scripts = f.scripts; let setup = BackendServersSetups(.init(runScript: { _, script in scripts.add(script); if script.contains("mktemp -d") { return .init(code: 0, stdout: "/tmp/td-signin-abc123") }; if script.contains("open.url") { arrived.send(); await release.wait(); return .init(code: 1, stdout: "") }; return .init(code: 0, stdout: "") })); let running = Task { await setup.signIn("s1", agentId: .claude, shell: f.shell, binary: "/c") }; await arrived.wait(); await setup.cancel("s1"); #expect(scripts.values.contains { $0.contains("rm -rf") && $0.contains("/tmp/td-signin-") }); #expect(f.shell.writes.contains("\u{03}")); release.send(); _ = await running.value }
    @Test("carries the absolute path rather than trusting the name to be findable") func s352AbsoluteBinary() async { let f = BackendServersSetupPortBox(); _ = await BackendServersSetups(f.dependencies).signIn("s1", agentId: .claude, shell: f.shell, binary: "/home/asad/.local/bin/claude"); #expect(f.shell.writes.contains { $0.contains("/home/asad/.local/bin/claude auth login") }) }
    @Test("makes the scratch folder unreadable by the other accounts on the machine") func s361ScratchMode() async { let f = BackendServersSetupPortBox(); _ = await BackendServersSetups(f.dependencies).signIn("s1", agentId: .claude, shell: f.shell, binary: "/c"); let made = f.scripts.values.first { $0.contains("mktemp -d") } ?? ""; #expect(made.contains(#"chmod 700 "$d""#)); #expect(made.contains("umask 077")) }
    @Test("says so and never types anything into the terminal") func s373InstallRefusal() async { let f = BackendServersSetupPortBox(); var r = room; r.downloader = ""; let state = await BackendServersSetups(f.dependencies).install("s1", agentId: .claude, shell: f.shell, room: r, serverName: "kiwi-vps"); #expect(state.step == .failed); #expect(f.shell.writes.isEmpty) }
    @Test("puts the code on the state the moment the sign-in prints it") func s419DeviceCodePush() async { let f = BackendServersSetupPortBox(); let setup = BackendServersSetups(f.dependencies); let running = Task { await setup.signIn("s1", agentId: .codex, shell: f.shell, binary: "/home/asad/.local/bin/codex") }; await f.shell.writesChanged.wait(); f.shell.emit(measuredDeviceOutput); await f.codeObserved.wait(); #expect(f.states.values.contains { $0.code == "519G-KS0UC" && $0.line.contains("this code") }); f.shell.emit("__terminaldeck_setup 0\n"); _ = await running.value }
    @Test("carries no code on a route that has none, rather than an empty box") func s449NoTunnelCode() async { let f = BackendServersSetupPortBox(); let state = await BackendServersSetups(f.dependencies).signIn("s1", agentId: .claude, shell: f.shell, binary: "/home/asad/.local/bin/claude"); #expect(state.code == ""); #expect(f.states.values.allSatisfy { $0.code == "" }) }
    @Test("reads it out of the exact bytes a real Codex printed") func s458MeasuredCode() { #expect(BackendServersSetupRules.oneTimeCodeIn(measuredDeviceOutput, deviceURL: deviceURL) == "519G-KS0UC") }
    @Test("answers nothing while the code has not been printed yet") func s462NoCodeYet() { for text in ["", "Welcome to Codex", "Enter this one-time code (expires in 15 minutes)\n"] { #expect(BackendServersSetupRules.oneTimeCodeIn(text, deviceURL: deviceURL) == nil) } }
    @Test("will not lift a code-shaped word out of output that is not a sign-in") func s470RequiresAnchor() { for text in ["519G-KS0UC\n", "release AAA-BBB\n", "/tmp/AAA-BBB"] { #expect(BackendServersSetupRules.oneTimeCodeIn(text, deviceURL: deviceURL) == nil) } }
    @Test("still finds it when the sentence around it has been reworded") func s481URLAnchor() { #expect(BackendServersSetupRules.oneTimeCodeIn(deviceURL + "\n\n 519G-KS0UC\n", deviceURL: deviceURL) == "519G-KS0UC") }
    @Test("takes the code after the phrase rather than something earlier on screen") func s488LaterCode() { #expect(BackendServersSetupRules.oneTimeCodeIn("AAA-BBB\nEnter this one-time code\n519G-KS0UC\n", deviceURL: deviceURL) == "519G-KS0UC") }
    @Test("types the agent’s own command into the terminal the person is watching") func s516SignoutCommands() async { for (id, suffix) in [(BackendServersAgentID.claude, "auth logout"), (.codex, "logout")] { let f = BackendServersSetupPortBox(); let shell = BackendServersSetupPortShell { _, shell in shell.emit("__terminaldeck_setup 0\n") }; _ = await BackendServersSetups(f.dependencies).signOut("s1", agentId: id, shell: shell, binary: "/home/me/bin/" + id.rawValue); #expect(shell.writes.first?.contains("/home/me/bin/" + id.rawValue + " " + suffix) == true) } }
    @Test("believes the server rather than the command’s exit status") func s528ServerWins() async { let shell = BackendServersSetupPortShell { _, shell in shell.emit("__terminaldeck_setup 0\n") }; let setups = BackendServersSetups(.init(runScript: { _, _ in .init(code: 0, stdout: "/usr/bin/codex\t1\tyes\tme@example.invalid\n") })); let state = await setups.signOut("s1", agentId: .codex, shell: shell, binary: "/usr/bin/codex"); #expect(state.step == .failed && state.line.contains("still signed in")) }
    @Test("refuses, with the agent’s own reason, where there is no command for it") func s546NoGeminiSignout() async { let f = BackendServersSetupPortBox(); let state = await BackendServersSetups(f.dependencies).signOut("s1", agentId: .gemini, shell: f.shell, binary: "/g"); #expect(state.step == .failed); #expect(state.line == BackendServersSetupRules.whyNoSignOut(.gemini)); #expect(f.shell.writes.isEmpty) }
    @Test("says what it will do before it does it, in the words of the file that does it") func s558SignoutConsequence() { for id in BackendServersSetupRules.setupAgents { let s = BackendServersSetupRules.signOutConsequence(id, serverName: "kiwi-vps"); #expect(s.contains("kiwi-vps") && s.contains("forget the login") && s.contains("stays installed") && s.contains("sign in again")) } }
    @Test("has a reason for exactly the one agent that cannot") func s567SignoutRefusals() { #expect(BackendServersSetupRules.whyNoSignOut(.claude) == nil); #expect(BackendServersSetupRules.whyNoSignOut(.codex) == nil); #expect(BackendServersSetupRules.whyNoSignOut(.gemini)?.contains("terminal") == true) }
}

private final class BackendServersSetupPortStates: @unchecked Sendable {
    private let lock = NSLock(); private var all: [BackendServersSetupState] = []
    func add(_ state: BackendServersSetupState) { lock.withLock { all.append(state) } }
    var values: [BackendServersSetupState] { lock.withLock { all } }
}
private struct BackendServersSetupPortBox: Sendable {
    let scripts = BackendServersSetupPortLog(), states = BackendServersSetupPortStates(), codeObserved = BackendServersSetupPortSignal()
    let shell = BackendServersSetupPortShell()
    var dependencies: BackendServersSetupDependencies {
        let scripts = scripts, states = states, codeObserved = codeObserved
        return .init(runScript: { _, script in
            scripts.add(script)
            if script.contains("mktemp -d") { return .init(code: 0, stdout: "/tmp/td-signin-abc123") }
            if script.contains("open.url") { return .init(code: 0, stdout: "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A39695%2Fcallback&state=x") }
            return .init(code: 0, stdout: "/home/me/bin/codex\t1\tno\t\n")
        }, openTunnel: { _, _ in .refused("this server will not carry it") }, openInBrowser: { _ in }, broadcast: { state in states.add(state); if !state.code.isEmpty { codeObserved.send() } })
    }
}
