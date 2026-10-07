import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckToolsMachinesPortMachineTests: XCTestCase {
    typealias V = NativeRPCValue
    private let o = BackendDeckToolsMachinesPortObject
    func testMachineRowsJoinCorrectLinkAndSessionWords() async throws {
        let area = BackendDeckToolsMachinesPortMachineArea(.init(["machines:list": BackendDeckToolsMachinesPortView()])), out = try await area.run("machines.look", .object([]), BackendDeckToolsMachinesPortContext())
        BackendDeckToolsMachinesPortEqual(out.value["thisComputer"], .string("Mac mini")); let row = try XCTUnwrap(out.value["machines"].elements?.first)
        BackendDeckToolsMachinesPortEqual(row["id"], .string("m1")); BackendDeckToolsMachinesPortEqual(row["online"], .bool(true)); BackendDeckToolsMachinesPortEqual(row["folders"], .array([.string("/work")]))
        let session = try XCTUnwrap(row["sessions"].elements?.first); BackendDeckToolsMachinesPortEqual(session["id"], .string("s-theirs")); BackendDeckToolsMachinesPortEqual(session["folder"], .string("/work")); BackendDeckToolsMachinesPortEqual(session["agent"], .string("claude")); BackendDeckToolsMachinesPortEqual(session["status"], .string("waiting"))
    }
    func testSessionLookNeverRefreshesExpensiveUsage() async throws {
        let channels = BackendDeckToolsMachinesPortChannels(["machines:list": BackendDeckToolsMachinesPortView(), "machines:controls:read": o(["model": .string("opus")]), "machines:account:read": o(["account": .string("work")])])
        await channels.onCall { channel, args in channel == "machines:usage:read" ? BackendDeckToolsMachinesPortObject(["want": args[2]]) : nil }
        let out = try await BackendDeckToolsMachinesPortMachineArea(channels).run("machines.look", o(["machineId": .string("m1"), "sessionId": .string("s-theirs")]), BackendDeckToolsMachinesPortContext()), reads = await channels.seen("machines:usage:read")
        BackendDeckToolsMachinesPortEqual(Set(reads.compactMap { $0[2].string }), ["plan", "context"]); XCTAssertTrue(reads.allSatisfy { $0[3] == .bool(false) }); BackendDeckToolsMachinesPortEqual(out.value["screen"], .null); XCTAssertTrue(out.value["screenNote"].string?.contains("watch") == true)
    }
    func testLookingRefusesPairedDeviceBeforeCalls() async throws {
        let channels = BackendDeckToolsMachinesPortChannels(), area = BackendDeckToolsMachinesPortMachineArea(channels)
        do { _ = try await area.policy(BackendDeckToolsMachinesPortSpec("machines.look"), .object([]), BackendDeckToolsMachinesPortContext(.remote)); XCTFail("remote admitted") } catch { XCTAssertTrue(error.localizedDescription.contains("A paired device cannot")) }
        let calls = await channels.all(); XCTAssertTrue(calls.isEmpty)
    }
    func testStartLearnsNewIDFromSubscribedPush() async throws {
        let registry = NativeChannelRegistry(), channels = BackendDeckToolsMachinesPortChannels(["machines:list": BackendDeckToolsMachinesPortView()]), clock = BackendDeckToolsMachinesPortClockFake(), ledger = BackendDeckToolsMachinesPortLedger()
        await channels.onCall { channel, _ in if channel == "machines:create" { try await registry.publish("machines:state", arguments: [BackendDeckToolsMachinesPortView(["s-theirs", "s-new"])]); return .bool(true) }; return nil }
        let area = BackendDeckToolsMachinesPortMachineArea(channels, registry: registry, clock: clock), out = try await area.run("machines.session", o(["machineId": .string("m1"), "do": .string("start"), "folder": .string("/work"), "agent": .string("claude")]), BackendDeckToolsMachinesPortContext(ledger: ledger))
        let remembered = await ledger.has(BackendDeckToolsMachinesArea.startedKey("m1", "s-new")), calls = await channels.seen("machines:create")
        BackendDeckToolsMachinesPortEqual(out.value["id"], .string("s-new")); XCTAssertTrue(remembered); BackendDeckToolsMachinesPortEqual(calls, [[.string("m1"), .string("/work"), .string("claude")]])
    }
    func testPermissionAndLoginSwitchStayAlterEvenWhenOwn() async throws {
        let ledger = BackendDeckToolsMachinesPortLedger(); await ledger.note(BackendDeckToolsMachinesArea.startedKey("m1", "s-mine"))
        let area = BackendDeckToolsMachinesPortMachineArea(.init()), spec = try BackendDeckToolsMachinesPortSpec("machines.session"), context = BackendDeckToolsMachinesPortContext(ledger: ledger)
        let common = o(["machineId": .string("m1"), "sessionId": .string("s-mine"), "do": .string("set"), "control": .string("permission"), "value": .string("x")])
        let permission = try await area.policy(spec, common, context), model = try await area.policy(spec, common.setting("control", .string("model")), context), login = try await area.policy(spec, o(["machineId": .string("m1"), "sessionId": .string("s-mine"), "do": .string("switch-login"), "loginId": .string("a")]), context)
        BackendDeckToolsMachinesPortEqual(permission.tier, .alter); BackendDeckToolsMachinesPortEqual(model.tier, .act); BackendDeckToolsMachinesPortEqual(login.tier, .alter)
    }
    func testNamedKeysWriteTerminalBytesSeparatelyWithFakeGap() async throws {
        let channels = BackendDeckToolsMachinesPortChannels(["machines:list": BackendDeckToolsMachinesPortView(), "machines:send": o(["ok": .bool(true), "message": .string("sent")])]), clock = BackendDeckToolsMachinesPortClockFake()
        _ = try await BackendDeckToolsMachinesPortMachineArea(channels, clock: clock).run("machines.session", o(["machineId": .string("m1"), "sessionId": .string("s-theirs"), "do": .string("keys"), "keys": .array([.string("up"), .string("enter")])]), BackendDeckToolsMachinesPortContext())
        let calls = await channels.seen("machines:send"); BackendDeckToolsMachinesPortEqual(calls, [[.string("m1"), .string("s-theirs"), .string("\u{1b}[A")], [.string("m1"), .string("s-theirs"), .string("\r")]]); BackendDeckToolsMachinesPortEqual(clock.sleepValues(), [50])
    }
    func testNewlineRefusedBeforeConsentSentence() async throws {
        let area = BackendDeckToolsMachinesPortMachineArea(.init())
        do { _ = try await area.policy(BackendDeckToolsMachinesPortSpec("machines.session"), o(["machineId": .string("m1"), "sessionId": .string("s1"), "do": .string("send"), "text": .string("a\nrm -rf")]), BackendDeckToolsMachinesPortContext()); XCTFail("control text admitted") } catch { XCTAssertTrue(error.localizedDescription.contains("printable")) }
    }
    func testLineAndReturnAreSeparateAndUnsubmittedDraftHasNoReturn() async throws {
        let channels = BackendDeckToolsMachinesPortChannels(["machines:list": BackendDeckToolsMachinesPortView(), "machines:send": o(["ok": .bool(true), "message": .string("sent")])]), clock = BackendDeckToolsMachinesPortClockFake(), area = BackendDeckToolsMachinesPortMachineArea(channels, clock: clock)
        let common = o(["machineId": .string("m1"), "sessionId": .string("s-theirs"), "do": .string("send"), "text": .string("hello")])
        _ = try await area.run("machines.session", common, BackendDeckToolsMachinesPortContext()); _ = try await area.run("machines.session", common.setting("text", .string("draft")).setting("submit", .bool(false)), BackendDeckToolsMachinesPortContext())
        let calls = await channels.seen("machines:send"); BackendDeckToolsMachinesPortEqual(calls.map { $0[2] }, [.string("hello"), .string("\r"), .string("draft")]); BackendDeckToolsMachinesPortEqual(clock.sleepValues(), [50])
    }
    func testMissingRemoteSessionIsNamed() async throws { do { _ = try await BackendDeckToolsMachinesPortMachineArea(.init(["machines:list": BackendDeckToolsMachinesPortView()])).run("machines.session", o(["machineId": .string("m1"), "sessionId": .string("nope"), "do": .string("stop")]), BackendDeckToolsMachinesPortContext()); XCTFail("missing session admitted") } catch { XCTAssertTrue(error.localizedDescription.contains("no session nope")) } }
    func testCachedMachineListRefusesGhostBeforeQuestion() async throws {
        let area = BackendDeckToolsMachinesPortMachineArea(.init(["machines:list": BackendDeckToolsMachinesPortView()])); _ = try await area.run("machines.look", .object([]), BackendDeckToolsMachinesPortContext())
        do { _ = try await area.policy(BackendDeckToolsMachinesPortSpec("machines.manage"), o(["do": .string("forget"), "machineId": .string("ghost")]), BackendDeckToolsMachinesPortContext()); XCTFail("ghost admitted") } catch { XCTAssertTrue(error.localizedDescription.contains("no machine with the id ghost")) }
    }
    func testUploadForbiddenPathsNameCredentialsOrAbsoluteRule() async throws {
        let area = BackendDeckToolsMachinesPortMachineArea(.init())
        for path in ["/fixture/home/.ssh/id_ed25519", "/fixture/data/machines.json", "relative.txt"] {
            do { _ = try await area.policy(BackendDeckToolsMachinesPortSpec("machines.upload"), o(["machineId": .string("m1"), "do": .string("send"), "path": .string(path)]), BackendDeckToolsMachinesPortContext()); XCTFail("forbidden path admitted") } catch { XCTAssertTrue(error.localizedDescription.contains(path == "relative.txt" ? "absolute" : "sign-in keys and credentials")) }
        }
    }
    func testUploadSendingAsksAndCancellationDoesNot() async throws {
        let area = BackendDeckToolsMachinesPortMachineArea(.init()), spec = try BackendDeckToolsMachinesPortSpec("machines.upload"), context = BackendDeckToolsMachinesPortContext()
        let send = try await area.policy(spec, o(["machineId": .string("m1"), "do": .string("send"), "path": .string("/fixture/report.txt")]), context), cancel = try await area.policy(spec, o(["machineId": .string("m1"), "do": .string("cancel")]), context)
        BackendDeckToolsMachinesPortEqual(send.tier, .alter); BackendDeckToolsMachinesPortEqual(cancel.tier, .act)
    }
    func testCopilotReplyIsNewStreamAfterNewQuestionWithFakeClock() async throws {
        let clock = BackendDeckToolsMachinesPortClockFake(), watch = BackendDeckToolsMachinesWatch(clock: clock), channels = BackendDeckToolsMachinesPortChannels(["machines:list": BackendDeckToolsMachinesPortView()])
        await channels.onCall { channel, _ in
            if channel == "machines:copilot:attach" { await watch.pushed("machines:copilot:chat", BackendDeckToolsMachinesPortChat([BackendDeckToolsMachinesPortMessage("1", "you", "earlier"), BackendDeckToolsMachinesPortMessage("2", "agent", "earlier answer")], reset: true)) }
            if channel.hasPrefix("machines:copilot:") { return BackendDeckToolsMachinesPortObject(["ok": .bool(true), "message": .string("sent")]) }; return nil
        }
        let area = BackendDeckToolsMachinesPortMachineArea(channels, watch: watch, clock: clock)
        let arguments = o(["machineId": .string("m1"), "do": .string("say"), "text": .string("is the build green?"), "waitSeconds": .number(30)])
        let pending = Task { try await area.run("machines.copilot", arguments, BackendDeckToolsMachinesPortContext()) }
        await clock.whenScheduled(2)
        await watch.pushed("machines:copilot:chat", BackendDeckToolsMachinesPortChat([BackendDeckToolsMachinesPortMessage("3", "you", "is the build green?"), BackendDeckToolsMachinesPortMessage("4", "agent", "Yes — all")]))
        clock.advance(500)
        await watch.pushed("machines:copilot:chat", BackendDeckToolsMachinesPortChat([BackendDeckToolsMachinesPortMessage("4", "agent", "Yes — all 412 tests pass.")]))
        clock.advance(2_501)
        let out = try await pending.value
        BackendDeckToolsMachinesPortEqual(out.value["answered"], .bool(true)); BackendDeckToolsMachinesPortEqual(out.value["messages"].elements?.last?["text"], .string("Yes — all 412 tests pass.")); await watch.dispose()
    }
    func testDispatcherAsksThenForgetsThroughActualHandler() async throws {
        let channels = BackendDeckToolsMachinesPortChannels(["machines:list": BackendDeckToolsMachinesPortView(), "machines:forget": BackendDeckToolsMachinesPortView().setting("machines", .array([]))]), area = BackendDeckToolsMachinesPortMachineArea(channels), environment = BackendDeckToolsMachinesPortEnvironment()
        let definitions = try await area.definitions(environment: environment), definition = try XCTUnwrap(definitions.first { $0.spec.id == "machines.manage" }), reply = try await definition.handler(BackendDeckToolsMachinesPortNativeContext(), o(["do": .string("forget"), "machineId": .string("m1")]))
        let asks = await environment.questionCount(), calls = await channels.seen("machines:forget")
        XCTAssertFalse(reply.isError); BackendDeckToolsMachinesPortEqual(asks, 1); BackendDeckToolsMachinesPortEqual(calls, [[.string("m1")]])
    }
    func testDispatcherRefusesPhoneWithoutQuestionOrMutation() async throws {
        let channels = BackendDeckToolsMachinesPortChannels(), area = BackendDeckToolsMachinesPortMachineArea(channels), environment = BackendDeckToolsMachinesPortEnvironment(BackendDeckToolsMachinesPortContext(.remote)), definitions = try await area.definitions(environment: environment), definition = try XCTUnwrap(definitions.first { $0.spec.id == "machines.manage" })
        let reply = try await definition.handler(BackendDeckToolsMachinesPortNativeContext(), o(["do": .string("forget"), "machineId": .string("m1")])), asks = await environment.questionCount(), calls = await channels.all()
        XCTAssertTrue(reply.isError); BackendDeckToolsMachinesPortEqual(reply.structuredContent?["refusal"], .string("not-granted")); BackendDeckToolsMachinesPortEqual(asks, 0); XCTAssertTrue(calls.isEmpty)
    }
}
