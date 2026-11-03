import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// #139: Settings › Coding AI › Servers and the Machines screens read one server list, so they cannot disagree.
@Suite("One server list", .serialized)
@MainActor
struct NativeServersOneListTests {
    @Test func theCodingAIServersSeatReadsTheMachinesList() {
        let shared = NativeServersModel.shared
        defer { shared.setFixture(servers: .null) }
        let box: [String: Any] = ["id": "s1", "name": "Box", "address": "box.example.invalid"]
        shared.setFixture(servers: CodingAIJSON([box]))
        let seat = NativeCodingAIServersModel()
        #expect(seat.servers.map(\.id) == ["s1"] && !seat.reading)
        shared.setFixture(servers: CodingAIJSON([box, ["id": "s2", "name": "Store", "address": "store.example.invalid"]]))
        #expect(seat.servers.map(\.id) == ["s1", "s2"])
    }
}
