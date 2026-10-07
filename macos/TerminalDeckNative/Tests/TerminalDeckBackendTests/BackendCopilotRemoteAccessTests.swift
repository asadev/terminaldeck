import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Remote Hoot access — paired identity is the authorization")
struct BackendCopilotRemoteAccessTests: Sendable {
    @Test func ownDeviceHasExactlyThreeTiersAndGuestHasNone() async {
        let access = BackendCopilotRemoteAccess(isMine: { $0 == "phone" })
        #expect(await access.granted("phone") == .full)
        #expect(await access.granted("guest") == .none)
        #expect(await access.linked("phone")); #expect(!(await access.linked("guest")))
        #expect(Set(BackendCopilotRemoteGrant.full.wireValue.fields!.map(\.key)) == ["read", "act", "alter"])
    }
    @Test func emptyIDsAndUnreadableKindsFailClosed() async {
        let permissive = BackendCopilotRemoteAccess(isMine: { _ in true })
        #expect(await permissive.granted("") == .none); #expect(!(await permissive.linked("")))
        let broken = BackendCopilotRemoteAccess(isMine: { _ in throw NativeRPCError(code: "test", message: "unreadable") })
        #expect(await broken.granted("phone") == .none); #expect(!(await broken.linked("phone")))
    }
    @Test func rosterIsFilteredAndCallerReReadsRevocation() async {
        let box = BackendCopilotRemoteTestBox()
        let access = BackendCopilotRemoteAccess(isMine: { id in box.read { $0.mine.contains(id) } })
        #expect(await access.list(["phone", "guest", "tablet"]).map { $0["deviceId"].string! } == ["phone", "tablet"])
        let before = await access.caller("phone")
        #expect(before.kind == .remote); #expect(before.deviceID == "phone"); #expect(before.tiers == [.read, .act, .alter])
        box.change { $0.mine.remove("phone") }
        #expect(await access.caller("phone").tiers.isEmpty)
    }
}
