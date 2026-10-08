import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

actor TAGTaskEventsProbe {
    private(set) var values: [NativeRPCValue] = []
    func add(_ value: NativeRPCValue) { values.append(value) }
}

final class TAGTaskEventsTests: XCTestCase {
    private typealias F = BackendRoutinesTaskEngineParityFixture
    func testCRMStartedProgressQuestionBlockedFinishedAndNeedsReplyReachOrigin() async throws { try await F.withFixture { rig in
        let probe = TAGTaskEventsProbe()
        await rig.engine.setNotificationObserver { task, event in await probe.add(event.setting("key", .string(BackendTAGTaskNotifications.keyID(task)!))) }
        let id = try await rig.give("u-builder")
        try await rig.engine.noteNeedsInput(sessionID: "s-1", screen: "Which file?")
        try await rig.engine.comment(id, kind: "blocker", text: "Waiting for the file.")
        try await rig.finish("s-1", answer: "Finished.")
        let events = await probe.values
        XCTAssertEqual(Set(events.compactMap { $0["type"].string }), Set(BackendTAGTaskNotifications.eventNames.keys))
        XCTAssertTrue(events.allSatisfy { $0["key"].string == F.key && $0["taskId"].string == id })
        try await rig.engine.noteFinishedTurn(sessionID: "s-1", turnID: "turn-1", answer: "Finished.")
        let again = await probe.values
        XCTAssertEqual(again.filter { $0["type"].string == "task.finished" }.count, 1)
    } }
    func testLocalKeyOriginGetsEventsAndOwnerOnlyTaskNeverLeaks() async throws { try await F.withFixture { rig in
        let probe = TAGTaskEventsProbe()
        await rig.engine.setNotificationObserver { task, event in await probe.add(event.setting("key", .string(BackendTAGTaskNotifications.keyID(task)!))) }
        let appTask = try await rig.local.create(F.obj([("title", .string("Key work")), ("project", .string("/work/key")), ("assignee", .string("builder"))]), notificationKeyID: "A")
        try await rig.engine.noteNeedsInput(sessionID: "s-1", screen: "Question")
        _ = try await rig.local.create(F.obj([("title", .string("Owner work")), ("project", .string("/work/owner")), ("assignee", .string("fixer"))]))
        let events = await probe.values
        XCTAssertTrue(events.contains { $0["type"].string == "task.needs-reply" })
        XCTAssertTrue(events.allSatisfy { $0["taskId"].string == appTask.id && $0["key"].string == "A" })
        _ = try await rig.local.update(appTask.id, input: F.obj([("assignee", .string("tester"))]), notificationKeyID: "B")
        let reassignEvents = Array((await probe.values).dropFirst(events.count))
        XCTAssertTrue(reassignEvents.contains { $0["type"].string == "task.started" })
        XCTAssertTrue(reassignEvents.allSatisfy { $0["key"].string == "B" && $0["taskId"].string == appTask.id })
        let reassigned = try await rig.record(appTask.id); XCTAssertEqual(reassigned.value["notificationKeyId"].string, "B")
        try await rig.engine.closeSession(appTask.id)
        let closed = try await rig.record(appTask.id); XCTAssertEqual(closed.value["notificationKeyId"].string, "B")
    } }
    func testNotificationFailureDoesNotStopTaskLaunch() async throws { try await F.withFixture { rig in
        await rig.engine.setNotificationObserver { _, _ in throw NativeRPCError(code: "notify", message: "Queue is unavailable") }
        let id = try await rig.give("u-builder"), record = try await rig.record(id), problems = await rig.probe.problems
        XCTAssertEqual(record.process, "running"); XCTAssertTrue(problems.contains { $0.contains("Queue is unavailable") })
    } }
    func testSuggestedToolsMatchLocalOrCRMTaskAccess() async throws { try await F.withFixture { rig in
        let local = try await rig.local.create(F.obj([("title", .string("Local"))])), crmID = try await rig.give("u-builder"), crm = try await rig.record(crmID)
        XCTAssertEqual(BackendTAGTaskNotifications.event(local, type: "task.finished", body: "Done")["suggestedTool"].string, "tasks_local")
        XCTAssertEqual(BackendTAGTaskNotifications.event(local, type: "task.needs-reply", body: "Question")["suggestedTool"].string, "tasks_local_change")
        XCTAssertEqual(BackendTAGTaskNotifications.event(crm, type: "task.finished", body: "Done")["suggestedTool"].string, "crm_task")
        XCTAssertEqual(BackendTAGTaskNotifications.event(crm, type: "task.question", body: "Question")["suggestedTool"].string, "crm_task")
    } }
}

