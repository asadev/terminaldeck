import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

private actor BackendCopilotRemoteTestSpawnServices: BackendCopilotRemoteSpawnServices {
    let userData: String
    let home: String
    let provider: String
    var starts: [(BackendCreateSessionInput, BackendLaunchContext)] = []
    var stopped: [String] = []
    var announced: [String] = []
    var measured = 0
    init(userData: String, home: String, provider: String = "claude") { self.userData = userData; self.home = home; self.provider = provider }
    func resolveProfile(cwd: String) -> BackendAccountProfile {
        .init(id: "system", name: "Personal", provider: "claude", configDir: home + "/.claude", system: true, color: "--accent", createdAt: 0,
            lastUsedAt: nil, loginStore: nil, keptSlots: nil)
    }
    func sessionEnvironment(profile: BackendAccountProfile) -> [String: String] { [:] }
    func measureRecordsFence(cwd: String, profile: BackendAccountProfile) throws -> BackendCopilotRemoteFenceMeasurement {
        measured += 1
        let paths = ["routines", "routine-state.json", "copilot-log", "remote/remote-device-kinds.json", "remote/remote-auth.json", "remote/access-keys.json", "plugin-grants.json"].map { userData + "/" + $0 }
        return .init(fenceID: BackendMacConfinement.recordsFenceID, records: try .init(paths: paths))
    }
    func tools() -> [BackendCopilotLayerTool] { [.init(wire: "sessions_list", tier: "read", title: "List sessions")] }
    func startSession(_ input: BackendCreateSessionInput, context: BackendLaunchContext) -> BackendSessionMeta {
        starts.append((input, context))
        return .init(id: "spawn-\(starts.count)", input: input, spawn: .init(provider: provider, command: "/test/claude", args: [], path: "/usr/bin", agentSessionId: UUID().uuidString, resumed: false))
    }
    func announce(_ session: BackendSessionMeta) { announced.append(session.id) }
    func stopSession(_ sessionID: String) { stopped.append(sessionID) }
}
@Suite("Remote Hoot field projection and native spawn/transcript wiring")
struct BackendCopilotRemoteWiringTests: Sendable {
    private func row(_ id: String) -> NativeRPCValue {
        .object([.init("id", .string(id)), .init("at", .string("2026-08-17T09:00:00.000Z")), .init("tool", .string("sessions.send")),
            .init("tier", .string("act")), .init("detail", .string("typed into api")), .init("outcome", .string("ok")),
            .init("args", .object([.init("text", .string("deploy to production"))])), .init("result", .string("private result")),
            .init("confirmed", .object([.init("reason", .null)])), .init("caller", .object([.init("kind", .string("local"))]))])
    }
    @Test func actionRowsLoseArgsResultsAndUnknownFieldsButKeepRefusalAttribution() throws {
        let raw = row("row-1"), wire = BackendCopilotRemoteWiring.actionRow(raw)
        #expect(Set(wire.fields!.map(\.key)) == ["id", "at", "tool", "tier", "outcome", "detail", "refusal", "deviceId"])
        #expect(wire["deviceId"] == .null); #expect(wire["refusal"] == .null)
        #expect(!String(decoding: try wire.encodedJSON(), as: UTF8.self).contains("deploy to production"))
        let refused = BackendCopilotRemoteWiring.actionRow(raw.setting("confirmed", .object([.init("reason", .string("not-granted"))]))
            .setting("caller", .object([.init("kind", .string("remote")), .init("deviceId", .string("phone"))])))
        #expect(refused["refusal"].string == "not-granted"); #expect(refused["deviceId"].string == "phone")
        #expect(BackendCopilotRemoteWiring.actionRow(raw.setting("caller", .missing))["deviceId"] == .null)
    }
    @Test func sessionsOnlyIncludeCopilotOriginAndCarryActionRowLink() {
        func session(_ id: String, origin: BackendSessionOrigin?, link: String? = nil) -> BackendSessionMeta {
            var input = BackendCreateSessionInput(cwd: "/work/api", provider: "claude")
            input.origin = origin; input.originRunId = link
            return .init(id: id, input: input, spawn: .init(provider: "claude", command: "/test/claude", args: [], path: "/usr/bin"))
        }
        let rows = BackendCopilotRemoteWiring.sessions([session("mine", origin: nil), session("user", origin: .user), session("theirs", origin: .copilot, link: "row-9"), session("old", origin: .copilot)]) { _ in "idle" }
        #expect(rows.map { $0["id"].string! } == ["theirs", "old"])
        #expect(rows[0]["originRunId"].string == "row-9"); #expect(rows[1]["originRunId"] == .null)
    }
    @Test func logTailIsNewestLastBoundedPagesBackAndUnknownCursorUsesEnd() {
        let rows = (0..<500).map { row("row-\($0)") }
        let newest = BackendCopilotRemoteWiring.tail(rows, limit: 10)
        #expect(newest.rows.map { $0["id"].string! } == (490..<500).map { "row-\($0)" }); #expect(newest.more)
        #expect(!BackendCopilotRemoteWiring.tail(Array(rows.prefix(5)), limit: 10).more)
        #expect(BackendCopilotRemoteWiring.tail(rows, limit: 3, before: "row-100").rows.map { $0["id"].string! } == ["row-97", "row-98", "row-99"])
        #expect(BackendCopilotRemoteWiring.tail(rows, limit: 2, before: "rotated-away").rows.map { $0["id"].string! } == ["row-498", "row-499"])
        #expect(BackendCopilotRemoteWiring.tail(rows, limit: 100000).rows.count == 200)
        #expect(BackendCopilotRemoteWiring.tail(rows, limit: 0).rows.count == 1)
    }
    @Test func spawnUsesSameTrustLayerProfileFenceAndFreshStrictMCPArguments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCopilotRemoteSpawn-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data").path, home = root.appendingPathComponent("home").path
        let paths = BackendCopilotPaths(userData: data)
        #expect(BackendCopilotHome.scaffold(paths).error == nil)
        let services = BackendCopilotRemoteTestSpawnServices(userData: data, home: home)
        let spawn = BackendCopilotRemoteSpawner(userData: data, accountHome: home, inheritedEnvironment: ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("wrong-config").path], services: services)
        _ = try await spawn.spawn(.init(cwd: paths.root, mcpConfig: paths.root + "/deck-control-device-phone.json", deviceID: "phone"))
        _ = try await spawn.spawn(.init(cwd: paths.root, mcpConfig: paths.root + "/deck-control-device-tablet.json", deviceID: "tablet"))
        #expect(await services.measured == 2)
        let first = try #require(await services.starts.first)
        #expect(first.0.cols == 120 && first.0.rows == 30)
        #expect(first.0.provider == "claude" && first.0.resume == false && first.0.profileId == "system" && first.0.origin == .copilot)
        #expect(first.1.deviceBoundary == nil); #expect(first.1.appFenceID == BackendMacConfinement.recordsFenceID)
        #expect(first.1.extraArguments == ["--mcp-config", paths.root + "/deck-control-device-phone.json", "--strict-mcp-config", "--append-system-prompt-file", paths.layer.composed])
        #expect(await services.announced == ["spawn-1", "spawn-2"])
        #expect(FileManager.default.fileExists(atPath: home + "/.claude.json"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("wrong-config/.claude.json").path))
    }
    @Test func shellFallbackIsStoppedBeforeAnyAnnouncement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCopilotRemoteShell-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = BackendCopilotPaths(userData: root.path)
        #expect(BackendCopilotHome.scaffold(paths).error == nil)
        let services = BackendCopilotRemoteTestSpawnServices(userData: root.path, home: root.appendingPathComponent("home").path, provider: "shell")
        let spawn = BackendCopilotRemoteSpawner(userData: root.path, accountHome: root.appendingPathComponent("home").path, inheritedEnvironment: [:], services: services)
        await #expect(throws: NativeRPCError.self) { _ = try await spawn.spawn(.init(cwd: paths.root, mcpConfig: paths.root + "/run.json", deviceID: "phone")) }
        #expect(await services.stopped == ["spawn-1"]); #expect(await services.announced.isEmpty)
    }
    @Test func namedTranscriptNeverReadsNewestDeskConversationAndEventsAppendParsedChat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCopilotRemoteChat-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = NativeTranscriptScope(configDirectory: root.appendingPathComponent(".claude").path)
        let cwd = root.appendingPathComponent("copilot").path
        let directory = try #require(NativeTranscriptPaths.projectDirectories(cwd, scope: scope).first)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let desk = URL(fileURLWithPath: directory).appendingPathComponent("desk.jsonl")
        try Data("{\"type\":\"assistant\",\"uuid\":\"desk\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"private desktop conversation\"}]}}\n".utf8).write(to: desk)
        let recorder = BackendCopilotRemoteTestRecorder()
        let watcher = BackendCopilotRemoteChatWatcher(cwd: cwd, agentSessionID: "phone", scope: scope) { update in
            if let frame = try? BackendRemoteServerMessage(.copilotChat, fields: [.init("run", .string("phone")), .init("messages", .array(update.messages))]) { await recorder.receive(frame) }
        }
        try await watcher.start()
        #expect(await recorder.all(.copilotChat).isEmpty)
        let named = URL(fileURLWithPath: directory).appendingPathComponent("phone.jsonl")
        try Data("{\"type\":\"assistant\",\"uuid\":\"phone\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"PONG\"}]}}\n".utf8).write(to: named)
        let frame = await recorder.next(.copilotChat)
        #expect(frame.value["messages"].elements?.first?["text"].string == "PONG")
        #expect(!frame.value.compact.contains("private desktop conversation"))
        await watcher.stop()
    }
}
