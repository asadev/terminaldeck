import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// A save made of several steps that half-fails shows what was really saved, never the state before or the hoped-for one.
@MainActor @Suite
struct HalfFailedSavesTests {
    @Test func taskPeopleShowWhatWasSavedAfterALaterStepIsRefused() async throws {
        var calls: [String] = []
        func person(_ id: String, _ name: String) -> NativeRPCValue { .object([.init("id", .string(id)), .init("name", .string(name))]) }
        let transport = NativeFIXESTaskThreadTransport(invoke: { function, _ in
            calls.append(function)
            switch function {
            case "addTaskAssignee": return .object([.init("ok", .bool(true))])
            case "removeTaskAssignee": return .object([.init("ok", .bool(false)), .init("error", .string("The fixture refused this."))])
            case "fetchTaskDetailBundle":
                // The engine kept the added reviewer and, after the refusal, "You" as well.
                return .object([.init("ok", .bool(true)), .init("bundle", .object([.init("people", .object([
                    .init("primary", person("builder", "portal-mechanic")),
                    .init("others", .array([person("me", "You"), person("reviewer", "portal-reviewer")]))]))]))])
            default: throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected call: " + function])
            }
        }, observe: { _ in .init {} })
        let row = TaskRow(id: "fixture-task", keyId: "local", externalTaskId: "fixture-task", title: "People",
                          project: "/stub/project", local: true, assignee: "builder")
        let model = TaskDetailModel(row: row, agents: [.init(id: "builder", name: "portal-mechanic", icon: "sf:wrench"),
                                                       .init(id: "reviewer", name: "portal-reviewer", icon: "sf:checkmark.seal")],
                                    threadTransport: transport, loadOnOpen: false)
        let builder = CrmPeople.person("builder", "portal-mechanic")
        model.people = TaskPeople(primary: builder, others: [CrmPeople.person("me", "You")])
        model.changePeople(TaskPeople(primary: builder, others: [CrmPeople.person("reviewer", "portal-reviewer")]))
        for _ in 0..<100 where !calls.contains("fetchTaskDetailBundle") { try await Task.sleep(for: .milliseconds(20)) }
        #expect(calls == ["addTaskAssignee", "removeTaskAssignee", "fetchTaskDetailBundle"])
        #expect(model.people?.others.map(\.id) == ["me", "reviewer"])
    }

    @Test func routineSwitchPutsTheFileBackWhenTheScheduleRefuses() async throws {
        var calls: [(channel: String, text: String?)] = []
        let source = "name: Nightly\nenabled: no\n---\nRead the night."
        let model = ROUTINESPageModel(); model.fixture = true
        model.call = { channel, args in
            calls.append((channel, args.count > 1 ? args[1] as? String : nil))
            switch channel {
            case "routines:text": return CodingAIJSON(["ok": true, "text": source])
            case "routines:save-text": return CodingAIJSON(["ok": true, "id": "nightly"])
            default: throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "The schedule refused."])
            }
        }
        let row = try #require(ROUTINESRoutine.list(CodingAIJSON([["id": "nightly", "name": "Nightly", "prompt": "Read the night.",
            "file": "/fixture/nightly.md", "folder": "/fixture", "agentId": "@hoot", "enabled": false, "state": "paused"]])).first)
        model.setOn(row, true)
        for _ in 0..<100 where model.busyID != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(calls.map(\.channel) == ["routines:text", "routines:save-text", "routines:resume", "routines:save-text"])
        #expect(calls[1].text?.contains("enabled: yes") == true)
        #expect(calls.last?.text == source)
        #expect(model.actionProblem != nil)
    }

    @Test func resetAllSaysWhichHalfWentThrough() {
        let refused = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "The preferences were refused."])
        let half = NativeAdvancedModel.resetProblem(refused, settingsReset: true)
        #expect(half.contains("back to their defaults"))
        #expect(!half.contains("nothing may have changed"))
        let none = NativeAdvancedModel.resetProblem(NSError(domain: "fixture", code: 2), settingsReset: false)
        #expect(!none.contains("back to their defaults"))
    }

    @Test func refusedSettingGoesBackToItsSavedValue() {
        let before = SettingsSchema.merge(["fixture.switch": CodingAIJSON(false)])
        var optimistic = before
        optimistic["fixture.switch"] = CodingAIJSON(true); optimistic["fixture.other"] = CodingAIJSON("kept")
        let shown = NativeSettingsValues.reverting(SettingsSchema.merge(optimistic), keys: ["fixture.switch"], to: before)
        #expect(shown["fixture.switch"] == CodingAIJSON(false))
        #expect(shown["fixture.other"] == CodingAIJSON("kept"))
    }
}
