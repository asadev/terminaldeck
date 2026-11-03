import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Shared fixtures for the S5 session-switch ports (names mirror the TS helpers).
enum S5SwitchFixture {
    static func profile(_ id: String = "home", name: String = "Home", provider: String = "claude", configDir: String = "/cfg/home") -> BackendAccountProfile {
        BackendAccountProfile(id: id, name: name, provider: provider, configDir: configDir, system: false, color: "--status-input", createdAt: 0, lastUsedAt: nil)
    }
    static func saved(_ provider: String = "claude", profileId: String? = "work") throws -> BackendSessionSaved {
        var fields: [NativeRPCValue.Field] = [.init("cwd", .string("/w/app")), .init("provider", .string(provider)),
            .init("cols", .number(100)), .init("rows", .number(30)), .init("lastSeenAt", .number(1))]
        if let profileId { fields.append(.init("profileId", .string(profileId))) }
        return try BackendSessionSaved(.object(fields))
    }
    static func meta(_ id: String = "s1", provider: String = "claude", profileId: String? = "work", profileName: String? = "Work", exited: Bool = false) -> BackendSessionMeta {
        var value = BackendFoundationTestsSessionsFixtures.meta(id, provider: provider, exited: exited)
        value.profileId = profileId; value.profileName = profileName
        return value
    }
    static func plan(refusal: String?, to: BackendAccountProfile?, resume: Bool = false) throws -> BackendSessionSwitchPlan {
        BackendSessionSwitchPlan(sessionID: "s1", refusal: refusal, from: profile("work", name: "Work"), to: to, conversation: "stays",
                                 resume: resume, conversationID: nil, mode: .restart, saved: try saved(), carried: nil)
    }
}

@Suite("S5 switch: wire shapes that exist today")
struct BackendFoundationTestsS5SwitchBasics {
    // TS switch-later.test.ts:511
    @Test func armedNoteNamesTheAccountAndTheMoment() {
        let armed = BackendSessionSwitchDeferred.Armed(sessionID: "s1", accountID: "b", accountName: "Work", armedAt: Date(timeIntervalSince1970: 1))
        let note = armed.wireValue["note"].string ?? ""
        #expect(note.contains("Work")); #expect(note.contains("next message"))
        #expect(armed.wireValue["sessionId"].string == "s1"); #expect(armed.wireValue["profileId"].string == "b")
    }
    // TS session-switch.test.ts:180 (wire half: a refusal plan promises nothing about the conversation)
    @Test func refusalPlanCarriesTheSentenceAndPromisesNothing() throws {
        let wire = try S5SwitchFixture.plan(refusal: "That account no longer exists on this computer.", to: nil).wireValue
        #expect(wire["refusal"].string != nil); #expect(wire["resume"].bool == false); #expect(wire["to"].isNullish)
    }
    // TS session-switch.test.ts:187
    @Test func refusalPlanStillNamesTheAccountTheSessionIsOn() throws {
        let from = try S5SwitchFixture.plan(refusal: "x", to: nil).wireValue["from"]
        #expect(from["id"].string == "work"); #expect(from["name"].string == "Work"); #expect(from["provider"].string == "claude")
    }
    // TS session-switch.test.ts:87 (the two questions stay apart: only the plan channel describes)
    @Test func planChannelDescribesAndAccountChannelActs() {
        #expect(BackendSessionLifecycleRPC.channels.isSuperset(of: ["session:switch-plan", "session:switch-account"]))
    }
}
