import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Mac reachability and helper setup")
@MainActor struct MacReachCoreTests {
    @Test func disconnectDoesNotGuessFileVaultOrSleep() {
        #expect(MacReach.state(reachable: false, locked: true, displayAsleep: true) == .unreachable)
        #expect(MacReach.State.unreachable.words == "Mac is asleep or unreachable. Check its power and internet connection.")
    }
    @Test func diskUnlockNeedsIndependentEvidence() {
        #expect(MacReach.state(reachable: false, diskUnlockConfirmed: true) == .diskUnlock)
        #expect(MacReach.state(reachable: true, diskUnlockConfirmed: false) == .desktop)
    }
    @Test func signInAndLockTakePriorityOverSleepingDisplay() {
        #expect(MacReach.state(reachable: true, loginDone: false, displayAsleep: true) == .signingIn)
        #expect(MacReach.state(reachable: true, locked: true, displayAsleep: true) == .locked)
        #expect(MacReach.state(reachable: true, displayAsleep: true) == .asleep)
    }
    @Test func bootFollowsGeneralWithoutPhoneOrPowerConditions() throws {
        let enabled = NativeRPCValue.object([.init("systemKeepAwake", .bool(true))])
        let restored = try NativeRPCValue.parseJSON(enabled.encodedJSON())
        #expect(MacReach.bootKeepsAwake(restored))
        #expect(!MacReach.bootKeepsAwake(.object([.init("systemKeepAwake", .bool(false))])))
        #expect(!MacReach.bootKeepsAwake(.null))
        #expect(!MacReach.bootKeepsAwake(.object([.init("keepAwake", .bool(true))])))
    }
    @Test func onlyAnApprovedOwnerWithFullAccessCanUseSignIn() {
        for kind in ["mine", "guest"] {
            for level in [nil, "look", "hoot", "work", "full"] as [String?] {
                for approved in [true, false] {
                    #expect(MacReach.mayControl(kind: kind, access: level, approved: approved)
                        == (approved && kind == "mine" && (level == nil || level == "full")))
                }
            }
        }
    }
    @Test func bootHasNoShellFileOrPairingCommands() {
        for command in ["create", "input", "enroll", "files.read", "files.write", "panel.act", "hoot.say", "credential.read"] {
            #expect(!MacReach.bootMessages.contains(command))
        }
        #expect(MacReach.bootMessages.contains("sims.unlock"))
        #expect(MacReach.agentSessionTypes == ["Aqua", "LoginWindow"])
    }
    @Test func scratchCannotRegister() throws {
        var calls = 0
        #expect(throws: MacReach.SetupFailure.releaseRequired) {
            try MacReach.enableHelper(isRelease: false, status: { .notRegistered }, register: { calls += 1 })
        }
        #expect(calls == 0)
    }
    @Test func registrationDoesNotPretendApprovalWasGranted() throws {
        var state = MacReach.Registration.notRegistered
        var calls = 0
        let answer = try MacReach.enableHelper(isRelease: true, status: { state }, register: { calls += 1; state = .needsApproval })
        #expect(answer == .needsApproval && calls == 1)
    }
    @Test func alreadyApprovedOrWaitingIsNotRegisteredAgain() throws {
        for state in [MacReach.Registration.enabled, .needsApproval] {
            var calls = 0
            #expect(try MacReach.enableHelper(isRelease: true, status: { state }, register: { calls += 1 }) == state)
            #expect(calls == 0)
        }
    }
    @Test func missingHelperDoesNotRegister() {
        var calls = 0
        #expect(throws: MacReach.SetupFailure.helperMissing) {
            try MacReach.enableHelper(isRelease: true, status: { .notBundled }, register: { calls += 1 })
        }
        #expect(calls == 0)
    }
    @Test func registrationFailureDoesNotBecomeEnabled() {
        enum Refused: Error { case no }
        #expect(throws: Refused.self) {
            try MacReach.enableHelper(isRelease: true, status: { .notRegistered }, register: { throw Refused.no })
        }
    }
    @Test func bundledDaemonStartsAtBootAndUsesTheStableKeeper() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: package.appendingPathComponent("Support/MacReach/" + MacReach.daemonPlist))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/TerminalDeckSessionHostHelper")
        #expect(plist["ProgramArguments"] as? [String] == ["TerminalDeckSessionHostHelper", MacReach.daemonArgument])
        #expect((plist["MachServices"] as? [String: Bool])?[MacReach.daemonLabel] == true)
    }
}
