import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Remote Hoot run ownership, tokens, grace and chat")
struct BackendCopilotRemoteRunsTests: Sendable {
    @Test func tokenIsRegisteredBeforeSpawnAndReReadsKindOnEveryCall() async throws {
        let rig = try await BackendCopilotRemoteTestFixture()
        #expect((await rig.runs.start("phone")).ok)
        #expect(await rig.table.size() == 1)
        #expect(rig.box.read { $0.tokenCountsAtSpawn } == [1])
        let request = try #require(rig.box.read { $0.spawned.first })
        let raw = try NativeRPCValue.parseJSON(Data(contentsOf: URL(fileURLWithPath: request.mcpConfig)))
        let authorization = try #require(raw["mcpServers"]["deck-control"]["headers"]["Authorization"].string)
        #expect(authorization.hasPrefix("Bearer ")); #expect(authorization.count == 71)
        #expect(raw["mcpServers"]["deck-control"]["url"].string == "http://127.0.0.1:5599/mcp")
        #expect(!request.cwd.contains(authorization)); #expect(!request.mcpConfig.contains(authorization))
        let attributes = try FileManager.default.attributesOfItem(atPath: request.mcpConfig)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let grant = try #require(await rig.table.match(authorization: authorization))
        #expect(grant.attended); #expect(await grant.caller().kind == .remote)
        #expect(await grant.caller().tiers == [.read, .act, .alter])
        rig.box.change { $0.mine.remove("phone") }
        #expect(await grant.caller().tiers.isEmpty)
        await rig.runs.revoked("phone")
        #expect(await rig.table.size() == 0); #expect(grant.cancellation.isCancelled)
        #expect(rig.box.read { $0.tokenCountsAtStop } == [0])
        #expect(!FileManager.default.fileExists(atPath: request.mcpConfig))
        #expect(!rig.hidden.contains("run-1"))
        await rig.finish()
    }
    @Test func repeatedAndConcurrentStartsAreIdempotentAndDevicesAreSeparate() async throws {
        let rig = try await BackendCopilotRemoteTestFixture()
        async let first = rig.runs.start("phone")
        async let second = rig.runs.start("phone")
        #expect(await first.ok); #expect(await second.ok)
        #expect((await rig.runs.start("phone")).ok)
        #expect(rig.box.read { $0.spawned.count } == 1)
        #expect((await rig.runs.start("tablet")).ok)
        #expect(await rig.table.size() == 2)
        let phone = try await rig.runs.state("phone"), tablet = try await rig.runs.state("tablet")
        #expect(phone["run"] != tablet["run"])
        #expect(!(await rig.runs.start("guest")).ok)
        await rig.finish()
    }
    @Test func failedStartLeavesNoConfigOrRegisteredCallerAndDoesNotLeakPath() async throws {
        let rig = try await BackendCopilotRemoteTestFixture(spawnFails: true)
        let outcome = await rig.runs.start("phone")
        #expect(!outcome.ok); #expect(outcome.code == "unavailable")
        #expect(!(outcome.message ?? "").contains("test-secret-path"))
        #expect(await rig.table.size() == 0)
        #expect(!FileManager.default.fileExists(atPath: rig.directory.appendingPathComponent("copilot/" + BackendCopilotRemoteSurface.runConfigName("phone")).path))
        await rig.finish()
    }
    @Test func revocationDuringSlowSpawnDropsPendingTokenBeforeProcessReturns() async throws {
        let gate = BackendCopilotRemoteTestStartGate()
        let rig = try await BackendCopilotRemoteTestFixture(startGate: gate)
        let starting = Task { await rig.runs.start("phone") }
        await gate.waitUntilPaused()
        #expect(await rig.table.size() == 1)
        rig.box.change { $0.mine.remove("phone") }
        await rig.runs.revoked("phone")
        #expect(await rig.table.size() == 0)
        await gate.release()
        #expect(!(await starting.value).ok)
        #expect(rig.box.read { $0.stopped } == ["run-1"])
        #expect(!rig.hidden.contains("run-1"))
        await rig.finish()
    }
    @Test func missingEndpointRefusesBeforeAnyProcessStarts() async throws {
        let rig = try await BackendCopilotRemoteTestFixture(endpointAvailable: false)
        #expect(!(await rig.runs.start("phone")).ok)
        #expect(rig.box.read { $0.spawned.isEmpty })
        let state = try await rig.runs.state("phone")
        #expect(state["available"].bool == false); #expect(state["reason"].string != nil)
        await rig.finish()
    }
    @Test func ownCancelAndStopCannotReachOtherRunsAndAreHiddenFromFanout() async throws {
        let rig = try await BackendCopilotRemoteTestFixture()
        #expect((await rig.runs.start("phone")).ok)
        #expect(rig.hidden.contains("run-1")); #expect(rig.runs.isRunSession("run-1"))
        #expect(!(await rig.runs.cancel("tablet")).ok); #expect(!(await rig.runs.stop("tablet")).ok)
        #expect(rig.box.read { $0.interrupted.isEmpty && $0.stopped.isEmpty })
        #expect((await rig.runs.cancel("phone")).ok)
        #expect(rig.box.read { $0.interrupted } == ["run-1"])
        #expect((await rig.runs.stop("phone")).ok)
        #expect(!rig.hidden.contains("run-1")); #expect(!rig.runs.isRunSession("run-1"))
        await rig.finish()
    }
    @Test func stopFailureNeverExposesPossiblyLivePTY() async throws {
        let rig = try await BackendCopilotRemoteTestFixture(stopFails: true)
        #expect((await rig.runs.start("phone")).ok)
        _ = await rig.runs.stop("phone")
        #expect(await rig.table.size() == 0); #expect(rig.hidden.contains("run-1"))
        await rig.finish()
    }
    @Test func revocationWithUnchangedKindKeepsRunButQuitReleasesAllRuns() async throws {
        let rig = try await BackendCopilotRemoteTestFixture()
        _ = await rig.runs.start("phone"); _ = await rig.runs.start("tablet")
        await rig.runs.revoked("phone")
        #expect(await rig.table.size() == 2); #expect(rig.box.read { $0.stopped.isEmpty })
        await rig.runs.stopAll()
        #expect(await rig.table.size() == 0); #expect(!rig.hidden.contains("run-1")); #expect(!rig.hidden.contains("run-2"))
        #expect(rig.box.read { $0.stopped.sorted() } == ["run-1", "run-2"])
        await rig.finish()
    }
    @Test func graceOnlyBeginsWhenLastWatcherLeavesAndReconnectionCancelsIt() async throws {
        let rig = try await BackendCopilotRemoteTestFixture(), first = BackendCopilotRemoteTestRecorder(), second = BackendCopilotRemoteTestRecorder()
        let one = await rig.watch("phone", recorder: first), two = await rig.watch("phone", recorder: second)
        _ = await rig.runs.start("phone")
        await rig.runs.unwatch(one); rig.advance(600_000)
        #expect(try await rig.runs.state("phone")["run"].string == "run-1")
        await rig.runs.unwatch(two); rig.advance(59_000)
        #expect(try await rig.runs.state("phone")["run"].string == "run-1")
        let again = BackendCopilotRemoteTestRecorder()
        let third = await rig.watch("phone", recorder: again)
        let reset = await again.next(.copilotChat)
        #expect(reset.value["reset"].bool == true); #expect(reset.value["run"].string == "run-1")
        rig.advance(600_000); #expect(try await rig.runs.state("phone")["run"].string == "run-1")
        await rig.runs.unwatch(third); rig.advance(60_001)
        #expect(try await rig.runs.state("phone")["run"] == .null)
        #expect(!rig.hidden.contains("run-1")); #expect(await rig.table.size() == 0)
        await rig.finish()
    }
    @Test func unobservedRunTimesOutAndDeadProcessIsForgottenBeforeNextStart() async throws {
        let rig = try await BackendCopilotRemoteTestFixture()
        _ = await rig.runs.start("phone"); rig.advance(60_001)
        #expect(try await rig.runs.state("phone")["run"] == .null)
        _ = await rig.runs.start("phone"); rig.box.change { $0.alive.remove("run-2") }
        #expect(try await rig.runs.state("phone")["run"] == .null)
        _ = await rig.runs.start("phone")
        #expect(rig.box.read { $0.spawned.count } == 3)
        await rig.finish()
    }
    @Test func chatHasResetBaselineIsDeviceScopedBoundedAndDropsStaleUpdates() async throws {
        let rig = try await BackendCopilotRemoteTestFixture(), mine = BackendCopilotRemoteTestRecorder(), other = BackendCopilotRemoteTestRecorder()
        _ = await rig.watch("phone", recorder: mine); _ = await rig.watch("tablet", recorder: other)
        _ = await rig.runs.start("phone")
        #expect(await mine.all(.copilotChat).first?.value["reset"].bool == true)
        await rig.emit("run-1", text: String(repeating: "x", count: 8692))
        let chat = try #require(await mine.all(.copilotChat).last)
        #expect(chat.value["messages"].elements?.count == 1)
        #expect(chat.value["messages"].elements?.first?["text"].string?.utf16.count == 8192)
        #expect(chat.value["messages"].elements?.first?["truncated"].bool == true)
        #expect(await other.all(.copilotChat).isEmpty)
        let previous = await mine.all(.copilotChat).count
        _ = await rig.runs.stop("phone"); await rig.emit("run-1", text: "late")
        #expect(await mine.all(.copilotChat).count == previous)
        await rig.finish()
    }
    @Test func stateSeparatesDeskAndOwnRunAndScanIsOneMachineWrite() async throws {
        let rig = try await BackendCopilotRemoteTestFixture()
        let idle = try await rig.runs.state("phone")
        #expect(idle["desk"].string == "running"); #expect(idle["run"] == .null)
        #expect(idle["grant"] == BackendCopilotRemoteGrant.full.wireValue)
        #expect(idle["tools"].number == 11); #expect(idle["turnTokens"].number == 900)
        try await rig.runs.setInteractive(false); try await rig.runs.setInteractive(true)
        #expect(rig.box.read { $0.interactiveWrites } == [false, true])
        #expect(try await rig.runs.state("phone")["interactive"].bool == true)
        await rig.finish()
    }
    @Test func logRequestsAreClampedAndSayStartsOwnRunInOneStep() async throws {
        let rig = try await BackendCopilotRemoteTestFixture()
        _ = try await rig.runs.log(limit: 100000); _ = try await rig.runs.log(limit: 0)
        _ = try await rig.runs.log(limit: .nan); _ = try await rig.runs.log()
        #expect(rig.box.read { $0.logLimits } == [200, 1, 200, 200])
        #expect((await rig.runs.say("phone", text: "which session is stuck?")).ok)
        #expect(rig.box.read { $0.spawned.count } == 1)
        #expect(rig.box.read { $0.said.first?.0 } == "run-1")
        #expect(rig.box.read { $0.said.first?.1 } == "which session is stuck?")
        await rig.finish()
    }
    @Test func inputFailuresHaveExactSanitizedRefusalAndConfigNamesAreBounded() async throws {
        let rig = try await BackendCopilotRemoteTestFixture(sayFails: true, interruptFails: true)
        #expect((await rig.runs.say("phone", text: "hello")).message == "Hoot did not take that message.")
        #expect((await rig.runs.cancel("phone")).message == "Hoot did not take the interrupt.")
        #expect(BackendCopilotRemoteSurface.runConfigName("phone-1") == "deck-control-device-phone-1.json")
        #expect(!BackendCopilotRemoteSurface.runConfigName("../../etc/passwd").contains(".."))
        #expect(!BackendCopilotRemoteSurface.runConfigName("../../etc/passwd").contains("/"))
        #expect(BackendCopilotRemoteSurface.runConfigName("") == "deck-control-device-unnamed.json")
        #expect(BackendCopilotRemoteSurface.runConfigName(String(repeating: "a", count: 500)).count < 120)
        await rig.finish()
    }
}
