import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("General keep-awake at boot")
@MainActor struct Fix29a2AwakeTests {
    @Test func restoredGeneralSettingHoldsBeforeAnyPhoneOrUserFilesExist() throws {
        var starts = 0
        var released: [UInt32] = []
        let awake = BackendMacReachAwake(create: { starts += 1; return 29 }, release: { released.append($0) })
        #expect(starts == 0)
        let saved = try NativeRPCValue.object([.init("systemKeepAwake", .bool(true)), .init("allowed", .bool(false))]).encodedJSON()
        awake.update(enabled: MacReach.bootKeepsAwake(try NativeRPCValue.parseJSON(saved)))
        #expect(awake.active && starts == 1)
        awake.update(enabled: true)
        #expect(starts == 1 && released.isEmpty)
        awake.update(enabled: false)
        #expect(!awake.active && released == [29])
        awake.stop()
        #expect(released == [29])
    }
    @Test func assertionFailureIsReportedAndNextExplicitUpdateCanRecover() {
        var allowed = false
        let awake = BackendMacReachAwake(create: { allowed ? 29 : nil }, release: { _ in })
        awake.update(enabled: true)
        #expect(!awake.active && awake.problem != nil)
        allowed = true
        awake.update(enabled: true)
        #expect(awake.active && awake.problem == nil)
        awake.stop()
    }
    @Test func bootAssertionIsTakenBeforeNetworkAndTrustChecks() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckSessionHostHelper/MacReachDaemon.swift"), encoding: .utf8)
        let assertion = try #require(source.range(of: "updateAwake() // Hold before networking"))
        let listener = try #require(source.range(of: "listener.resume()"))
        #expect(assertion.lowerBound < listener.lowerBound)
        #expect(!source.contains("preferences.keepAwake"))
    }
}
