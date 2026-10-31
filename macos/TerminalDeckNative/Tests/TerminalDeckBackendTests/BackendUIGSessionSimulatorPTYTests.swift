import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private final class BackendUIGSessionSimulatorPTYOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var readySent = false
    private var acceptedSent = false
    private let ready: XCTestExpectation
    private let accepted: XCTestExpectation
    private let tokens: [String]
    init(ready: XCTestExpectation, accepted: XCTestExpectation, tokens: [String]) {
        self.ready = ready; self.accepted = accepted; self.tokens = tokens
    }
    func note(_ event: BackendSessionEvent) {
        guard case .data(_, let chunk) = event else { return }
        let signals = lock.withLock { () -> (Bool, Bool) in
            text += chunk
            let becameReady = !readySent && text.contains("UIG_PTY_READY")
            let becameAccepted = !acceptedSent && tokens.allSatisfy { text.contains("accepted:" + $0) }
            readySent = readySent || becameReady; acceptedSent = acceptedSent || becameAccepted
            return (becameReady, becameAccepted)
        }
        if signals.0 { ready.fulfill() }; if signals.1 { accepted.fulfill() }
    }
    func captured() -> String { lock.withLock { text } }
}

final class BackendUIGSessionSimulatorPTYTests: XCTestCase, @unchecked Sendable {
    private var reader: BackendSpawnSpec {
        .init(provider: "shell", command: "/bin/sh", args: ["-c", #"stty -echo; printf 'UIG_PTY_READY\n'; while IFS= read -r line; do printf 'accepted:%s\n' "$line"; done"#], path: "/usr/bin:/bin")
    }
    private func cleanup(_ manager: BackendPTYManager) {
        addTeardownBlock {
            manager.beginShutdown()
            let drained = await manager.drain(timeoutMilliseconds: 2_000)
            XCTAssertTrue(drained, "Owned fixture PTY did not drain")
        }
    }
    func testAtomicIncarnationCheckForwardsBothOverloadsAndKeepsDefaultCallers() async throws {
        let ready = expectation(description: "fixture ready"), accepted = expectation(description: "guarded and legacy writes accepted")
        let output = BackendUIGSessionSimulatorPTYOutput(ready: ready, accepted: accepted, tokens: ["guarded-string", "guarded-bytes", "legacy-string", "legacy-bytes"])
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { output.note($0) }); cleanup(manager)
        let meta = try manager.create(.init(cwd: "/tmp", provider: "shell"), spawn: reader)
        await fulfillment(of: [ready], timeout: 5)
        for mismatch in [meta.createdAt + 1, .nan, .infinity] {
            XCTAssertThrowsError(try manager.write(meta.id, data: "rejected-string\n", expectedCreatedAt: mismatch)) { error in
                XCTAssertEqual((error as? NativeRPCError)?.code, "stale-session")
            }
            XCTAssertThrowsError(try manager.write(meta.id, bytes: Data("rejected-bytes\n".utf8), expectedCreatedAt: mismatch)) { error in
                XCTAssertEqual((error as? NativeRPCError)?.code, "stale-session")
            }
        }
        try manager.write(meta.id, data: "guarded-string\n", expectedCreatedAt: meta.createdAt)
        try manager.write(meta.id, bytes: Data("guarded-bytes\n".utf8), expectedCreatedAt: meta.createdAt)
        try manager.write(meta.id, data: "legacy-string\n")
        try manager.write(meta.id, bytes: Data("legacy-bytes\n".utf8))
        await fulfillment(of: [accepted], timeout: 5)
        XCTAssertFalse(output.captured().contains("accepted:rejected"))
    }
    func testReplacementRejectsOriginalTicketAndDoesNotReachNewPTY() async throws {
        let ready = expectation(description: "replacement ready"), accepted = expectation(description: "replacement accepts its own incarnation")
        let output = BackendUIGSessionSimulatorPTYOutput(ready: ready, accepted: accepted, tokens: ["replacement-current"])
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { output.note($0) }); cleanup(manager)
        let original = try manager.create(.init(cwd: "/tmp", provider: "shell"), spawn: .init(provider: "shell", command: "/bin/cat", args: [], path: "/usr/bin:/bin"))
        manager.kill(original.id)
        var input = BackendCreateSessionInput(cwd: "/tmp", provider: "shell"); input.replaces = original.id
        let replacement = try manager.create(input, spawn: reader)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertNotEqual(original.id, replacement.id)
        XCTAssertThrowsError(try manager.write(original.id, data: "original-delayed\n", expectedCreatedAt: original.createdAt)) { error in
            guard case BackendSessionFailure.missingSession = error else { return XCTFail("Expected missing original session, got \(error)") }
        }
        XCTAssertThrowsError(try manager.write(replacement.id, bytes: Data("wrong-incarnation\n".utf8), expectedCreatedAt: original.createdAt)) { error in
            XCTAssertEqual((error as? NativeRPCError)?.code, "stale-session")
        }
        try manager.write(replacement.id, data: "replacement-current\n", expectedCreatedAt: replacement.createdAt)
        await fulfillment(of: [accepted], timeout: 5)
        XCTAssertFalse(output.captured().contains("accepted:original-delayed"))
        XCTAssertFalse(output.captured().contains("accepted:wrong-incarnation"))
    }
    func testExitedSessionRefusesGuardedStringAndBytesWrites() async throws {
        let exited = expectation(description: "owned fixture exits")
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { event in
            if case .exit = event { exited.fulfill() }
        }); cleanup(manager)
        let meta = try manager.create(.init(cwd: "/tmp", provider: "shell"), spawn: .init(provider: "shell", command: "/bin/sh", args: ["-c", "exit 0"], path: "/usr/bin:/bin"))
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertThrowsError(try manager.write(meta.id, data: "late", expectedCreatedAt: meta.createdAt)) { error in
            guard case BackendSessionFailure.exitedSession = error else { return XCTFail("Expected exited session, got \(error)") }
        }
        XCTAssertThrowsError(try manager.write(meta.id, bytes: Data("late".utf8), expectedCreatedAt: meta.createdAt)) { error in
            guard case BackendSessionFailure.exitedSession = error else { return XCTFail("Expected exited session, got \(error)") }
        }
    }
}
