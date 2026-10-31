import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

struct MachineSmallBugsTests {
    @Test func sessionReadsShareADeadlineAndKeepCompletedFields() async {
        let start = ContinuousClock.now
        let result = await BackendMachineMCP.readTogether([
            ("controls", { .string("ready") }),
            ("login", { try await Task.sleep(for: .milliseconds(10)); return .string("signed in") }),
            ("plan", { try await Task.sleep(for: .seconds(5)); return .number(1) }),
            ("context", { try await Task.sleep(for: .seconds(5)); return .number(2) })
        ], milliseconds: 100)
        #expect(result["controls"] == .string("ready"))
        #expect(result["login"] == .string("signed in"))
        #expect(result["plan"] == nil && result["context"] == nil)
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test func completedReadsDoNotWaitForTheDeadline() async {
        let start = ContinuousClock.now
        let result = await BackendMachineMCP.readTogether([("screen", { .string("text") })], milliseconds: 5000)
        #expect(result["screen"] == .string("text"))
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test func onlyDiscoveryReceiveTimeoutMeansCodeNotFound() {
        let timeout = NativeRPCError(code: "machine-timeout", message: "Timed out")
        #expect(BackendMachineCoordinator.discoveryFailure(timeout).code == "pair-not-found")
        let unreachable = NativeRPCError(code: "pair-unreachable", message: "Offline")
        #expect(BackendMachineCoordinator.discoveryFailure(unreachable).code == "pair-unreachable")
        #expect(BackendMachineCoordinator.discoveryFailure(URLError(.cannotConnectToHost)).code == "pair-unreachable")
        #expect(BackendMachineCoordinator.discoveryFailure(NativeRPCError.malformed("Bad offer")).code == "pair-unreachable")
    }
}
