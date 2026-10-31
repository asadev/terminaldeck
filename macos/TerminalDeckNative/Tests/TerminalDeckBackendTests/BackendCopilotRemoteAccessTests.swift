import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Remote Hoot access — paired identity is the authorization")
struct BackendCopilotRemoteAccessTests: Sendable {
    @Test func ownDeviceIsLinkedAndGuestIsNot() async {
        let access = BackendCopilotRemoteAccess(isMine: { $0 == "phone" })
        #expect(await access.linked("phone")); #expect(!(await access.linked("guest")))
    }
    @Test func emptyIDsAndUnreadableKindsFailClosed() async {
        let permissive = BackendCopilotRemoteAccess(isMine: { _ in true })
        #expect(!(await permissive.linked("")))
        let broken = BackendCopilotRemoteAccess(isMine: { _ in throw NativeRPCError(code: "test", message: "unreadable") })
        #expect(!(await broken.linked("phone")))
    }
}
