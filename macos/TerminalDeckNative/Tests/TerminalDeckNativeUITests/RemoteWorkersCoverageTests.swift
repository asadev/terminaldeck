import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor
final class RemoteWorkersCoverageTests: XCTestCase {
    func testFailedCredentialSaveClearsTheSecretAndReloadsTheScreen() async {
        var requests: [NativeRPCValue] = []
        let model = NativeRemoteWorkersModel { request in
            requests.append(request)
            if request["op"].string == "credential_set" {
                throw NativeRPCError(code: "unavailable", message: "Worker unavailable")
            }
            return .object([.init("connections", .array([]))])
        }
        model.tokens["worker"] = "test-secret"
        await model.saveToken("worker")
        XCTAssertEqual(requests.map { $0["op"].string }, ["credential_set", "list"])
        XCTAssertEqual(requests.first?["connection"].string, "worker")
        XCTAssertEqual(requests.first?["token"].string, "test-secret")
        XCTAssertEqual(model.tokens["worker"], "")
        XCTAssertNotNil(model.problem)
        XCTAssertFalse(model.pending)
        XCTAssertTrue(model.connections.isEmpty)
    }

    func testStartingKeepsFailedPromptAndClearsSuccessfulPrompt() async {
        var fail = true
        let model = NativeRemoteWorkersModel { request in
            if request["op"].string == "start", fail {
                throw NativeRPCError(code: "unavailable", message: "Worker unavailable")
            }
            return .object([])
        }
        model.prompts["worker"] = "Check this project"
        await model.start("worker")
        XCTAssertEqual(model.prompts["worker"], "Check this project")
        fail = false
        await model.start("worker")
        XCTAssertEqual(model.prompts["worker"], "")
        XCTAssertNil(model.problem)
        XCTAssertFalse(model.pending)
    }

    func testRunRowsStayWithTheirConnectionAndNeverInventAConfirmedStop() {
        let model = NativeRemoteWorkersModel(invoke: { _ in .null })
        let run = NativeRPCValue.object([.init("connection", .string("one")), .init("state", .string("stop_requested"))])
        model.state = .object([.init("runs", .array([run]))])
        XCTAssertEqual(model.runs(for: "one"), [run])
        XCTAssertTrue(model.runs(for: "two").isEmpty)
        XCTAssertEqual(NativeRemoteWorkersModel.stateText(run), "Stop requested, not confirmed")
        XCTAssertEqual(NativeRemoteWorkersModel.stateText(run.setting("stopConfirmed", .bool(true))), "Stopping")
        XCTAssertEqual(NativeRemoteWorkersModel.tokenText(run), "Tokens: Not reported")
    }
}
