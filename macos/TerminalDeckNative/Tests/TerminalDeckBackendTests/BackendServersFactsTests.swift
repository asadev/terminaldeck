import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Server facts keep absence, refusal and unasked apart")
struct BackendServersFactsTests {
    private func read(_ raw: String) -> BackendServersFacts { BackendServersProbe.parse(raw, serverId: "s1", measuredAt: 1234) }
    private func allFacts(_ f: BackendServersFacts) throws -> [String: [String: Any]] {
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f)) as! [String: Any]
        return raw.compactMapValues { $0 as? [String: Any] }.filter { $0.value["known"] != nil }
    }
    @Test func emptyAnswerCannotOnEveryFieldAndCarriesReason() throws {
        let facts = try allFacts(read(""))
        #expect(facts.count == 21)
        for (_, fact) in facts { #expect(fact["known"] as? String == "cannot"); #expect((fact["why"] as? String)?.count ?? 0 > 10); #expect(fact["measuredAt"] as? Double == 1234) }
    }
    @Test func measuredAbsenceIsClosedSet() throws {
        let facts = try allFacts(read(BackendServersProbeFixtures.container))
        #expect(facts.filter { $0.value["known"] as? String == "no" }.keys.sorted() == ["containerRuntime", "containers", "siteNames", "webServer"])
        for raw in [BackendServersProbeFixtures.container, BackendServersProbeFixtures.administrator] { for (_, fact) in try allFacts(read(raw)) { #expect(fact["measuredAt"] as? Double == 1234); if fact["known"] as? String != "cannot" { #expect((fact["how"] as? String)?.contains(" ") == true) } } }
        let ordinary = read(BackendServersProbeFixtures.ordinary)
        #expect(ordinary.containerRuntime.known == "cannot"); #expect(ordinary.containers.known == "cannot")
        #expect(ordinary.listeners.value?.allSatisfy { $0.unit.isEmpty } == true)
    }
    @Test func containerHostNumbersCannotEscapeRawOutput() throws {
        let f = read(BackendServersProbeFixtures.container)
        #expect(f.numbersBelongToTheHost)
        #expect(f.disk.why == BackendServersFacts.containerNumbersWhy); #expect(f.memory.why == BackendServersFacts.containerNumbersWhy)
        #expect(f.load1.why == BackendServersFacts.containerNumbersWhy); #expect(f.uptimeSeconds.why == BackendServersFacts.containerNumbersWhy)
        #expect(f.os.known == "yes"); #expect(f.cpus.known == "yes"); #expect(f.packageManager.known == "yes")
        #expect(try allFacts(f)["scalars"] == nil)
        let full = read(BackendServersProbeFixtures.administrator)
        #expect(!full.numbersBelongToTheHost); #expect(full.disk.known == "yes"); #expect(full.memory.known == "yes"); #expect(full.uptimeSeconds.known == "yes")
        #expect(read("init=systemd\ndisk_used_kb=100\n#end ok\n").disk.known == "cannot")
    }
    @Test func partialNoisyAndInvalidAnswers() {
        #expect(read("Welcome!\nstdin: is not a tty\n" + BackendServersProbeFixtures.administrator).os.value == "Ubuntu 24.04.4 LTS")
        #expect(read("os=Ubuntu\n#services ok\n").listeners.why == BackendServersProbe.cutOff)
        #expect(read("#end ok\n").listeners.why == BackendServersProbe.neverAsked)
        #expect(read("web=\n#end ok\n").webServer.known == "no"); #expect(read("#end ok\n").webServer.known == "cannot")
        #expect(read("os=\nkernel=\ncpus=lots\n#end ok\n").cpus.known == "cannot")
        #expect(read("cpus=Infinity\n#end ok\n").cpus.known == "cannot")
        #expect(read("#listeners cannot this server has no tool installed for listing what is listening\n#end ok\n").listeners.why == "This server has no tool installed for listing what is listening.")
    }
    @Test func serviceAndContainerDialectsKeepUnknownStates() {
        #expect(read("init=openrc\n#services ok\nnginx\tstarted\tstarted\t\ncrond\tstopped\tstopped\t\nx\tcrashed\tcrashed\t\n#end ok").services.value?.map(\.state) == [.running, .stopped, .failed])
        #expect(read("init=sysvinit\n#services ok\nnginx\t+\t+\t\ncron\t-\t-\t\nx\t?\t?\t\n#end ok").services.value?.map(\.state) == [.running, .stopped, .unknown])
        #expect(read("#containers ok\na\ti\trestarting\tRestarting\t\nb\ti\t\tUp\t\n#end ok").containers.value?.map(\.state) == [.unknown, .unknown])
        let listener = read("#listeners ok\n*\t443\t\t\t\n*\tnot-a-number\tx\t1\tu\n#end ok").listeners.value
        #expect(listener?.count == 1); #expect(listener?.first?.pid == nil)
    }
    @Test func installedBrokenAbsentAndUnaskedAgentsAreDifferent() {
        let local = read(BackendServersProbeFixtures.localBin)
        #expect(local.agents.value?.first?.path == "/home/asad/.local/bin/claude")
        #expect(local.agents.value?.first?.version == "2.1.235"); #expect(local.agents.value?.first?.signedIn == .yes)
        #expect(local.agentInstall.value?.memoryAvailableKb == 6412188)
        #expect(read(BackendServersProbeFixtures.noneInstalled).agents.value == [])
        #expect(read("#agents ok\nclaude\t/usr/bin/claude\t\tunknown\t\ncopilot\t/usr/bin/copilot\t1\tno\t\n#end ok").agents.value?.count == 1)
        #expect(read("os=Ubuntu\n").agents.known == "cannot"); #expect(read("os=Ubuntu\n").agentInstall.known == "cannot")
    }
    @Test func probeContainsUnionOfLoginShellAndKnownInstallPaths() {
        let s = BackendServersProbe.script
        #expect(s.contains("$HOME/.local/bin")); #expect(s.contains(".nvm")); #expect(s.contains("command -v claude; command -v codex; command -v gemini"))
        #expect(s.contains(#"PATH="$AW" command -v"#)); #expect(s.contains(BackendServersAgentSignin.agentEnvProbe)); #expect(s.hasSuffix("\n\n"))
        #expect(!s.contains("[[")); #expect(!s.contains("declare ")); #expect(!s.contains("local ")); #expect(!s.contains("<(") ); #expect(!s.contains("$'"))
        #expect(s.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(#"printf '#end ok\n'"#))
        for tool in ["systemctl", "ss", "netstat", "docker", "podman", "nginx"] { #expect(s.contains(tool) && (s.contains("have \(tool)") || s.contains(#""$INIT""#) || s.contains(#""$CTR""#))) }
    }
    @Test func genericFactCodablePreservesThreeStates() throws {
        let facts: [BackendServersFact<String>] = [.yes("a", measuredAt: 1, how: "asked a question"), .no(measuredAt: 2, how: "asked a question"), .cannot(measuredAt: 3, why: "Could not ask.")]
        #expect(try JSONDecoder().decode([BackendServersFact<String>].self, from: JSONEncoder().encode(facts)) == facts)
        let agent = try NativeRPCValue.parseJSON(JSONEncoder().encode(BackendServersAgentFact(id: .codex, path: "/usr/bin/codex", version: "")))
        #expect(agent["account"] == .null)
        let listener = try NativeRPCValue.parseJSON(JSONEncoder().encode(BackendServersListenerFact(address: "*", port: 443)))
        #expect(listener["pid"] == .null)
    }
}
