import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("App session reach and literal probes")
struct BackendAppSessionRulesTests {
    @Test func boundaryRefusesSiblingAndAllowsExactFiles() {
        let boundary = BackendAppSessionBoundary(folder: "/person/project", readable: ["/person/project", "/usr"], readableFiles: ["/person/helper.sh"])
        #expect(boundary.allows("/person/project"))
        #expect(boundary.allows("/person/project/src/main.swift"))
        #expect(!boundary.allows("/person/project-old/key"))
        #expect(!boundary.allows("/person/.ssh/id_ed25519"))
        #expect(boundary.allows("/person/helper.sh"))
        #expect(!boundary.allows("/person/another-helper.sh"))
    }
    @Test func absenceAndExitDoNotInventABoundary() async {
        let registry = BackendAppSessionBoundaryRegistry()
        let before = await registry.boundary(for: "s1"); #expect(before == nil)
        await registry.note("s1", boundary: .init(folder: "/project", readable: ["/project"], readableFiles: []))
        let during = await registry.boundary(for: "s1"); #expect(during?.folder == "/project")
        await registry.forget("s1"); let after = await registry.boundary(for: "s1"); #expect(after == nil)
    }
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
