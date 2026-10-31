import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("App session reach and literal probes")
struct BackendAppSessionRulesTests {
    @Test func missingBrowserVerbsExplainLaunchTimingWithoutDenyingOpen() async {
        let registry = BackendAppSessionVerbsRegistry()
        let absent = await registry.line(for: "s"); #expect(absent == nil)
        await registry.note("s", reason: .early)
        let line = await registry.line(for: "s")
        #expect(line?.contains("read once at launch") == true)
        #expect(line?.contains("started again") == true)
        #expect(line?.contains("cannot open") == false)
        await registry.forget("s"); let after = await registry.line(for: "s"); #expect(after == nil)
    }
    @Test func unavailableErrorRetainsAgentIdentityAndExactMacSentence() {
        let error = BackendAppSessionAgentUnavailableError(provider: "codex", label: "Codex CLI")
        #expect(error.provider == "codex")
        #expect(error.name == "AgentUnavailableError")
        #expect(error.message == "Codex CLI could not be found on this machine, so this session was not started.")
    }
    @Test func literalProbePreservesShellWords() {
        let result = BackendAppSessionToolProbe.result(bin: "copilot", command: "which copilot", stdout: "copilot not found\n", stderr: "", exitCode: 1)
        #expect(result.line == "copilot not found")
        #expect(!result.found)
    }
    @Test func silentAndKilledProbesHaveActionableDifferentSentences() {
        #expect(BackendAppSessionToolProbe.result(bin: "copilot", command: "which copilot", stdout: "", stderr: "", exitCode: 1).line == "copilot not found (which copilot exited 1).")
        #expect(BackendAppSessionToolProbe.result(bin: "codex", command: "which codex", stdout: "", stderr: "", exitCode: -1).line == "codex not found (which codex did not finish).")
    }
    @Test func probeLimitsOutputAndRejectsShellText() {
        let result = BackendAppSessionToolProbe.result(bin: "gemini", command: "which gemini", stdout: "a\nb\nc\nd", stderr: String(repeating: "x", count: 500), exitCode: 1)
        #expect(result.output == "a\nb\nc")
        #expect(!BackendAppSessionToolProbe.safeBinary("claude; rm -rf ~"))
        #expect(!BackendAppSessionToolProbe.safeBinary("$(secret)"))
        #expect(!BackendAppSessionToolProbe.safeBinary("claude\n"))
        #expect(BackendAppSessionToolProbe.safeBinary("gemini-cli"))
    }
    @Test func macConfinementFacadeNeverPerformsAWindowsGrant() throws {
        let channels = BackendAppConfinementChannels(), context = NativeRPCContext(caller: .nativeApp, ownerID: "fixture")
        let state = try channels.invoke("confine:state", args: [], context: context)
        #expect(state["platform"].string == "darwin")
        #expect(state["confining"].bool == true)
        #expect(state["canGrant"].bool == false)
        #expect(try channels.invoke("confine:grant", args: [], context: context)["result"] == .null)
        #expect(try channels.invoke("confine:withdraw", args: [], context: context)["ok"].bool == true)
    }
}
