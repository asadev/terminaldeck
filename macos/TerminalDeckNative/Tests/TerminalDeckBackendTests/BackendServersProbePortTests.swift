import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Server probe exact captured facts")
struct BackendServersProbePortTests {
    private func read(_ raw: String) -> BackendServersFacts { BackendServersProbe.parse(raw, serverId: "server-1", measuredAt: 1_000) }
    @Test func administratorMachineFacts() {
        let f = read(BackendServersProbeFixtures.administrator)
        #expect(f.os.value == "Ubuntu 24.04.4 LTS" && f.os.known == "yes"); #expect(f.`init`.value == .systemd); #expect(f.containerRuntime.value == .docker)
        #expect(f.packageManager.value == "apt-get" && f.webServer.value == "caddy" && f.privilege.value == .yes)
    }
    @Test func administratorListenersHaveOwningUnits() {
        let rows = read(BackendServersProbeFixtures.administrator).listeners.value ?? []
        #expect(rows.first { $0.port == 443 }?.unit == "caddy.service"); #expect(rows.first { $0.port == 8787 }?.unit == "terminaldeck-demo-broker.service")
    }
    @Test func administratorAddedServicesDifferFromPackageServices() {
        let added = (read(BackendServersProbeFixtures.administrator).services.value ?? []).filter(\.addedHere).map(\.name)
        #expect(added.contains("terminaldeck-demo-broker.service")); #expect(!added.contains("caddy.service"))
    }
    @Test func administratorSiteNamesComeFromWebSettings() { #expect(read(BackendServersProbeFixtures.administrator).siteNames.value == ["178-105-239-176.sslip.io"]) }
    @Test func failedServiceIsNotMerelyStopped() {
        let rows = read(BackendServersProbeFixtures.administrator).services.value ?? []
        #expect(rows.first { $0.name == "cloud-init-hotplugd.service" }?.state == .failed); #expect(rows.first { $0.name == "caddy.service" }?.state == .running)
    }
    @Test func refusedContainerQuestionExplainsPermission() { let f = read(BackendServersProbeFixtures.ordinary); #expect(f.containerRuntime.known == "cannot"); #expect(f.containerRuntime.why == "This sign-in is not allowed to ask this server about its containers.") }
    @Test func installedSudoIsNotPermission() { #expect(read(BackendServersProbeFixtures.ordinary).privilege == .yes(.sudoPassword, measuredAt: 1_000, how: read(BackendServersProbeFixtures.ordinary).privilege.how ?? "")) }
    @Test func ordinaryUserKeepsPortsAndDropsOnlyOwners() {
        let f = read(BackendServersProbeFixtures.ordinary), rows = f.listeners.value ?? []
        #expect(!rows.isEmpty && rows.map(\.port).contains(443)); #expect(rows.allSatisfy { $0.unit == "" }); #expect(f.listeners.known == "yes")
    }
    @Test func ordinaryUserSeesSameMachineAndSites() { let f = read(BackendServersProbeFixtures.ordinary); #expect(f.os.value == "Ubuntu 24.04.4 LTS" && f.os.known == "yes"); #expect(f.siteNames.value == ["178-105-239-176.sslip.io"]) }
    @Test func containerHasNoKeeper() { let f = read(BackendServersProbeFixtures.container); #expect(f.`init`.value == .containerNone && f.`init`.known == "yes"); #expect(f.services.known == "cannot"); #expect(f.numbersBelongToTheHost) }
    @Test func containerMissingListenerToolIsNotZero() { let f = read(BackendServersProbeFixtures.container); #expect(f.listeners.known == "cannot"); #expect(f.listeners.why == "This server has no tool installed for listing what is listening.") }
    @Test func containerMeasuredAbsentTools() { let f = read(BackendServersProbeFixtures.container); #expect(f.containerRuntime.known == "no" && f.webServer.known == "no") }
    @Test func containerOwnMachineFactsSurvive() { let f = read(BackendServersProbeFixtures.container); #expect(f.os.value == "Debian GNU/Linux 12 (bookworm)" && f.os.known == "yes"); #expect(f.packageManager.value == "apt-get" && f.packageManager.known == "yes") }
    @Test func cutOffSectionIsNotEmptyButArrivedFactsSurvive() throws {
        let raw = BackendServersProbeFixtures.administrator, at = try #require(raw.range(of: "#listeners"))
        let f = read(String(raw[..<at.lowerBound])); #expect(f.listeners.known == "cannot"); #expect(f.listeners.why == "The server stopped answering before it finished this check."); #expect(f.os.known == "yes")
    }
    @Test func emptyScalarsCannotBecomeNo() { let f = read("os=\nkernel=\ncpus=\n#end ok\n"); #expect(f.os.known == "cannot" && f.kernel.known == "cannot" && f.cpus.known == "cannot") }
    @Test func unknownInitOffersNoServices() { let f = read("init=weird\n#end ok\n"); #expect(f.`init`.known == "cannot" && f.services.known == "cannot") }
    @Test func localBinAgentAbsolutePathAndVersion() {
        let a = read(BackendServersProbeFixtures.localBin).agents.value ?? []
        #expect(a.map(\.id) == [.claude]); #expect(a.first?.path == "/home/asad/.local/bin/claude" && a.first?.version == "2.1.235")
    }
    @Test func localBinAgentAccount() { let a = read(BackendServersProbeFixtures.localBin).agents.value?.first; #expect(a?.signedIn == .yes && a?.account == "asad@example.com") }
    @Test func installRoomUsesMeasuredDownloaderMemoryAndDisk() { let r = read(BackendServersProbeFixtures.localBin).agentInstall.value; #expect(r?.downloader == "curl" && r?.memoryAvailableKb == 6_412_188 && r?.homeFreeKb == 417_238_528) }
    @Test func noAgentsIsMeasuredEmptyList() { let f = read(BackendServersProbeFixtures.noneInstalled); #expect(f.agents.known == "yes" && f.agents.value == []) }
    @Test func noDownloaderAndLowMemoryAreSeparateReasons() { let r = read(BackendServersProbeFixtures.noneInstalled).agentInstall.value; #expect(r?.downloader == ""); #expect((r?.memoryAvailableKb ?? .infinity) < 512 * 1024) }
    @Test func brokenAgentIsInstalledUnknownAndHasNoAccount() {
        let a = read("#agents ok\nclaude\t/usr/bin/claude\t\tunknown\t\n#end ok").agents.value ?? []
        #expect(a.count == 1); #expect(a.first?.version == "" && a.first?.signedIn == .unknown && a.first?.account == nil)
    }
    @Test func unknownAgentRowIsDropped() { #expect(read("#agents ok\ncopilot\t/usr/bin/copilot\t1.0\tunknown\t\n#end ok").agents.value == []) }
    @Test func missingAgentsSectionIsCannot() { let f = read("os=Ubuntu\n#services ok\n"); #expect(f.agents.known == "cannot" && f.agentInstall.known == "cannot") }
}

@Suite("Fact third state and container numbers exact field membership")
struct BackendServersFactsPortTests {
    private func fields(_ raw: String, at: Double = 1_000) throws -> [String: NativeRPCValue] {
        let wire = try BackendServersProbe.parse(raw, serverId: "server-1", measuredAt: at).wireValue()
        return Dictionary(uniqueKeysWithValues: (wire.fields ?? []).filter { $0.value.has("known") }.map { ($0.key, $0.value) })
    }
    @Test func timestampCoversAllThreeStates() throws {
        for raw in ["", BackendServersProbeFixtures.administrator, BackendServersProbeFixtures.container] { for (_, f) in try fields(raw, at: 1_234) { #expect(f["measuredAt"].number == 1_234) } }
    }
    @Test func inheritedValuesWerePresentButEveryHostNumberIsCannot() throws {
        let raw = BackendServersProbeFixtures.container, f = try fields(raw)
        #expect(raw.range(of: "disk_total_kb=\\d+", options: .regularExpression) != nil); #expect(raw.range(of: "uptime_s=\\d+", options: .regularExpression) != nil)
        #expect(BackendServersFacts.containerInheritedFacts == ["disk", "memory", "load1", "uptimeSeconds"])
        for name in BackendServersFacts.containerInheritedFacts { #expect(f[name]?["known"].string == "cannot"); #expect(f[name]?["why"].string == BackendServersFacts.containerNumbersWhy) }
    }
    @Test func ownerMachineReportsAllFourNumbers() throws {
        let parsed = BackendServersProbe.parse(BackendServersProbeFixtures.administrator, serverId: "server-1", measuredAt: 1_000), f = try fields(BackendServersProbeFixtures.administrator)
        #expect(!parsed.numbersBelongToTheHost); for name in BackendServersFacts.containerInheritedFacts { #expect(f[name]?["known"].string == "yes") }
    }
    @Test func rawScalarsCannotBypassRefusal() throws { let wire = try BackendServersProbe.parse("", serverId: "s", measuredAt: 1).wireValue(); #expect(!wire.has("scalars")); #expect(wire.has("disk")) }
}