@MainActor
final class TAGTaskNotificationHubTests: XCTestCase {
    private func event(_ type: String, id: String, clock: BackendDeckCoreEventsTestClock) -> NativeRPCValue {
        BackendTaskValues.object([("id", .string(id)), ("type", .string(type)), ("taskId", .string("local:work")), ("sessionId", .string("s1")), ("sessionName", .string("Work")), ("at", .number(clock.now())), ("body", .string("Task progress")), ("note", .string("Task progress")), ("suggestedTool", .string("tasks_get"))])
    }
    func testAllSixEventsAreKeyIsolatedAndWaitDeliversThem() async {
        let clock = BackendDeckCoreEventsTestClock(), queue = BackendDeckCoreEventsHub(settings: { _ in BackendTaskValues.object([("mode", .string("wait"))]) }, clock: clock)
        for (i, type) in BackendTAGTaskNotifications.eventNames.keys.sorted().enumerated() { _ = await queue.publishTask(keyId: "A", event: event(type, id: "a\(i)", clock: clock)) }
        _ = await queue.publishTask(keyId: "B", event: event("task.progress", id: "b", clock: clock))
        let list = await queue.list(keyId: "A"), got = await queue.wait(keyId: "A", timeoutMs: 1), other = await queue.list(keyId: "B")
        XCTAssertEqual(list.count, 6); XCTAssertEqual(got.count, 6); XCTAssertEqual(other.map { $0["id"].string }, ["b"])
        let ack = await queue.ack(keyId: "B", ids: ["a0"]); XCTAssertEqual(ack["acked"], .array([]))
        await queue.stop()
    }
    func testParkedWaitIsWokenByTaskEvent() async {
        let clock = BackendDeckCoreEventsTestClock(), queue = BackendDeckCoreEventsHub(settings: { _ in BackendTaskValues.object([("mode", .string("wait"))]) }, clock: clock)
        let waiting = Task { await queue.wait(keyId: "A", timeoutMs: 45_000) }
        await clock.scheduled.wait(1)
        _ = await queue.publishTask(keyId: "A", event: event("task.started", id: "wake", clock: clock))
        let received = await waiting.value; XCTAssertEqual(received.first?["id"].string, "wake")
        await queue.stop()
    }
    func testTaskWebhookUsesOnlyOriginKeySignedDelivery() async {
        let clock = BackendDeckCoreEventsTestClock(), receiver = BackendDeckCoreEventsTestReceiver()
        let queue = BackendDeckCoreEventsHub(settings: { key in BackendTaskValues.object([("mode", .string("webhook")), ("url", .string("https://callbacks.example.com/" + key)), ("secret", .string(BackendDeckCoreEventsTestFixture.secret))]) }, clock: clock, post: { try await receiver.post($0, $1, $2).status })
        _ = await queue.publishTask(keyId: "A", event: event("task.finished", id: "finish", clock: clock)); await queue.awaitIdle()
        let posts = await receiver.deliveries(), list = await queue.list(keyId: "A"), other = await queue.list(keyId: "B")
        XCTAssertEqual(posts.map(\.url), ["https://callbacks.example.com/A"]); XCTAssertEqual(list.first?["via"].string, "webhook"); XCTAssertTrue(other.isEmpty)
        XCTAssertNil(BackendDeckCoreEventsWebhook.verify(secret: BackendDeckCoreEventsTestFixture.secret, headers: posts[0].headers, body: posts[0].body, nowSeconds: floor(clock.now() / 1_000)))
        await queue.stop()
    }
    func testTaskEventsSurviveRestartAndOffKeysKeepNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TAG-task-events-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: directory) }
        let clock = BackendDeckCoreEventsTestClock(), settings: BackendDeckCoreEventsHub.Settings = { key in key == "A" ? BackendTaskValues.object([("mode", .string("wait"))]) : nil }
        let before = BackendDeckCoreEventsHub(directory: directory, settings: settings, clock: clock)
        _ = await before.publishTask(keyId: "A", event: event("task.blocked", id: "durable", clock: clock))
        let rejected = await before.publishTask(keyId: "gone", event: event("task.started", id: "gone", clock: clock)); XCTAssertFalse(rejected)
        await before.flush(); await before.stop()
        let after = BackendDeckCoreEventsHub(directory: directory, settings: settings, clock: clock); await after.load()
        let restored = await after.list(keyId: "A"); XCTAssertEqual(restored.first?["id"].string, "durable"); await after.stop()
    }
    func testEveryTaskEventHasSubscriptionCatalogueAndRoutesOnlyOrigin() async throws {
        let receiver = BackendDeckCoreEventsTestReceiver(), clock = BackendDeckCoreEventsTestClock()
        let events = BackendDeckCoreEvents(mode: { _ in "wait" }, internet: { true }, clock: clock, post: { try await receiver.post($0, $1, $2) })
        let type = "task.question", name = BackendTAGTaskNotifications.eventNames[type]!
        _ = try await events.subscribe(keyId: "A", via: "internet", params: BackendDeckCoreEventsTestFixture.params().setting("name", .string(name)))
        _ = try await events.subscribe(keyId: "B", via: "internet", params: BackendDeckCoreEventsTestFixture.params(url: "https://callbacks.example.com/other").setting("name", .string(name)))
        let offered = await events.offer(keyId: "A", event: event(type, id: "question", clock: clock)); await events.awaitIdle()
        let posts = await receiver.deliveries(); XCTAssertEqual(offered, 1); XCTAssertEqual(posts.count, 1)
        XCTAssertTrue(BackendTAGTaskNotifications.eventNames.values.allSatisfy { name in BackendDeckCoreEvents.catalogue().contains { $0["name"].string == name } })
        await events.stop()
    }
}
