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
        let guest = BackendDeckCoreSecurityCaller(kind: .remote, tiers: [], deviceID: "guest")
        for entry in metadata {
            #expect((await control.call(name: entry.tool.id, arguments: .object([]), options: .init(caller: guest))).refusal == .notGranted)
        }
        let acting = BackendDeckCoreSecurityCaller(kind: .remote, tiers: [.read, .act], deviceID: "phone")
        for entry in metadata where entry.tool.tier == .alter {
            #expect((await control.call(name: entry.tool.id, arguments: .object([]), options: .init(caller: acting))).refusal == .notGranted)
        }
        #expect(await approver.asks == 0)
        let alter = try #require(metadata.first { $0.tool.tier == .alter })
        let full = BackendDeckCoreSecurityCaller(kind: .remote, tiers: [.read, .act, .alter], deviceID: "phone")
        let permitted = await control.call(name: alter.tool.id, arguments: .object([]), options: .init(caller: full))
        #expect(permitted.ok); #expect(permitted.row["confirmed"]["required"].bool == true)
        #expect(permitted.row["confirmed"]["granted"].bool == true)
        await broker.stop()
    }
}
