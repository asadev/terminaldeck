import Foundation
import Testing
@testable import TerminalDeckBackend

/// U45: a server set-up is stopped only by its own Stop or its own terminal closing,
/// and long progress output does not make the setup terminal fall behind.
@Suite("Server set-up keeps going")
struct BackendServersSetupKeepsGoingTests {
    private func eventually(_ done: () -> Bool) async {
        for _ in 0..<500 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("#61: closing another terminal on the same server leaves the install running") func otherTerminalCloses() async {
        let working = BackendServersSetupTestShell(), other = BackendServersSetupTestShell()
        let setups = BackendServersSetups(.init(runScript: { _, _ in .init(code: 0, stdout: "") }))
        let install = Task { await setups.install("s1", agentId: .claude, shell: working, room: .init(downloader: "curl"), serverName: "server") }
        await eventually { working.writes.contains { $0.contains(BackendServersSetupRules.done) } }
        await setups.cancel("s1", closing: other)
        #expect(!working.writes.contains("\u{03}"))
        #expect(await setups.stateOf("s1", agentId: .claude).step == .installing)
        await setups.cancel("s1", closing: working)
        #expect(working.writes.contains("\u{03}"))
        #expect(await install.value.step == .idle)
    }

    @Test("#489: megabytes of progress are searched piece by piece and the tape stays bounded") func longProgress() async {
        let shell = BackendServersSetupTestShell(), tape = BackendServersSetupTape(shell)
        let waiting = Task { await tape.next(BackendServersSetupRules.done + #" (\d+)"#, milliseconds: 60_000) }
        try? await Task.sleep(for: .milliseconds(50)) // the waiter is listening before the output starts
        let bar = String(repeating: "█", count: 300) + "\r"
        for _ in 0..<4_000 { shell.emit(bar) }
        shell.emit("Fingerprint ABCD-EFGH\n__terminaldeck_se"); shell.emit("tup 0\n")
        #expect(await waiting.value == "0")
        #expect(tape.snapshot().utf8.count <= 2 * BackendServersSetupTape.kept)
        // A waiter that arrives late still finds what was printed just before it.
        #expect(await tape.next(BackendServersHostRules.fingerprintPattern, milliseconds: 1) == "ABCD-EFGH")
        tape.close()
    }
}
