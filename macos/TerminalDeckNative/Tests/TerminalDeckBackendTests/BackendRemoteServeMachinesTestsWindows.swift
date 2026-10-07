import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendRemoteServeMachinesTestsWindowCalls {
    struct Row: Sendable { let tool: String; let args: NativeRPCValue; let caller: BackendMachineWindowCaller }
    var rows: [Row] = []
    func record(_ tool: String, _ args: NativeRPCValue, _ caller: BackendMachineWindowCaller) { rows.append(.init(tool: tool, args: args, caller: caller)) }
    func values() -> [Row] { rows }
}

@MainActor
final class BackendRemoteServeMachinesTestsWindows: XCTestCase {
    private typealias F = BackendRemoteServeMachinesTestsFixture
    private let tools: Set<String> = ["browser.open", "browser.read", "browser.step", "browser.screenshot", "browser.handover", "browser.close"]
    func testNonBrowserToolRefusedWithoutConfirmingItExists() async throws {
        let calls = BackendRemoteServeMachinesTestsWindowCalls()
        let service = BackendMachineWindowServices(allowedTools: tools, call: { tool, args, caller in await calls.record(tool, args, caller); return .null }, attended: { true })
        let answer = await service.serve(machineID: "machine-1", sessionID: "sess-1", tool: "sessions.start", arguments: "{}")
        XCTAssertFalse(answer.ok); XCTAssertEqual(try F.responseMessage(answer.body), "there is no such tool here.")
        let recorded = await calls.values(); XCTAssertTrue(recorded.isEmpty)
    }
    func testScreenshotPathRefusedOnDifferentComputer() async throws {
        let calls = BackendRemoteServeMachinesTestsWindowCalls()
        let service = BackendMachineWindowServices(allowedTools: tools, call: { tool, args, caller in await calls.record(tool, args, caller); return .null }, attended: { true })
        let answer = await service.serve(machineID: "machine-1", sessionID: "sess-1", tool: "browser.screenshot", arguments: "{}")
        XCTAssertFalse(answer.ok); XCTAssertTrue(try F.responseMessage(answer.body).contains("browser.read"))
        let recorded = await calls.values(); XCTAssertTrue(recorded.isEmpty)
    }
    func testUnreadableArgumentsNeverDispatchEmptyObject() async throws {
        let calls = BackendRemoteServeMachinesTestsWindowCalls()
        let service = BackendMachineWindowServices(allowedTools: tools, call: { tool, args, caller in await calls.record(tool, args, caller); return .null }, attended: { true })
        let answer = await service.serve(machineID: "machine-1", sessionID: "sess-1", tool: "browser.read", arguments: "not json")
        XCTAssertFalse(answer.ok); let recorded = await calls.values(); XCTAssertTrue(recorded.isEmpty)
    }
    func testDispatcherGetsMachineAndRemoteSessionIdentityTogether() async throws {
        let calls = BackendRemoteServeMachinesTestsWindowCalls()
        let service = BackendMachineWindowServices(allowedTools: tools, call: { tool, args, caller in
            await calls.record(tool, args, caller); return .object([.init("title", .string("Example"))])
        }, attended: { true })
        let answer = await service.serve(machineID: "machine-1", sessionID: "sess-1", tool: "browser.read", arguments: "{\"selector\":\"h1\"}")
        XCTAssertTrue(answer.ok); XCTAssertEqual(answer.body, "{\"title\":\"Example\"}")
        let rows = await calls.values(); XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.tool, "browser.read")
        XCTAssertEqual(rows.first?.args["selector"].string, "h1"); XCTAssertEqual(rows.first?.caller.machineID, "machine-1")
        XCTAssertEqual(rows.first?.caller.sessionID, "sess-1"); XCTAssertEqual(rows.first?.caller.attended, true)
    }
    func testDispatcherRefusalWordingPassedVerbatim() async throws {
        let service = BackendMachineWindowServices(allowedTools: tools, call: { _, _, _ in throw NativeRPCError(code: "refused", message: "B2 has no page in it yet") }, attended: { true })
        let answer = await service.serve(machineID: "machine-1", sessionID: "sess-1", tool: "browser.read", arguments: "{}")
        XCTAssertFalse(answer.ok); XCTAssertEqual(try F.responseMessage(answer.body), "B2 has no page in it yet")
    }
    func testAttendedComesFromLocalComputer() async throws {
        let calls = BackendRemoteServeMachinesTestsWindowCalls()
        let service = BackendMachineWindowServices(allowedTools: tools, call: { tool, args, caller in await calls.record(tool, args, caller); return .null }, attended: { false })
        let answer = await service.serve(machineID: "machine-1", sessionID: "sess-1", tool: "browser.read", arguments: "{}")
        XCTAssertTrue(answer.ok); let rows = await calls.values(); XCTAssertEqual(rows.first?.caller.attended, false)
    }
    func testLargePageAnswerFitsBothCapsAndNamesTextCharsRemedy() throws {
        let value = NativeRPCValue.object([.init("url", .string("https://example.com")), .init("title", .string("A real page")),
            .init("text", .string(String(repeating: "x", count: 40000))), .init("elements", .array((0..<600).map { i in
                .object([.init("selector", .string("#e\(i)")), .init("role", .string("button")), .init("text", .string("element number \(i)"))])
            }))])
        let answer = BackendMachineWindowServices.fit(value)
        XCTAssertTrue(answer.ok); XCTAssertLessThanOrEqual(answer.body.utf8.count, 49152)
        XCTAssertLessThan(try NativeRPCValue.string(answer.body).encodedJSON().count, 65536)
        let parsed = try NativeRPCValue.parseJSON(Data(answer.body.utf8))
        XCTAssertEqual(parsed["url"].string, "https://example.com"); XCTAssertEqual(parsed["title"].string, "A real page")
        XCTAssertGreaterThan(parsed["truncatedOnTheWay"]["charactersDropped"].number ?? 0, 0)
        XCTAssertTrue(parsed["truncatedOnTheWay"]["message"].string?.contains("textChars") == true)
    }
    func testSmallAnswerUnchangedWithoutTruncationNote() throws {
        let value = NativeRPCValue.object([.init("url", .string("https://example.com")), .init("text", .string("short"))])
        let answer = BackendMachineWindowServices.fit(value)
        XCTAssertTrue(answer.ok); XCTAssertEqual(try NativeRPCValue.parseJSON(Data(answer.body.utf8)), value)
    }
    func testUnshortenableBareAnswerRefusedWithSelectorRemedy() throws {
        let answer = BackendMachineWindowServices.fit(.string(String(repeating: "y", count: 49162)))
        XCTAssertFalse(answer.ok); XCTAssertTrue(try F.responseMessage(answer.body).contains("selector"))
    }
}
