import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

private actor RoutingSendDoors {
    var tasks: [NativeRPCValue]
    var created: [String] = [], assigned: [String] = [], comments: [String] = [], typed: [String] = []
    init(tasks: [NativeRPCValue]) { self.tasks = tasks }
    func create(_ details: String) -> String { created.append(details); return "local:new" }
    func assign(_ task: String) { assigned.append(task) }
    func comment(_ text: String) { comments.append(text) }
    func type(_ line: String) { typed.append(line) }
    nonisolated func doors() -> NativeHOOTSIMRoutingSend.Doors {
        .init(tasks: { await self.tasks }, create: { _, details, _, _, _ in await self.create(details) },
              assign: { task, _ in await self.assign(task) }, comment: { _, text in await self.comment(text) },
              type: { _, line in await self.type(line); return .number(1) })
    }
}

/// U41 (#97): the card's send and the automatic send follow one rule, so neither makes a second copy of a task.
final class HOOTSIMRoutingSendTests: XCTestCase {
    private func proposal(kind: String = "agent") -> NativeRPCValue {
        .object([.init("id", .string("card-one")), .init("reason", .string("Owns the portal.")),
            .init("request", .object([.init("problem", .string("The portal login loops"))])),
            .init("source", .object([.init("kind", .string("browser"))])),
            .init("target", .object([.init("id", .string(kind == "session" ? "session-one" : "portal-mechanic")), .init("kind", .string(kind)),
                .init("name", .string("Portal mechanic")), .init("projectId", .string("crm")), .init("folder", .string("/scratch/crm"))]))])
    }
    /// A task stored with a projectId and an empty folder, holding the problem in "instructions".
    private let stored = NativeRPCValue.object([.init("id", .string("local:old")), .init("title", .string("The portal login loops")),
        .init("projectId", .string("crm")), .init("project", .string("")), .init("crmStatus", .string("In Progress")),
        .init("instructions", .string("The portal login loops\n\nSource: browser")), .init("assignee", .string("portal-mechanic"))])

    func testBothApprovalsReuseTheSameOpenTask() async throws {
        for approval in [NativeHOOTSIMRoutingSend.Approval.card, .standing] {
            let doors = RoutingSendDoors(tasks: [stored])
            let result = try await NativeHOOTSIMRoutingSend.send(proposal(), approval: approval, doors: doors.doors())
            XCTAssertEqual(result["taskId"].string, "local:old", "\(approval)")
            let created = await doors.created, assigned = await doors.assigned, comments = await doors.comments
            XCTAssertEqual(created, []); XCTAssertEqual(assigned, []); XCTAssertEqual(comments.count, 1)
            XCTAssertEqual(result["automatic"].bool, approval == .standing ? true : nil)
        }
    }

    func testAFinishedTaskIsNotReusedAndASessionGetsOneLine() async throws {
        let done = stored.setting("crmStatus", .string("Done"))
        let doors = RoutingSendDoors(tasks: [done])
        let result = try await NativeHOOTSIMRoutingSend.send(proposal(kind: "session"), approval: .standing, doors: doors.doors())
        XCTAssertEqual(result["taskId"].string, "local:new")
        let created = await doors.created, typed = await doors.typed
        XCTAssertEqual(created.count, 1); XCTAssertTrue(created[0].contains("Hoot routing card card-one"))
        XCTAssertEqual(typed, ["Task local:new: The portal login loops"])
        XCTAssertEqual(result["sessionId"].string, "session-one")
    }
}
