import Foundation
import Testing
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// U100: server page small bugs.
@Suite("Server page small bugs")
struct ServerPageSmallBugsTests {
    /// #125: only a trailing ".git" goes, so a repository with ".git" inside its name keeps it.
    @Test func linkedRepositoryKeepsGitInsideTheName() {
        #expect(DeployBoard.linkedRepository("owner/my.github-tools") == "owner/my.github-tools")
        #expect(DeployBoard.linkedRepository("https://github.com/owner/my.github-tools.git") == "owner/my.github-tools")
        #expect(DeployBoard.linkedRepository("git@github.com:owner/web.git") == "owner/web")
        #expect(DeployBoard.linkedRepository("https://github.com/owner/web/") == "owner/web")
    }

    /// #199: a server saved by its number address runs no command to learn it.
    @Test func numericAddressNeedsNoServerCommand() async throws {
        actor Count { var value = 0; func add() { value += 1 } }
        let count = Count()
        let numeric = try await NativeCompositionProduction.connectedAddresses(saved: "203.0.113.9") {
            await count.add(); return BackendServersRunResult(code: 0, stdout: "198.51.100.1 50000 203.0.113.9 22")
        }
        #expect(numeric == ["203.0.113.9"])
        #expect(await count.value == 0)
        let named = try await NativeCompositionProduction.connectedAddresses(saved: "box.example") {
            await count.add(); return BackendServersRunResult(code: 0, stdout: "198.51.100.1 50000 203.0.113.9 22")
        }
        #expect(named == ["203.0.113.9"])
        #expect(await count.value == 1)
    }
}
