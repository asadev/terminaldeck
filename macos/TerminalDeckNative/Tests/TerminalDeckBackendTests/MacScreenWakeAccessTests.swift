import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Phone screen wake access")
struct MacScreenWakeAccessTests {
    @Test func onlyOwnDeviceOrExplicitFullCanWake() {
        for kind in [BackendRemoteDeviceKind.mine, .guest] {
            let levels: [BackendINT2PhoneAccessLevel?] = [nil, .look, .work, .full]
            for level in levels {
                let context = BackendRemoteHostContext(connectionID: UUID(), deviceID: "fixture", kind: kind,
                    address: "fixture", peerPublicKey: nil, claimedCapabilities: [],
                    reach: .init(kind: kind, unrestricted: kind == .mine, folders: [], accounts: nil, drivesWindows: false), phoneAccess: level)
                #expect(BackendPhoneDevices.mayWakeMac(context) == (level == .full || (level == nil && kind == .mine)))
            }
        }
    }
    @Test func wakePermissionDoesNotEscapeTheRequest() async {
        #expect(!MacScreenAvailability.mayWake)
        await MacScreenAvailability.$mayWake.withValue(true) {
            #expect(MacScreenAvailability.mayWake)
            await Task { #expect(MacScreenAvailability.mayWake) }.value
        }
        #expect(!MacScreenAvailability.mayWake)
    }
}
