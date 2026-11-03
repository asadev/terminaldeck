// INT2 enables this only after applying the PTY seam and helper dispatch.
// Ordinary shared-tree builds retain no dependency on unapplied methods.
#if TD_HOST_INTEGRATED
import Foundation
import Darwin
import XCTest
@testable import TerminalDeckBackend

final class HOSTIntegrationTests: XCTestCase, @unchecked Sendable {
    override func setUpWithError() throws {
    }

    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func launch(_ root: URL, tag: String = "before") throws -> BackendHOSTProtocol.Launch {
        let input = BackendCreateSessionInput(cwd: root.path, provider: "shell")
        let spawn = BackendSpawnSpec(provider: "shell", command: "/bin/sh",
            args: ["-c", "printf '%s\\n' '" + tag + "'; while IFS= read -r line; do printf '%s\\n' \"$line\"; done"],
            path: "/usr/bin:/bin", env: ["HOST_SCRATCH_MARKER": tag])
        return try .init(id: UUID().uuidString.lowercased(), input: input, spawn: spawn,
                         inheritedEnvironment: ["HOME": root.path, "LANG": "en_US.UTF-8"])
    }
    private func withOwner(_ root: URL) throws -> (BackendPTYManager, BackendHOSTServer, BackendHOSTClient) {
        let paths = try BackendHOSTPaths(dataDirectory: root); _ = try paths.secret(create: true)
        let manager = BackendPTYManager(inheritedEnvironment: ["HOST_MUST_NOT_INHERIT": "launchd"], onEvent: { _ in })
        let server = try BackendHOSTServer(paths: paths, hostVersion: "fixture-v1", manager: manager,
            launch: { try manager.hostCreate($0) }, snapshot: { manager.hostSnapshot($0) }, onIdle: {})
        return (manager, server, try BackendHOSTClient(paths: paths))
    }
    func testResolvedCwdAndEnvironmentRejectNULBeforeExec() throws {
        let root = try scratch(), manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        for field in 0..<3 {
            var value = try launch(root)
            if field == 0 { value.cwd += "\0suffix" }
            else if field == 1 { value.environment["bad\0name"] = "value" }
            else { value.environment["good_name"] = "bad\0value" }
            XCTAssertThrowsError(try manager.hostCreate(value))
            XCTAssertTrue(manager.list().isEmpty)
        }
    }
    func testDetachReattachKeepsBothOriginalProcessesAndScrollback() async throws {
        let root = try scratch(), (manager, server, first) = try withOwner(root)
        defer { first.detach(); server.stopListening(); manager.beginShutdown() }
        let one = try first.create(launch(root, tag: "before-one")), two = try first.create(launch(root, tag: "before-two"))
        let pidOne = try XCTUnwrap(manager.pidOf(one.id)), pidTwo = try XCTUnwrap(manager.pidOf(two.id))
        let before = expectation(description: "both shells emit before detach"), outputs = HOSTObservedOutput(expected: ["before-one", "before-two"], ready: before)
        try first.attach(onSnapshot: { outputs.receive($0.replay) }, onEvent: { outputs.receive($0.text ?? "") }, onReady: {}, onDisconnect: {})
        await fulfillment(of: [before], timeout: 5)
        first.detach()
        try first.write(one.id, bytes: Data("during-detach-one\n".utf8))
        try first.write(two.id, bytes: Data("during-detach-two\n".utf8))
        let second = try BackendHOSTClient(paths: BackendHOSTPaths(dataDirectory: root))
        defer { second.detach() }
        let attached = expectation(description: "new app reattaches"), after = expectation(description: "output continues from both pids")
        let resumed = HOSTObservedOutput(expected: ["during-detach-one", "during-detach-two", "after-attach-one", "after-attach-two"], ready: after)
        try second.attach(onSnapshot: { resumed.receive($0.replay) }, onEvent: { resumed.receive($0.text ?? "") }, onReady: { attached.fulfill() }, onDisconnect: {})
        await fulfillment(of: [attached], timeout: 5)
        XCTAssertEqual(second.cachedPID(one.id), pidOne); XCTAssertEqual(second.cachedPID(two.id), pidTwo)
        try second.write(one.id, bytes: Data("after-attach-one\n".utf8)); try second.write(two.id, bytes: Data("after-attach-two\n".utf8))
        await fulfillment(of: [after], timeout: 5)
        try second.stopAll(); let drained = await manager.drain(); XCTAssertTrue(drained)
        XCTAssertNil(manager.pidOf(one.id)); XCTAssertNil(manager.pidOf(two.id))
    }
    func testDoubleCreateUsesSamePidAndChangedPayloadIsRefused() async throws {
        let root = try scratch(), (manager, server, client) = try withOwner(root)
        defer { client.detach(); server.stopListening(); manager.beginShutdown() }
        let value = try launch(root), first = try client.create(value), pid = manager.pidOf(first.id)
        XCTAssertEqual(try client.create(value).id, first.id); XCTAssertEqual(manager.pidOf(first.id), pid)
        var changed = value; changed.arguments.append("different")
        XCTAssertThrowsError(try client.create(changed)); XCTAssertEqual(manager.list().count, 1)
        try client.remove(first.id); XCTAssertThrowsError(try client.create(value))
        let drained = await manager.drain(); XCTAssertTrue(drained)
    }
    func testMetadataChangesReachAlreadyAttachedClient() async throws {
        let root = try scratch(), (manager, server, client) = try withOwner(root)
        defer { client.detach(); server.stopListening(); manager.beginShutdown() }
        let meta = try client.create(launch(root)), attached = expectation(description: "attached"), changed = expectation(description: "metadata propagated")
        changed.assertForOverFulfill = false // later snapshots repeat the final metadata; any one of them proves it (QUIT 9 Oct)
        try client.attach(onSnapshot: { value in
            if value.session.title == "kept-title", value.session.profileId == "account-two", value.session.agentSessionId == "conversation-two" { changed.fulfill() }
        }, onEvent: { _ in }, onReady: { attached.fulfill() }, onDisconnect: {})
        await fulfillment(of: [attached], timeout: 5)
        XCTAssertTrue(try client.rename(meta.id, title: "kept-title"))
        _ = try client.setAccount(meta.id, account: .init(id: "account-two", name: "Second"), home: nil)
        try client.setConversation(meta.id, conversation: "conversation-two")
        await fulfillment(of: [changed], timeout: 5)
        XCTAssertEqual(client.cachedSessions().first?.profileId, "account-two")
        try client.stopAll()
    }
    func testStopAllKillsIgnoringChildGroupAndConfirmsDrain() async throws {
        let root = try scratch(), (manager, server, client) = try withOwner(root)
        defer { client.detach(); server.stopListening(); manager.beginShutdown() }
        var value = try launch(root)
        value.arguments = ["-c", "trap '' HUP TERM; /bin/sh -c 'trap \"\" HUP TERM; while :; do /bin/sleep 1; done' & wait"]
        let session = try client.create(value), pid = try XCTUnwrap(manager.pidOf(session.id))
        try client.stopAll()
        let drained = await manager.drain(); XCTAssertTrue(drained); XCTAssertTrue(manager.list().isEmpty)
        XCTAssertEqual(Darwin.kill(-pid, 0), -1); XCTAssertEqual(errno, ESRCH)
    }
    func testLaunchdHostOutlivesKilledFakeAppThenReattachesSamePids() async throws {
        // Its scratch helper/app products are built only by the O2 HOST gate (TD_WIP=HOST), like the managed proof.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TD_WIP"]?.contains("HOST") == true, "WIP HOST launchd scratch gate")
        let helper = try scratchExecutable("HOSTSessionHelper", environmentKey: "TD_HOST_SCRATCH_HELPER", version: "HOST scratch helper gate 3")
        let fakeApp = try scratchExecutable("HOSTScratchApp", environmentKey: "TD_HOST_SCRATCH_APP", version: "HOST scratch app gate 3")
        let root = try scratch(), paths = try BackendHOSTPaths(dataDirectory: root)
        let plan = try BackendHOSTLaunchAgent(paths: paths, version: "scratch-v1", launchAgentsDirectory: root.appendingPathComponent("agents"))
        var activeClient: BackendHOSTClient?
        defer {
            try? activeClient?.stopAll(); activeClient?.detach()
            let cleanup = Process(); cleanup.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            cleanup.arguments = ["bootout", "gui/" + String(geteuid()) + "/" + plan.label]
            cleanup.standardOutput = FileHandle.nullDevice; cleanup.standardError = FileHandle.nullDevice
            do { try cleanup.run(); cleanup.waitUntilExit() } catch { XCTFail("Owned scratch launchd cleanup failed.") }
        }
        let result = try await plan.connectOrStart(sourceHelper: helper)
        let client: BackendHOSTClient
        switch result { case .attached(let value, _), .started(let value): client = value }
        activeClient = client
        let one = try client.create(launch(root, tag: "app-one")), two = try client.create(launch(root, tag: "app-two"))
        let firstOne = try XCTUnwrap(client.snapshot(one.id)?.pid), firstTwo = try XCTUnwrap(client.snapshot(two.id)?.pid)
        let app = Process(), output = Pipe(), ready = expectation(description: "fake app attached")
        app.executableURL = fakeApp; app.arguments = [root.path]; app.standardOutput = output; app.standardError = FileHandle.nullDevice
        let exited = XCTestExpectation(description: "killed fake app exit observed"), cleanupExited = XCTestExpectation(description: "owned fake app cleanup exit observed")
        app.terminationHandler = { _ in exited.fulfill(); cleanupExited.fulfill() }
        try app.run()
        addTeardownBlock {
            if app.isRunning { XCTAssertEqual(Darwin.kill(app.processIdentifier, SIGKILL), 0) }
            await self.fulfillment(of: [cleanupExited], timeout: 5)
            XCTAssertFalse(app.isRunning)
        }
        DispatchQueue.global().async { if !output.fileHandleForReading.availableData.isEmpty { ready.fulfill() } }
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(Darwin.kill(app.processIdentifier, SIGKILL), 0)
        await fulfillment(of: [exited], timeout: 5)
        guard !app.isRunning else { throw BackendHOSTFailure.invalid("The owned killed fake app did not report its exit.") }
        XCTAssertEqual(app.terminationReason, .uncaughtSignal); XCTAssertEqual(app.terminationStatus, SIGKILL)
        let replacement = try BackendHOSTClient(paths: paths)
        defer { replacement.detach() }
        XCTAssertEqual(replacement.hello.hostPID, client.hello.hostPID)
        XCTAssertEqual(try replacement.snapshot(one.id)?.pid, firstOne); XCTAssertEqual(try replacement.snapshot(two.id)?.pid, firstTwo)
        try replacement.write(one.id, bytes: Data("after-app-kill-one\n".utf8)); try replacement.write(two.id, bytes: Data("after-app-kill-two\n".utf8))
        let attached = expectation(description: "replacement app has continued output"), seen = HOSTObservedOutput(expected: ["app-one", "app-two", "after-app-kill-one", "after-app-kill-two"], ready: attached)
        try replacement.attach(onSnapshot: { seen.receive($0.replay) }, onEvent: { seen.receive($0.text ?? "") }, onReady: {}, onDisconnect: {})
        await fulfillment(of: [attached], timeout: 5)
        let idle = expectation(description: "idle host exits without a KeepAlive loop")
        let monitor = DispatchSource.makeProcessSource(identifier: client.hello.hostPID, eventMask: .exit, queue: .global())
        monitor.setEventHandler { idle.fulfill() }; monitor.resume()
        defer { monitor.cancel() }
        try replacement.stopAll()
        XCTAssertEqual(try replacement.snapshot(one.id)?.pid, nil)
        XCTAssertEqual(try replacement.snapshot(two.id)?.pid, nil)
        await fulfillment(of: [idle], timeout: 40)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socket))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.activeFile.path))
    }
    private func scratchExecutable(_ name: String, environmentKey: String, version: String) throws -> URL {
        // SwiftPM's test subprocess need not inherit every build environment
        // variable. The O2 source path and test bundle both identify its actual
        // build products; no installed helper/app is considered.
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let supplied = ProcessInfo.processInfo.environment[environmentKey].map { URL(fileURLWithPath: $0) }
        let adjacent = Bundle(for: HOSTIntegrationTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent(name)
        let candidates = supplied.map { [$0] } ?? [adjacent, package.appendingPathComponent(".build/debug/" + name)]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw BackendHOSTFailure.invalid("The current test build did not produce " + name + ". Build that scratch product with both HOST flags before running this gate.")
        }
        let probe = Process(), output = Pipe()
        probe.executableURL = binary; probe.arguments = ["--host-test-gate-version"]
        probe.standardOutput = output; probe.standardError = FileHandle.nullDevice
        try probe.run()
        let reply = output.fileHandleForReading.readDataToEndOfFile(); probe.waitUntilExit()
        guard probe.terminationStatus == 0, String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == version else {
            throw BackendHOSTFailure.invalid(name + " is stale or was built without both HOST flags. No scratch host was started.")
        }
        return binary
    }
}

private final class HOSTObservedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let expected: [String]
    private let ready: XCTestExpectation
    private var text = ""
    private var completed = false
    init(expected: [String], ready: XCTestExpectation) { self.expected = expected; self.ready = ready }
    func receive(_ part: String) {
        let done = lock.withLock { () -> Bool in
            if completed { return false }; text += part
            if expected.allSatisfy({ text.contains($0) }) { completed = true; return true }; return false
        }
        if done { ready.fulfill() }
    }
}
#endif
