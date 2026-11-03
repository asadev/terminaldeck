import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// U171 #480: Settings and the Alerts sheet let a device in with one request and one verdict.
@Suite("Letting a device in")
@MainActor
struct RemoteApprovalCallTests {
    @MainActor final class Sent { var channel = ""; var args: [Any?] = [] }

    @Test func oneRequestAndOneVerdict() async throws {
        var approval = RemoteApproval(device: RemoteDevice(id: "d", name: "iPad", state: .pending))
        approval.pick(.guest)
        approval.addFolder("/work")
        let sent = Sent()
        let refused = try await RemoteApprovalCall.approve(approval) { channel, args in
            sent.channel = channel; sent.args = args
            return [["id": "d", "status": "pending"]] as [Any]
        }
        #expect(sent.channel == "remote:device:approve")
        #expect(sent.args.count == 5 && sent.args[0] as? String == "d" && sent.args[1] as? String == "guest")
        #expect(sent.args[2] as? [String] == ["/work"] && sent.args[3] as? String == "all")
        #expect(refused == "iPad is still waiting, so that did not take. Try again from Settings → Remote.")
        let taken = try await RemoteApprovalCall.approve(approval) { _, _ in [["id": "d", "status": "approved"]] as [Any] }
        #expect(taken == nil)
        #expect(try await RemoteApprovalCall.pickFolder { _, _ in "" } == nil)
        #expect(try await RemoteApprovalCall.pickFolder { _, _ in "/work" } == "/work")
    }
}
