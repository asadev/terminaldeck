import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

private actor BackendCopilotRemoteTestApprover {
    var broker: BackendDeckCoreSecurityConsentBroker?
    var asks = 0
    func install(_ broker: BackendDeckCoreSecurityConsentBroker) { self.broker = broker }
    func ask(_ question: BackendDeckCoreSecurityConsentRequest) async -> Bool {
        asks += 1
        _ = await broker?.respond(id: question.id, approved: true, by: "window")
        return true
    }
}
@Suite("Remote Hoot is enforced at the actual security dispatcher")
struct BackendCopilotRemoteEnforcementTests: Sendable {
    @Test func readOnlyAndGuestCallersAreDeniedAcrossWholeCoreCatalogueBeforeConsent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCopilotRemoteEnforcement-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let approver = BackendCopilotRemoteTestApprover()
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { await approver.ask($0) })
        await approver.install(broker)
        let metadata = try BackendDeckCoreCatalogueLiterals.builtins()
        #expect(metadata.count > 10)
        let policies = metadata.map { entry in BackendDeckCoreSecurityToolPolicy(tool: entry.tool,
            summary: { _, _ in "A permitted test operation" }, run: { _, _ in .init(value: .bool(true)) }) }
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: directory), consent: broker, policies: policies,
            checkArguments: { _, _ in })
        let watching = BackendDeckCoreSecurityCaller(kind: .remote, tiers: [.read], deviceID: "phone")
        let above = metadata.filter { $0.tool.tier != .read }; #expect(above.count > 3)
        for entry in above {
            let result = await control.call(name: entry.tool.id, arguments: .object([]), options: .init(caller: watching))
            #expect(!result.ok); #expect(result.refusal == .notGranted); #expect(result.row["outcome"].string == "refused")
            #expect(result.row["caller"]["deviceId"].string == "phone")
        }
        #expect(await approver.asks == 0)
        let read = try #require(metadata.first { $0.tool.tier == .read })
        #expect((await control.call(name: read.tool.id, arguments: .object([]), options: .init(caller: watching))).ok)
        let access = BackendCopilotRemoteAccess(isMine: { $0 == "phone" })
        let guest = await access.caller("guest")
        for entry in metadata {
            #expect((await control.call(name: entry.tool.id, arguments: .object([]), options: .init(caller: guest))).refusal == .notGranted)
        }
        let acting = BackendDeckCoreSecurityCaller(kind: .remote, tiers: [.read, .act], deviceID: "phone")
        for entry in metadata where entry.tool.tier == .alter {
            #expect((await control.call(name: entry.tool.id, arguments: .object([]), options: .init(caller: acting))).refusal == .notGranted)
        }
        #expect(await approver.asks == 0)
        let alter = try #require(metadata.first { $0.tool.tier == .alter })
        let full = await access.caller("phone")
        let permitted = await control.call(name: alter.tool.id, arguments: .object([]), options: .init(caller: full))
        #expect(permitted.ok); #expect(permitted.row["confirmed"]["required"].bool == true)
        #expect(permitted.row["confirmed"]["granted"].bool == true)
        await broker.stop()
    }
    @Test func nextToolCallReadsRevocationAndUnreadableKindsAreGuests() async throws {
        let rig = try await BackendCopilotRemoteTestFixture()
        let access = BackendCopilotRemoteAccess(isMine: { id in rig.box.read { $0.mine.contains(id) } })
        let tool = try BackendMCPTool(id: "sessions.list", wireName: "sessions_list", description: "List", inputSchema: .object([.init("type", .string("object"))]), tier: .read)
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: rig.directory.appendingPathComponent("log")), consent: rig.broker,
            policies: [.init(tool: tool, summary: { _, _ in "List sessions" }, run: { _, _ in .init(value: .array([])) })])
        #expect((await control.call(name: tool.id, arguments: .object([]), options: .init(caller: await access.caller("phone")))).ok)
        rig.box.change { $0.mine.remove("phone") }
        #expect((await control.call(name: tool.id, arguments: .object([]), options: .init(caller: await access.caller("phone")))).refusal == .notGranted)
        let broken = BackendCopilotRemoteAccess(isMine: { _ in throw BackendSessionFailure.closed })
        #expect((await control.call(name: tool.id, arguments: .object([]), options: .init(caller: await broken.caller("phone")))).refusal == .notGranted)
        await rig.finish()
    }
    @Test func frameTableKeepsBooleansIndependentAndUnknownCeremonyTagsRefused() {
        let read = BackendCopilotRemoteGrant(read: true, act: false, alter: false)
        for (verb, tier) in BackendCopilotRemoteSurface.frameTier { #expect(BackendCopilotRemoteSurface.allowed(read, verb: verb) == (tier == .read)) }
        let act = BackendCopilotRemoteGrant(read: false, act: true, alter: false)
        #expect(BackendCopilotRemoteSurface.allowed(act, verb: "copilot.say"))
        #expect(!BackendCopilotRemoteSurface.allowed(act, verb: "copilot.state"))
        for verb in BackendCopilotRemoteSurface.frameTier.keys { #expect(!BackendCopilotRemoteSurface.allowed(.none, verb: verb)) }
        for verb in ["copilot.tool", "copilot.approve", "sessions.send"] + Array(BackendCopilotRemoteSurface.untiered) { #expect(!BackendCopilotRemoteSurface.allowed(.full, verb: verb)) }
        #expect(!BackendCopilotRemoteSurface.allowed(read, verb: "copilot.answer"))
        #expect(!BackendCopilotRemoteSurface.allowed(.init(read: true, act: true, alter: false), verb: "copilot.answer"))
        #expect(BackendCopilotRemoteSurface.allowed(.full, verb: "copilot.answer"))
    }
}
