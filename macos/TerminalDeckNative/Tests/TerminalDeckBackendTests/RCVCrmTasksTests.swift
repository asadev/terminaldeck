import XCTest
import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// CRM-FIELDS on the Receiver: an event's named values reach the task it becomes; a CRM task link
/// arrival shows in the Tasks source without being routed again; Check connection reads only.
final class RCVCrmTasksTests: XCTestCase {
    func testAnEventsOwnFieldsReachTheTaskItBecomes() async throws {
        let (service, dispatch, _) = try await RCVTestKit.service()
        let (view, reveal) = try await service.createSource(preset: "crm", name: "Other CRM")
        _ = try await service.saveRule(RCVRule(name: "Tasks", sourceIds: [view.id], target: .init(kind: .newTask, id: "builder")), byOwner: true)
        _ = try await RCVTestKit.deliver(service, source: view.id, opened: .init(headers: [:], pathToken: reveal!.secret, body: Data(RCVPresets.crmTasksSample.utf8)))
        let created = await dispatch.createdFields
        let fields = try XCTUnwrap(created.first)
        XCTAssertEqual(fields.dueDate, "2026-10-14"); XCTAssertEqual(fields.priority, "High")
        XCTAssertTrue(fields.custom.contains { $0.label == "Budget" && $0.value == "AED 2,500,000" })
        // Check connection: the last event became a task; with the task holding nothing yet, the fields show as not landed.
        let arrived = try await service.events(sourceID: view.id)
        let taskID = try XCTUnwrap(arrived.first?.taskId)
        await dispatch.setSnapshot(taskID, RCVTaskSnapshot(id: taskID, title: "Call", status: "To-Do", values: [:], custom: [:]))
        let check = try await service.check(sourceID: view.id)
        XCTAssertEqual(check.verdict, .partly); XCTAssertEqual(check.taskId, taskID)
        XCTAssertTrue(check.landings.contains { $0.name == "dueDate" && !$0.landed })
    }

    func testATaskLinkArrivalShowsInTheTasksSourceAndIsNeverRoutedAgain() async throws {
        let (service, dispatch, _) = try await RCVTestKit.service()
        _ = try await service.saveRule(RCVRule(name: "Every task", sourceIds: ["terminaldeck.tasks"], target: .init(kind: .hoot)), byOwner: true)
        let before = try await service.check(sourceID: "terminaldeck.tasks")
        XCTAssertEqual(before.verdict, .nothingYet)
        XCTAssertTrue(before.lines.contains { $0.contains("the CRM side has not sent anything") })
        let payload = try NativeRPCValue.parseJSON(Data(RCVPresets.crmTasksSample.utf8))
        await service.recordTaskArrival(.init(kind: "task.created", from: "iLoop CRM", title: "Call the Al Barari owner back", payload: payload,
                                              upstreamId: "iloop:create:7f3a:1", taskId: "k1:7f3a1c2e", outcome: "Answered “accepted”.", projectId: "crm"))
        let events = try await service.events(sourceID: "terminaldeck.tasks")
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events.first?.status, .delivered); XCTAssertEqual(events.first?.taskId, "k1:7f3a1c2e")
        XCTAssertEqual(events.first?.fields["dueDate"], "2026-10-14")
        let created = await dispatch.created
        XCTAssertTrue(created.isEmpty, "an arrival is a task already; no rule makes a second one")
        let preview = try await service.preview(sourceID: "terminaldeck.tasks")
        XCTAssertTrue(preview.unmapped.isEmpty); XCTAssertTrue(preview.basis.hasPrefix("Latest event"))
    }
}
