import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDockerMCPReceiverTests: XCTestCase {
    private func record(_ action: String, type: String = "container") -> NativeRPCValue {
        .object([.init("type", .string(type)), .init("action", .string(action)),
            .init("id", .string("owned-container")), .init("target", .string("saved-server")),
            .init("timeNano", .number(1234)), .init("attributes", .object([
                .init("name", .string("test-app")), .init("io.terminaldeck.app", .string("test-app")),
                .init("password", .string("must-not-forward"))]))])
    }
    func testOnlyCrashAndUnhealthyContainerEventsBecomeReceiverSignals() {
        for action in ["die", "oom", "health_status: unhealthy"] {
            XCTAssertNotNil(BackendDockerMCPReceiver.dockerEvent(record(action)))
        }
        for action in ["start", "stop", "health_status: healthy", "exec_create"] {
            XCTAssertNil(BackendDockerMCPReceiver.dockerEvent(record(action)))
        }
        XCTAssertNil(BackendDockerMCPReceiver.dockerEvent(record("die", type: "image")))
    }
    func testReceiverSignalUsesPublicFieldsAndRepeatableEventIdentity() throws {
        let event = try XCTUnwrap(BackendDockerMCPReceiver.dockerEvent(record("die")))
        XCTAssertEqual(event.kind, "docker.container.died")
        XCTAssertEqual(event.fields, ["server": "saved-server", "container": "test-app", "app": "test-app"])
        XCTAssertEqual(event.id, BackendDockerMCPReceiver.dockerEvent(record("die"))?.id)
        XCTAssertFalse(event.text.contains("must-not-forward"))
        XCTAssertFalse(event.fields.values.contains("must-not-forward"))
    }
}
