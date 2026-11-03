import Foundation
import Testing
@testable import TerminalDeckBackend

// Lane S5. Ports src/main/pty-manager.test.ts:36-76 against BackendSessionFailure.launch (the Swift spawn-failure sentence).
@Suite("S5 sessions: the sentence for a process that would not start (pty-manager.test.ts)")
struct BackendFoundationTestsS5SessionsSpawnFailure {
    private func sentence(command: String = "/usr/bin/claude", cwd: String = "/home/asad/ClaudeKiwi", procCwd: String = "/Users/kiwi", cause: String? = nil) -> String {
        BackendSessionFailure.launch(provider: "claude", cwd: cwd, command: command, processCwd: procCwd, cause: cause).errorDescription ?? ""
    }
    // TS pty-manager.test.ts:37
    @Test func namesAgentFolderProgramAndWhereItWasToRun() {
        let message = sentence()
        #expect(message.contains("claude")); #expect(message.contains("/home/asad/ClaudeKiwi"))
        #expect(message.contains("/usr/bin/claude")); #expect(message.contains("/Users/kiwi"))
    }
    // TS pty-manager.test.ts:54
    @Test func keepsWhatTheLayerBelowSaidVerbatimAndLast() {
        #expect(sentence(procCwd: "/p", cause: "posix_spawnp failed.").hasSuffix("posix_spawnp failed."))
    }
    // TS pty-manager.test.ts:61
    @Test func endsCleanlyWhenThereWasNothingToQuote() {
        #expect(sentence(command: "/usr/bin/claude", cwd: "/p", procCwd: "/p") == "could not start claude in /p: /usr/bin/claude would not run from /p")
    }
    // TS pty-manager.test.ts:73 — skipped: Swift takes a POSIX status code, so "something that is not an Error" has no input. (pty-manager.test.ts:79 is a source-text check of pty-manager.ts: skipped.)
}
