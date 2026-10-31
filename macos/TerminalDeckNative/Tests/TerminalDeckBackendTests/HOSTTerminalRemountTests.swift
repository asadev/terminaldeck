#if TD_HOST_INTEGRATED
import Foundation
import XCTest
@testable import TerminalDeckBackend

/// 27 Oct: the session host part of the garbled-terminal fix, for a session-preserving host swap.
/// An app restart against the same host gets the session redrawn whole (`Snapshot.remount`); an app from before
/// this build, asking without `remount`, gets exactly what it always got; and the new field is optional both ways.
final class HOSTTerminalRemountTests: XCTestCase, @unchecked Sendable {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-remount-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testAnAppRestartAgainstTheSameHostGetsTheSessionRedrawnWhole() async throws {
        let root = try scratch()
        let paths = try BackendHOSTPaths(dataDirectory: root); _ = try paths.secret(create: true)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let server = try BackendHOSTServer(paths: paths, hostVersion: "fixture-v1", manager: manager,
            launch: { try manager.hostCreate($0) }, snapshot: { manager.hostSnapshot($0) }, onIdle: {})
        defer { server.stopListening(); manager.beginShutdown() }
        let first = try BackendHOSTClient(paths: paths)

        // A session whose program draws Claude Code's full-screen view (the recorded stream) and stays running.
        let drawing = TerminalGarbleFixture.segments[0].bytes
        let stream = root.appendingPathComponent("claude.bin"); try drawing.write(to: stream)
        var input = BackendCreateSessionInput(cwd: root.path, provider: "shell"); input.cols = 120; input.rows = 40
        let spawn = BackendSpawnSpec(provider: "shell", command: "/bin/sh",
            args: ["-c", "cat \"$1\"; while IFS= read -r line; do :; done", "sh", stream.path], path: "/usr/bin:/bin")
        let one = try first.create(.init(id: UUID().uuidString.lowercased(), input: input, spawn: spawn,
                                         inheritedEnvironment: ["HOME": root.path, "LANG": "en_US.UTF-8"]))
        let pid = try XCTUnwrap(manager.pidOf(one.id))
        for _ in 0..<200 where manager.hostViewport(one.id)?.screen?.contains("auto mode on") != true {
            try await Task.sleep(for: .milliseconds(25))
        }

        // The app quits (the host keeps the session) and starts again.
        first.detach()
        let second = try BackendHOSTClient(paths: paths)
        defer { second.detach() }
        let fresh = try XCTUnwrap(try second.snapshot(one.id, remount: true))
        let remount = try XCTUnwrap(fresh.remount, "a host of this build answers the remount")
        let exact = BackendTerminalProbe(cols: 120, rows: 40); exact.feed(drawing)
        let joined = BackendTerminalProbe(cols: 120, rows: 40); joined.feed(remount)
        XCTAssertEqual(joined.rows, exact.rows, "redrawn whole after the restart")
        XCTAssertTrue(joined.fullScreen)
        XCTAssertEqual(fresh.pid, pid, "the same process the whole time")

        // An app from before this build asks without `remount` and gets the snapshot it always got.
        let older = try XCTUnwrap(try second.snapshot(one.id))
        XCTAssertNil(older.remount)
        XCTAssertTrue(older.replay.contains("auto mode on"), "the raw tail, as before")
        try second.stopAll(); let drained = await manager.drain(); XCTAssertTrue(drained)
    }

    /// The fields are optional both ways: a newer app's request reads in an older host (it ignores what it does not
    /// know), and an older host's snapshot reads in a newer app (no remount: the raw tail is used).
    func testTheRemountFieldsAreOptionalBothWays() throws {
        var request = BackendHOSTProtocol.Request(secret: "s", operation: .snapshot, id: "x"); request.remount = true
        let wire = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(wire["remount"] as? Bool, true)
        var olderWire = wire; olderWire["remount"] = nil
        let older = try JSONDecoder().decode(BackendHOSTProtocol.Request.self, from: JSONSerialization.data(withJSONObject: olderWire))
        XCTAssertNil(older.remount, "an older app's request: no remount asked")
        var withUnknown = wire; withUnknown["somethingNewer"] = true
        XCTAssertNoThrow(try JSONDecoder().decode(BackendHOSTProtocol.Request.self, from: JSONSerialization.data(withJSONObject: withUnknown)),
                         "a host ignores fields it does not know, which is what an older host does with `remount`")
    }
}
#endif
