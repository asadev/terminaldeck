import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("AGT every agent on this Mac: detection from process trees")
struct AGTDeviceAgentsTests {
    // A fixture Mac: Terminal, iTerm, VS Code, Cursor, the Claude app, the ChatGPT/Codex app,
    // Terminal Deck's host, a tmux session, and helpers that must not count as agents.
    static let tree: [AGTProcess] = [
        .init(pid: 100, ppid: 1, name: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        .init(pid: 101, ppid: 100, name: "login", path: "/usr/bin/login"),
        .init(pid: 102, ppid: 101, name: "zsh", path: "/bin/zsh"),
        .init(pid: 103, ppid: 102, name: "claude", path: "/Users/u/.local/share/claude/versions/2.1.293", args: ["claude", "--resume", "aaaaaaaa-1111-2222-3333-444444444444"], cwd: "/Users/u/app", startedAt: 1_000),
        // Claude runs Codex through its node launcher: the launcher is not a second agent.
        .init(pid: 104, ppid: 103, name: "node", path: "/usr/local/bin/node", args: ["node", "/Users/u/.npm/bin/codex.js", "exec"], cwd: "/Users/u/app"),
        .init(pid: 105, ppid: 104, name: "codex", path: "/Users/u/.codex/bin/codex", args: ["codex", "exec"], cwd: "/Users/u/app", startedAt: 2_000,
              openFiles: ["/Users/u/.codex/sessions/2026/10/09/rollout-2026-10-09T01-00-00-01a11874-3909-70b0-85e7-984c56605aff.jsonl"]),
        .init(pid: 200, ppid: 1, name: "iTerm2", path: "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
        .init(pid: 201, ppid: 200, name: "zsh", path: "/bin/zsh"),
        .init(pid: 202, ppid: 201, name: "node", path: "/opt/homebrew/bin/node", args: ["node", "/opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js"], cwd: "/Users/u/site"),
        .init(pid: 300, ppid: 1, name: "Electron", path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"),
        .init(pid: 301, ppid: 300, name: "Code Helper", path: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"),
        .init(pid: 302, ppid: 301, name: "claude", path: "/Users/u/.vscode/extensions/anthropic.claude-code/resources/native-binary/claude", args: ["claude"], cwd: "/Users/u/api", startedAt: 3_000),
        .init(pid: 400, ppid: 1, name: "Cursor", path: "/Applications/Cursor.app/Contents/MacOS/Cursor"),
        .init(pid: 401, ppid: 400, name: "zsh", path: "/bin/zsh"),
        .init(pid: 402, ppid: 401, name: "codex", path: "/opt/homebrew/bin/codex", args: ["codex", "resume", "bbbbbbbb-1111-2222-3333-444444444444"], cwd: "/Users/u/cursor-proj"),
        .init(pid: 500, ppid: 1, name: "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude"),
        .init(pid: 501, ppid: 500, name: "claude", path: "/Applications/Claude.app/Contents/Resources/claude", args: ["claude", "--output-format", "stream-json"], cwd: "/Users/u/desk"),
        .init(pid: 600, ppid: 1, name: "ChatGPT", path: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"),
        .init(pid: 601, ppid: 600, name: "codex", path: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", args: ["codex", "app-server"]),
        .init(pid: 602, ppid: 600, name: "codex", path: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", args: ["codex", "exec-server", "--remote", "x"]),
        .init(pid: 603, ppid: 600, name: "codex", path: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", args: ["codex", "app-server"],
              openFiles: ["/Users/u/.codex/sessions/2026/10/09/rollout-2026-10-09T02-00-00-01a11b5d-f58b-7d22-bb75-a713a841fbc9.jsonl"]),
        .init(pid: 700, ppid: 1, name: "TerminalDeckNat", path: "/Users/u/Library/Application Support/terminaldeck/host/agents/0.20.2-host3/TerminalDeckNativeHelper"),
        .init(pid: 701, ppid: 700, name: "zsh", path: "/bin/zsh"),
        .init(pid: 702, ppid: 701, name: "claude.exe", path: "/Users/u/.nvm/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe", args: ["/Users/u/.nvm/bin/claude", "--resume", "cccccccc-1111-2222-3333-444444444444"], cwd: "/Users/u/ClaudeCRM"),
        .init(pid: 800, ppid: 1, name: "tmux", path: "/opt/homebrew/bin/tmux"),
        .init(pid: 801, ppid: 800, name: "zsh", path: "/bin/zsh"),
        .init(pid: 802, ppid: 801, name: "claude", path: "/Users/u/.local/bin/claude", args: ["claude", "mcp", "serve"]),
        .init(pid: 803, ppid: 801, name: "claude", path: "/Users/u/.local/bin/claude", args: ["claude", "--model", "opus"], cwd: "/Users/u/tmuxed"),
        .init(pid: 900, ppid: 1, name: "node", path: "/usr/local/bin/node", args: ["node", "server.js"]),
    ]

    static let files = AGTDeviceDetect.Files(
        claudeSession: { pid in
            switch pid {
            case 103: AGTClaudeSessionFile(sessionID: "aaaaaaaa-1111-2222-3333-444444444444", cwd: "/Users/u/app", status: "busy", name: "Fix login", processStart: 1_002)
            case 302: AGTClaudeSessionFile(sessionID: "dddddddd-1111-2222-3333-444444444444", cwd: "/Users/u/api", status: "idle", processStart: 50_000) // stale: another process
            default: nil
            }
        },
        claudeTranscript: { session, cwd in "/Users/u/.claude/projects/\(AGTDeviceDetect.claudeProjectFolder(cwd))/\(session).jsonl" },
        tail: { path, ai in
            if ai == "codex" {
                return (AGTTranscriptTail(lastLine: "Running the tests now.", lastSpeaker: "Agent", model: "gpt-6.1", pendingTool: false,
                                          sessionID: AGTDeviceDetect.codexSessionID(fromFile: path), cwd: path.contains("02-00-00") ? "/Users/u/desktop-codex" : "/Users/u/app"), 0)
            }
            return (AGTTranscriptTail(lastLine: "Done. The login is fixed.", lastSpeaker: "Agent", model: "claude-opus-5-5"), 0)
        })

    @Test func findsEveryAgentInEveryAppAndNothingElse() {
        let agents = AGTDeviceDetect.agents(Self.tree, files: Self.files, now: 10_000)
        let byPID = Dictionary(grouping: agents, by: \.pid)
        #expect(Set(byPID.keys) == [103, 105, 202, 302, 402, 501, 603, 702, 803])
        #expect(byPID[103]?.first?.app.name == "Terminal")
        #expect(byPID[105]?.first?.app.name == "Terminal")
        #expect(byPID[105]?.first?.startedBy == "Claude Code")
        #expect(byPID[202]?.first?.ai == "gemini" && byPID[202]?.first?.app.name == "iTerm2")
        #expect(byPID[302]?.first?.app.name == "VS Code")
        #expect(byPID[302]?.first?.app.bundlePath == "/Applications/Visual Studio Code.app")
        #expect(byPID[302]?.first?.app.pid == 300)
        #expect(byPID[402]?.first?.app.name == "Cursor")
        #expect(byPID[501]?.first?.app.name == "Claude")
        #expect(byPID[603]?.first?.app.name == "ChatGPT")
        #expect(byPID[702]?.first?.app.isTerminalDeck == true)
        #expect(byPID[803]?.first?.app.name == "tmux" && byPID[803]?.first?.model == "opus")
    }

    @Test func sessionIdsModelsFoldersStatesAndResume() {
        let agents = AGTDeviceDetect.agents(Self.tree, files: Self.files, now: 10_000, cpu: [302: 12, 803: 0.2])
        let terminal = agents.first { $0.pid == 103 }!
        #expect(terminal.sessionID == "aaaaaaaa-1111-2222-3333-444444444444")
        #expect(terminal.title == "Fix login" && terminal.state == .working && terminal.model == "claude-opus-5-5")
        #expect(terminal.transcriptPath == "/Users/u/.claude/projects/-Users-u-app/aaaaaaaa-1111-2222-3333-444444444444.jsonl")
        #expect(terminal.resumeCommand == "cd /Users/u/app && claude --resume aaaaaaaa-1111-2222-3333-444444444444")
        // A stale record from another process is ignored; CPU decides the state.
        let code = agents.first { $0.pid == 302 }!
        #expect(code.sessionID == nil && code.state == .working && code.resumeCommand == nil)
        let cursor = agents.first { $0.pid == 402 }!
        #expect(cursor.sessionID == "bbbbbbbb-1111-2222-3333-444444444444")
        #expect(cursor.resumeCommand == "cd /Users/u/cursor-proj && codex resume bbbbbbbb-1111-2222-3333-444444444444")
        let desktop = agents.first { $0.pid == 603 }!
        #expect(desktop.sessionID == "01a11b5d-f58b-7d22-bb75-a713a841fbc9" && desktop.project == "/Users/u/desktop-codex" && desktop.model == "gpt-6.1")
        #expect(agents.first { $0.pid == 803 }?.state == .idle)
        #expect(AGTDeviceDetect.shellQuote("/Users/u/My Project") == "'/Users/u/My Project'")
        #expect(AGTDeviceDetect.claudeProjectFolder("/Users/u/td.native shell") == "-Users-u-td-native-shell")
        // Wire round trip, and last messages only when allowed.
        let decoded = AGTDeviceAgent.decode(terminal.wireValue(includeText: true))
        #expect(decoded?.app.name == "Terminal" && decoded?.lastLine == "Done. The login is fixed.")
        #expect(terminal.wireValue(includeText: false)["lastLine"].isNullish)
    }

    @Test func transcriptsGiveTheLastLineModelAndOpenTools() {
        let claude = """
        {"type":"user","sessionId":"s1","cwd":"/w","message":{"role":"user","content":"Please fix the login"},"timestamp":"2026-10-09T01:00:00Z","uuid":"1"}
        {"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"Looking at it.\\nMore detail"},{"type":"tool_use","id":"t1","name":"Bash","input":{}}]},"timestamp":"2026-10-09T01:00:05Z","uuid":"2"}
        """.split(separator: "\n")
        let tail = AGTTranscriptTail.claude(claude)
        #expect(tail.lastLine == "Looking at it." && tail.model == "claude-opus-5-5" && tail.pendingTool && tail.sessionID == "s1")
        let codex = """
        {"type":"session_meta","payload":{"id":"c1","cwd":"/repo"}}
        {"type":"turn_context","payload":{"model":"gpt-6.1","cwd":"/repo"}}
        {"type":"response_item","timestamp":"2026-10-09T01:00:00.000Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Tests pass."}]}}
        {"type":"response_item","payload":{"type":"function_call","call_id":"x","name":"shell","arguments":"{}"}}
        {"type":"response_item","payload":{"type":"function_call_output","call_id":"x","output":"ok"}}
        {"type":"response_item","payload":{"type":"reasoning","summary":[]}}
        """.split(separator: "\n")
        let read = AGTTranscriptTail.codex(codex)
        #expect(read.sessionID == "c1" && read.cwd == "/repo" && read.model == "gpt-6.1" && read.lastLine == "Tests pass." && !read.pendingTool)
        // Claude's own pid record, as written on disk.
        let record = AGTClaudeSessionFile.parse(Data(#"{"pid":62754,"sessionId":"2c6070f9","cwd":"/Users/u/ClaudeCRM","status":"busy","procStart":"Thu Oct  8 21:56:51 2026"}"#.utf8))
        #expect(record?.sessionID == "2c6070f9" && record?.status == "busy" && record?.processStart != nil)
    }
}
