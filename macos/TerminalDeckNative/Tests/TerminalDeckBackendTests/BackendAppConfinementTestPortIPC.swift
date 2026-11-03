import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend
final class BackendAppConfinementTestPortIPC: XCTestCase {
    func testRegistersAllSourceChannelsOnMac() { XCTAssertEqual(BackendAppConfinementChannels.channels, ["confine:grant", "confine:state", "confine:withdraw"]) }
    func testMacStateIsConfinedWithoutGrant() throws {
        let value = try BackendAppConfinementChannels().invoke("confine:state", args: [], context: .init(caller: .nativeApp, ownerID: "fixture"))
        XCTAssertEqual(value["confining"].bool, true); XCTAssertEqual(value["canGrant"].bool, false)
    }
    func testMacGrantIsNoOpAndStillConfined() throws {
        let value = try BackendAppConfinementChannels().invoke("confine:grant", args: [], context: .init(caller: .nativeApp, ownerID: "fixture"))
        XCTAssertEqual(value["result"], .null); XCTAssertEqual(value["state"]["confining"].bool, true)
    }
}
