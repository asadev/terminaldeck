import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// 27 Oct (live, Asad's Mac): every Claude and Codex chat started from the phone died with "Hoot's CLI exited during its
// handshake." A phone's chat runs inside its device's folder boundary (`sandbox-exec -p <profile> <cli> …`), and the
// chat mode put its flags in front of `-p`, so sandbox-exec printed its usage and quit. The Mac also dropped that reason.

@Suite("Chat sessions: a confined launch and a CLI that quits while starting", .serialized)
struct ChatHandshakeExitReasonTests {
    /// Claude Code's print mode, as far as the handshake and one answer.
    private static let fakeClaude = #"""
    #!/bin/sh
    read init
    id=$(printf '%s' "$init" | /usr/bin/sed -E 's/.*"request_id":"([^"]*)".*/\1/')
    printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\n' "$id"
    while read line; do
      printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"pong"}]}}\n'
      printf '{"type":"result","subtype":"success","is_error":false,"result":"pong"}\n'
    done
    """#
    /// The real launcher's argument rules: `-p <profile>` (or `-f <file>`) first, else its usage and exit 64. It notes
    /// what it was given, then runs the CLI with the rest.
    private static let fakeSandbox = #"""
    #!/bin/sh
    printf '%s\n' "$@" > "$(dirname "$0")/sandbox-argv"
    if [ "$1" != "-p" ] && [ "$1" != "-f" ]; then
      echo "/usr/bin/sandbox-exec: illegal option -- -" >&2
      echo "Usage: sandbox-exec [options] command [args]" >&2
      exit 64
    fi
    shift 2
    exec "$@"
    """#

    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("td-handshake-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func script(_ root: URL, _ name: String, _ text: String) throws -> URL {
        let file = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }
    private func until(_ check: @escaping () async -> Bool) async -> Bool {
        let limit = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < limit { if await check() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
        return await check()
    }

    @Test func theLaunchersWordsStayInFrontOfTheChatModesFlags() throws {
        let claude = try BackendSessionChats.confinedCLI(executable: "/usr/bin/sandbox-exec",
            arguments: ["-p", "(version 1)", "claude", "--permission-mode", "acceptEdits"])
        #expect(claude.wrapper == ["-p", "(version 1)", "claude"])
        #expect(claude.arguments == ["--permission-mode", "acceptEdits"])
        let claudePlan = try BackendSessionChats.plan(.init(provider: .claude, executable: "/usr/bin/sandbox-exec", arguments: claude.arguments,
            environment: [:], cwd: "/work", conversation: nil), cliSession: nil, again: false).arguments
        #expect(claudePlan.first == "--print")
        #expect(Array((claude.wrapper + claudePlan).prefix(4)) == ["-p", "(version 1)", "claude", "--print"])

        let codex = try BackendSessionChats.confinedCLI(executable: "/usr/bin/sandbox-exec",
            arguments: ["-p", "(version 1)", "codex", "-c", "model_reasoning_effort=high"])
        let codexPlan = try BackendSessionChats.plan(.init(provider: .codex, executable: "/usr/bin/sandbox-exec", arguments: codex.arguments,
            environment: [:], cwd: "/work", conversation: nil), cliSession: nil, again: false).arguments
        #expect(Array((codex.wrapper + codexPlan).prefix(5)) == ["-p", "(version 1)", "codex", "app-server", "--stdio"])

        // A plain launch has no launcher words; an unknown launcher shape is refused, never guessed at.
        let plain = try BackendSessionChats.confinedCLI(executable: "/opt/bin/claude", arguments: ["-p", "x"])
        #expect(plain.wrapper.isEmpty && plain.arguments == ["-p", "x"])
        #expect(throws: BackendSessionFailure.self) { try BackendSessionChats.confinedCLI(executable: "/usr/bin/sandbox-exec", arguments: ["--print"]) }
        #expect(throws: BackendSessionFailure.self) { try BackendSessionChats.confinedCLI(executable: "/usr/bin/sandbox-exec", arguments: ["-p", "(version 1)", "--print"]) }
    }

    @Test func aChatInsideAFolderBoundaryStartsAndAnswers() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let claude = try script(root, "claude", Self.fakeClaude), sandbox = try script(root, "sandbox-exec", Self.fakeSandbox)
        let manager = BackendPTYManager(inheritedEnvironment: ["PATH": "/usr/bin:/bin"]) { _ in }
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in })
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude"); input.chat = true
        // What BackendMacConfinement makes of a phone's start: the launcher, its profile, the CLI, the CLI's own flags.
        let spawn = BackendSpawnSpec(provider: "claude", command: sandbox.path,
            args: ["-p", "(version 1)(allow default)", claude.path, "--permission-mode", "default"], path: "/usr/bin:/bin", tabKey: "phone-tab")
        let meta = try await chats.launch(input, spawn: spawn)
        let argv = try String(contentsOf: root.appendingPathComponent("sandbox-argv"), encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(Array(argv.prefix(4)) == ["-p", "(version 1)(allow default)", claude.path, "--print"])
        #expect(argv.contains("--permission-mode"))
        _ = try await chats.say(meta.id, text: "ping")
        #expect(await until { manager.screen(meta.id)?.contains("pong") == true })
        manager.kill(meta.id)
    }

    @Test func aCLIThatQuitsWhileStartingSaysWhyWithoutSecrets() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let home = NSHomeDirectory()
        let quits = try script(root, "claude", """
        #!/bin/sh
        echo "warning: a slow disk" >&2
        echo "Error: the login sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789 was refused for \(home)/.claude" >&2
        exit 3
        """)
        let manager = BackendPTYManager(inheritedEnvironment: ["PATH": "/usr/bin:/bin"]) { _ in }
        let chats = BackendSessionChats(manager: manager, directory: root.appendingPathComponent("chats"), publish: { _, _ in })
        var input = BackendCreateSessionInput(cwd: root.path, provider: "claude"); input.chat = true
        let spawn = BackendSpawnSpec(provider: "claude", command: quits.path, args: [], path: "/usr/bin:/bin", tabKey: "quits")
        do {
            _ = try await chats.launch(input, spawn: spawn)
            Issue.record("A CLI that quit while starting must not leave a started chat.")
        } catch let error as NativeRPCError {
            #expect(error.message.hasPrefix("Claude Code stopped while it was starting: Error: the login"), "\(error.message)")
            // A path outside the chat's folder never reaches the phone (Reviewer, 27 Oct).
            #expect(error.message.contains("refused for [path]"))
            #expect(!error.message.contains(".claude"))
            #expect(!error.message.contains("sk-ant-api03"))
            #expect(!error.message.contains(home + "/"))
            #expect(!error.message.contains("handshake"))
        }
        #expect(manager.list().isEmpty)
    }

    @Test func aCodexThatHasAlreadyQuitStillGivesItsReason() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat-codex.json"), provider: .codex)
        try await store.attach(.init(command: "/bin/sh", arguments: ["-c", "echo 'Usage: sandbox-exec [options] command [args]' >&2; exit 64"],
                                     cwd: root.path, environment: [:], setup: .init(cwd: root.path)))
        // Its exit is handled before the handshake is asked for.
        #expect(await until { await store.snapshot()["problem"].string != nil })
        do {
            try await store.initialize()
            Issue.record("The handshake of a CLI that quit must fail.")
        } catch let error as NativeRPCError {
            #expect(error.message == "Codex stopped while it was starting: Usage: sandbox-exec [options] command [args]")
        }
    }

    @Test func theReasonIsOneShortPlainLine() {
        #expect(BackendHootChatStore.reasonLine("") == nil)
        #expect(BackendHootChatStore.stoppedWhileStarting(provider: .gemini, code: 9, diagnostic: " \n ") == "Gemini stopped while it was starting (exit code 9).")
        #expect(BackendHootChatStore.reasonLine("\u{1B}[31mfatal\u{1B}[0m: no such file\nmore") == "fatal: no such file")
        #expect(BackendHootChatStore.reasonLine("loading…\nERROR config.toml is invalid") == "ERROR config.toml is invalid")
        // The launch's own secret values are hidden too, and a stray control character never reaches the phone.
        #expect(BackendHootChatStore.reasonLine("Error: refused key hunter2-secret-value\u{7}", secrets: ["hunter2-secret-value"]) == "Error: refused key [redacted]")
        // Only paths inside the chat's own folder are kept; everything else the CLI named becomes [path], whole paths
        // with spaces and `..` escapes included.
        #expect(BackendHootChatStore.reasonLine("Error: cannot read /work/api/src/main.swift or /etc/hosts or ~/.ssh/id_rsa", folder: "/work/api")
                == "Error: cannot read /work/api/src/main.swift or [path] or [path]")
        #expect(BackendHootChatStore.reasonLine("Error: no /work/apiary/x, /work/api/../secret.txt or /Library/Application Support/x y", folder: "/work/api")
                == "Error: no [path], [path] or [path] y")
        #expect(BackendHootChatStore.reasonLine("/usr/bin/sandbox-exec: illegal option -- -", folder: "/work/api") == "[path]: illegal option -- -")
        let long = BackendHootChatStore.reasonLine(String(repeating: "x ", count: 300)) ?? ""
        #expect(long.count == 200 && long.hasSuffix("…"))
    }
}
