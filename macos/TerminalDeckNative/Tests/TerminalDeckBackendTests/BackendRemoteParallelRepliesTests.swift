import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// 29 Oct 2026 (the phones' opening screen, ~0.6 s on every launch): the reads a phone sends together are answered at
/// the same time, each reply matched to its request; refusals without a rid keep their order; a write still runs after
/// every read before it and before every read after it.
@Suite("Remote host answers reads alongside each other", .serialized)
struct BackendRemoteParallelRepliesTests {
    private actor Capture {
        var frames: [NativeRPCValue] = []
        func receive(_ text: String) throws { frames.append(try NativeRPCValue.parseJSON(Data(text.utf8))) }
    }
    /// Lets the reads through only once `count` of them are inside at the same time; a host that answers one after
    /// another never gets there, and the first read gives up after its wait.
    private actor Gate {
        let count: Int
        private var inside = 0, most = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []
        init(_ count: Int) { self.count = count }
        func arrive() async -> Bool {
            inside += 1; most = max(most, inside)
            if inside >= count { waiting.forEach { $0.resume() }; waiting = []; return true }
            let opened = await withTaskGroup(of: Bool.self) { group in
                group.addTask { await self.wait(); return true }
                group.addTask { try? await Task.sleep(for: .seconds(3)); return false }
                let first = await group.next() ?? false
                group.cancelAll(); await self.give()
                return first
            }
            return opened
        }
        private func wait() async { if inside >= count { return }; await withCheckedContinuation { waiting.append($0) } }
        private func give() { waiting.forEach { $0.resume() }; waiting = [] }
        func leave() { inside -= 1 }
        var mostInside: Int { most }
    }
    private actor Log {
        var lines: [String] = []
        func note(_ line: String) { lines.append(line) }
    }

