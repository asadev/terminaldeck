import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Server guests require the direct link", .serialized)
struct BackendServerDirectGuestTests {
    @Test("a server without the link is refused instead of keeping relay data")
    func oldServerIsRefused() async throws {
        let guest = BackendRemoteServeMachinesTestsFixture.guest()
        try await guest.feedForTest(#"{"t":"welcome","protocol":1,"deviceId":"device-1","deviceName":"Test Mac","token":null,"sessions":[],"capabilities":["create"],"hostKind":"headless","hostPlatform":"linux"}"#)
        let state = await guest.state()
        #expect(state.phase == .error)
        #expect(state.reason == "Update the host on your server to connect directly.")
        #expect(state.sessions.isEmpty)
    }

    @Test("a server cannot use relay data when this computer has no usable link")
    func serverWithoutUsableLinkIsRefused() async throws {
        let guest = BackendRemoteServeMachinesTestsFixture.guest()
        try await guest.feedForTest(#"{"t":"welcome","protocol":1,"deviceId":"device-1","deviceName":"Test Mac","token":null,"sessions":[],"capabilities":["link.dc2","link.only"],"hostKind":"headless","hostPlatform":"linux"}"#)
        let state = await guest.state()
        #expect(state.phase == .error)
        #expect(state.reason == "Can't reach your server — this network blocks the direct connection.")
        #expect(state.linkPath.isEmpty)
    }
}
