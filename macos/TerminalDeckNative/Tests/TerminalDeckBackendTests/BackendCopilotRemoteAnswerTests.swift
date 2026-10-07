import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Phone approval decides a real gated call and records who approved")
struct BackendCopilotRemoteAnswerTests: Sendable {
    private func gate(_ rig: BackendCopilotRemoteTestFixture) throws -> (BackendDeckCoreSecurityControl, BackendDeckCoreSecurityActionLog) {
        let log = BackendDeckCoreSecurityActionLog(directory: rig.directory.appendingPathComponent("log"))
        let metadata = try #require(BackendDeckCoreCatalogueLiterals.builtins().first { $0.tool.id == "settings.write" })
        let policy = BackendDeckCoreSecurityToolPolicy(tool: metadata.tool, summary: { _, _ in "Change appearance.density to compact" }, run: { _, _ in
            rig.box.change { $0.applied += 1 }; return .init(value: .object([.init("appearance.density", .string("compact"))]))
        })
        return (try .init(log: log, consent: rig.broker, policies: [policy], onRow: { try await rig.runs.publishTool($0) }), log)
    }
    private var args: NativeRPCValue { .object([.init("scope", .string("settings")), .init("patch", .object([.init("appearance.density", .string("compact"))]))]) }
    @Test func ownDeviceIsAskedWithArgumentsAndCallRunsOnlyAfterApproval() async throws {
        let rig = try await BackendCopilotRemoteTestFixture(), recorder = BackendCopilotRemoteTestRecorder()
        _ = await rig.watch("phone", recorder: recorder)
        let (control, log) = try gate(rig)
        let call = Task { await control.call(name: "settings.write", arguments: args, options: .init(caller: .init(kind: .remote, tiers: [.read, .act, .alter], deviceID: "phone"))) }
        let question = await recorder.next(.copilotAsk).value["question"]
        #expect(question["args"] == args); #expect(question["origin"].string == "device:phone"); #expect(question["tier"].string == "alter")
        #expect(rig.box.read { $0.applied } == 0)
        #expect(await rig.runs.answer("phone", id: question["id"].string!, approved: true))
        let result = await call.value
        #expect(result.ok); #expect(rig.box.read { $0.applied } == 1)
        #expect(result.row["caller"]["deviceId"].string == "phone")
        #expect(result.row["confirmed"]["by"].string == "device:phone")
        #expect(result.row["detail"].string?.contains("allowed on a connected device") == true)
        #expect(result.row["detail"].string?.contains("allowed by the person") == false)
        #expect(await log.tail(10).last?["confirmed"]["by"].string == "device:phone")
        let settled = await recorder.next(.copilotSettled).value["settled"]
        #expect(settled["granted"].bool == true); #expect(settled["by"].string == "device:phone")
        #expect(!(await rig.runs.answer("phone", id: question["id"].string!, approved: true)))
        #expect(!(await rig.broker.respond(id: question["id"].string!, approved: true, by: "window")))
        await rig.finish()
    }
    @Test func anotherDeviceCannotSeeArgsOrAnswerAndDeclineIsFirstClass() async throws {
        let rig = try await BackendCopilotRemoteTestFixture(), mine = BackendCopilotRemoteTestRecorder(), other = BackendCopilotRemoteTestRecorder()
        _ = await rig.watch("phone", recorder: mine); _ = await rig.watch("tablet", recorder: other)
        let (control, _) = try gate(rig)
        let call = Task { await control.call(name: "settings.write", arguments: args, options: .init(caller: .init(kind: .remote, tiers: [.read, .act, .alter], deviceID: "phone"))) }
        let question = await mine.next(.copilotAsk).value["question"], id = question["id"].string!
        #expect(await other.all(.copilotAsk).isEmpty)
        let pending = await rig.runs.pending("tablet")
        #expect(pending.first?["mine"].bool == false); #expect(pending.first?["args"] == .missing)
        #expect(!(await rig.runs.answer("tablet", id: id, approved: true)))
        #expect(await rig.broker.list().count == 1)
        #expect(await rig.runs.answer("phone", id: id, approved: false))
        let result = await call.value
        #expect(!result.ok); #expect(result.refusal == .declined)
        #expect(result.row["confirmed"]["by"].string == "device:phone")
        #expect(rig.box.read { $0.applied } == 0)
        await rig.finish()
    }
    @Test func desktopAnswerWinsRaceAndWithdrawsDeviceDialogWithItsSurface() async throws {
        let rig = try await BackendCopilotRemoteTestFixture(), recorder = BackendCopilotRemoteTestRecorder()
        _ = await rig.watch("phone", recorder: recorder)
        let (control, _) = try gate(rig)
        let call = Task { await control.call(name: "settings.write", arguments: args, options: .init(caller: .init(kind: .remote, tiers: [.read, .act, .alter], deviceID: "phone"))) }
        let id = await recorder.next(.copilotAsk).value["question"]["id"].string!
        #expect(await rig.broker.respond(id: id, approved: true, by: "window"))
        let result = await call.value
        #expect(result.ok); #expect(result.row["confirmed"]["by"].string == "window")
        #expect(result.row["detail"].string?.contains("allowed by the person") == true)
        #expect(await recorder.next(.copilotSettled).value["settled"]["by"].string == "window")
        #expect(!(await rig.runs.answer("phone", id: id, approved: true)))
        await rig.finish()
    }
    @Test func disconnectDefaultsToCallerGone() async throws {
        let rig = try await BackendCopilotRemoteTestFixture(), recorder = BackendCopilotRemoteTestRecorder()
        _ = await rig.watch("phone", recorder: recorder)
        let (control, _) = try gate(rig)
        let call = Task { await control.call(name: "settings.write", arguments: args, options: .init(caller: .init(kind: .remote, tiers: [.read, .act, .alter], deviceID: "phone"))) }
        _ = await recorder.next(.copilotAsk)
        await rig.runs.closed("phone")
        #expect((await call.value).refusal == .callerGone); #expect(rig.box.read { $0.applied } == 0)
        // Broker ownership rule itself keeps local questions off device answers.
        #expect(!BackendDeckCoreSecurityConsentBroker.mayAnswerFor(origin: "window", by: "device:phone"))
        #expect(BackendDeckCoreSecurityConsentBroker.mayAnswerFor(origin: "window", by: "window"))
        await rig.finish()
    }
    @Test func disconnectLeavesAnActualDesktopQuestionWaitingAndItsApprovalAttributionLocal() async throws {
        let rig = try await BackendCopilotRemoteTestFixture(desktopAttached: true), recorder = BackendCopilotRemoteTestRecorder()
        _ = await rig.watch("phone", recorder: recorder)
        let (control, _) = try gate(rig)
        let call = Task { await control.call(name: "settings.write", arguments: args) }
        _ = await recorder.next(.copilotPending)
        let question = try #require(await rig.broker.list().first)
        #expect(question.origin == "window")
        await rig.runs.closed("phone")
        #expect(await rig.broker.list().map(\.id) == [question.id])
        #expect(await rig.broker.respond(id: question.id, approved: true, by: "window"))
        let result = await call.value
        #expect(result.ok); #expect(result.row["confirmed"]["by"].string == "window")
        #expect(result.row["detail"].string?.contains("allowed by the person") == true)
        await rig.finish()
    }
    @Test func timeoutStillRefusesAndKeyQuestionsGoToAllOwnerApprovers() async throws {
        let rig = try await BackendCopilotRemoteTestFixture(timeoutMilliseconds: 1), first = BackendCopilotRemoteTestRecorder(), second = BackendCopilotRemoteTestRecorder()
        _ = await rig.watch("phone", recorder: first); _ = await rig.watch("tablet", recorder: second)
        let (control, _) = try gate(rig)
        let result = await control.call(name: "settings.write", arguments: args, options: .init(caller: .init(kind: .remote, tiers: [.read, .act, .alter], deviceID: "phone")))
        #expect(result.refusal == .timeout); #expect(rig.box.read { $0.applied } == 0)
        let question = BackendDeckCoreSecurityConsentRequest(id: "outside", tool: "settings.write", tier: .alter, summary: "Change density", arguments: args,
            requestedAt: 0, expiresAt: 45000, origin: "key:k1", label: "ChatGPT", askedBy: "ChatGPT")
        #expect(await rig.runs.ask(question))
        #expect(await first.all(.copilotAsk).last?.value["question"]["origin"].string == "ChatGPT")
        #expect(await second.all(.copilotAsk).last?.value["question"]["origin"].string == "ChatGPT")
        #expect(BackendDeckCoreSecurityConsentBroker.mayAnswerFor(origin: "key:k1", by: "device:tablet"))
        await rig.finish()
    }
}