    private struct Fixture {
        let host: BackendRemoteHost, trust: BackendRemoteTrustStore, capture: Capture, connection: UUID, directory: URL
        func frame(_ type: String, _ fields: [NativeRPCValue.Field]) throws -> String {
            String(decoding: try NativeRPCValue.object([.init("t", .string(type))] + fields).encodedJSON(), as: UTF8.self)
        }
        func finish() async { await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: directory) }
    }

    private func fixture(panel: @escaping @Sendable (BackendRemoteClientMessage) async throws -> [BackendRemoteServerMessage],
                         settings: @escaping @Sendable (BackendRemoteClientMessage) async throws -> [BackendRemoteServerMessage] = { _ in [] }) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteParallel-" + UUID().uuidString)
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let device = try await trust.redeem(try await trust.createPairingOffer().token, name: "Test phone", address: "test", publicKey: nil)
        try await trust.approve(device.device.id, kind: .mine)
        try await trust.setPhoneAccess(device.device.id, level: .full)
        let capture = Capture(), clock = INT2PhoneHostClock()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), state: NativeStateStore(),
            home: directory.path, hostName: "Test", appVersion: "test", privateRoots: [],
            sleep: { try await clock.sleep($0) }, clock: { clock.now() })
        try await host.register(.init(capability: "panels", messageTypes: ["panel.read", "settings.read"], policy: .grantedDevice) { message, _ in try await panel(message) })
        try await host.register(.init(capability: "settings", messageTypes: ["settings.apply"], policy: .grantedDevice) { message, _ in try await settings(message) })
        try await host.start()
        let connection = try #require(await host.accept(.init(address: "test", send: { try await capture.receive($0) }, close: { _, _ in })))
        let fixture = Fixture(host: host, trust: trust, capture: capture, connection: connection, directory: directory)
        await host.receive(connection, text: try fixture.frame("hello", [.init("protocol", .number(1)), .init("token", .string(device.credential)),
            .init("device", .object([.init("name", .string("Test phone")), .init("platform", .string("ios"))])), .init("capabilities", .array([]))]))
        return fixture
    }

    /// A read's answer: a settings reading carries its request's rid; a panel's rows, its path (how phones match them).
    private static func rows(_ message: BackendRemoteClientMessage) throws -> [BackendRemoteServerMessage] {
        if message.type == "settings.read" {
            return [try BackendRemoteServerMessage(.settingsState, fields: [.init("rid", .string(message["rid"].string ?? "")), .init("settings", .array([]))])]
        }
        var fields: [NativeRPCValue.Field] = [.init("panel", .string("tasks")), .init("path", .string(message["path"].string ?? "")), .init("rows", .array([]))]
        if let rid = message["rid"].string { fields.append(.init("rid", .string(rid))) }
        return [try BackendRemoteServerMessage(.panelRows, fields: fields)]
    }

    @Test("four reads sent together are answered at the same time, each to its own request")
    func fourReadsAtOnce() async throws {
        let gate = Gate(4)
        let fixture = try await fixture(panel: { message in
            let together = await gate.arrive()
            defer { Task { await gate.leave() } }
            guard together else { throw NativeRPCError(code: "unavailable", message: "The reads were answered one after another.") }
            return try Self.rows(message)
        })
        var answered: [Task<Void, Never>] = []
        // Two kinds the opening screen sends: reads with a request id, and panel reads matched by their path.
        let frames: [(String, [NativeRPCValue.Field])] = [
            ("settings.read", [.init("rid", .string("r-1"))]), ("panel.read", [.init("panel", .string("tasks")), .init("path", .string("/work/a"))]),
            ("settings.read", [.init("rid", .string("r-2"))]), ("panel.read", [.init("panel", .string("tasks")), .init("path", .string("/work/b"))])]
        for (type, fields) in frames {
            let taken = try #require(await fixture.host.take(fixture.connection, text: try fixture.frame(type, fields)))
            #expect(taken.alongside)
            answered.append(taken.answered)
        }
        for task in answered { await task.value }
        let readings = await fixture.capture.frames.filter { $0["t"].string == "settings.state" }
        #expect(Set(readings.compactMap { $0["rid"].string }) == ["r-1", "r-2"], "each reading answers its own request id")
        let rows = await fixture.capture.frames.filter { $0["t"].string == "panel.rows" }
        #expect(Set(rows.compactMap { $0["path"].string }) == ["/work/a", "/work/b"])
        #expect(await fixture.capture.frames.filter { $0["t"].string == "error" }.isEmpty)
        #expect(await gate.mostInside == 4)
        await fixture.finish()
    }

    @Test("reads still running stop when the connection closes")
    func closingStopsReads() async throws {
        let log = Log()
        let fixture = try await fixture(panel: { message in
            await log.note("start")
            do { try await Task.sleep(for: .seconds(30)) } catch { await log.note("stopped"); throw error }
            return try Self.rows(message)
        })
        let taken = try #require(await fixture.host.take(fixture.connection, text: try fixture.frame("panel.read",
            [.init("panel", .string("tasks")), .init("path", .string("/work/a"))])))
        while await log.lines.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let closedAt = Date()
        await fixture.host.closed(fixture.connection)
        await taken.answered.value
        #expect(Date().timeIntervalSince(closedAt) < 5, "the read stopped instead of running on")
        #expect(await log.lines == ["start", "stopped"])
        await fixture.finish()
    }

    @Test("file, folder and git reads keep their order: older phones apply them as the newest wins")
    func fileReadsStayInOrder() {
        for type in ["files.list", "files.read", "git.status", "git.diff", "folders.browse"] {
            #expect(!BackendRemoteHost.readsAlongside.contains(type))
        }
        #expect(BackendRemoteHost.readsAlongside.isSuperset(of: ["list", "panel.read", "pictures", "browser.windows"]))
    }

    @Test("a refusal without a rid waits for the earlier read's answer")
    func refusalsKeepTheirOrder() async throws {
        let gate = Gate(2)
        let fixture = try await fixture(panel: { message in
            if message["path"].string == "/work/slow" {
                _ = await gate.arrive()   // held until the second read is inside: it refuses first
                try await Task.sleep(for: .milliseconds(150))
                return try Self.rows(message)
            }
            _ = await gate.arrive()
            throw NativeRPCError(code: "unavailable", message: "The tasks panel cannot be read for this project.")
        })
        let first = try #require(await fixture.host.take(fixture.connection, text: try fixture.frame("panel.read",
            [.init("panel", .string("tasks")), .init("path", .string("/work/slow"))])))
        let second = try #require(await fixture.host.take(fixture.connection, text: try fixture.frame("panel.read",
            [.init("panel", .string("tasks")), .init("path", .string("/work/refused"))])))
        await first.answered.value; await second.answered.value
        let frames = await fixture.capture.frames.filter { ["panel.rows", "error"].contains($0["t"].string ?? "") }
        #expect(frames.map { $0["t"].string } == ["panel.rows", "error"], "the oldest waiting read is answered before the refusal")
        #expect(frames.last?["rid"] == .missing)
        await fixture.finish()
    }

    @Test("a write waits for the reads before it and holds back the reads after it")
    func writesStayInOrder() async throws {
        let log = Log()
        let fixture = try await fixture(panel: { message in
            let path = message["path"].string ?? ""
            await log.note("start " + path)
            try await Task.sleep(for: .milliseconds(path == "/work/after" ? 10 : 120))
            await log.note("end " + path)
            return try Self.rows(message)
        }, settings: { message in
            await log.note("write")
            return [try BackendRemoteServerMessage(.settingsApplied, fields: [.init("rid", .string(message["rid"].string ?? "")), .init("ok", .bool(true)),
                .init("message", .string("")), .init("setting", .object([]))])]
        })
        var tasks: [Task<Void, Never>] = []
        for (type, path) in [("panel.read", "/work/a"), ("panel.read", "/work/b"), ("settings.apply", ""), ("panel.read", "/work/after")] {
            let fields: [NativeRPCValue.Field] = type == "panel.read" ? [.init("panel", .string("tasks")), .init("path", .string(path))]
                : [.init("rid", .string("w1")), .init("key", .string("general.restoreSessions")), .init("value", .string("on"))]
            let taken = try #require(await fixture.host.take(fixture.connection, text: try fixture.frame(type, fields)))
            #expect(taken.alongside == (type == "panel.read"))
            tasks.append(taken.answered)
        }
        for task in tasks { await task.value }
        let lines = await log.lines
        let write = try #require(lines.firstIndex(of: "write"))
        #expect(lines.prefix(write).filter { $0.hasPrefix("end ") }.count == 2, "both earlier reads finished before the write")
        #expect(Array(lines.suffix(from: write + 1)) == ["start /work/after", "end /work/after"], "the later read began after the write")
        #expect(Array(lines.prefix(2)).sorted() == ["start /work/a", "start /work/b"], "the two reads ran at the same time")
        await fixture.finish()
    }
}
