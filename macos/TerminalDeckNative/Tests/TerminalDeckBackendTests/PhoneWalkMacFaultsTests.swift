import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// 27 Oct live walk (phone at Full control, this Mac's own device): the Mac-side faults a–g.

@Suite("Phone walk 27 Oct: the Mac side", .serialized)
struct PhoneWalkMacFaultsTests {
    private final class Order: @unchecked Sendable {
        private let lock = NSLock(); private var steps: [String] = []
        func note(_ step: String) { lock.withLock { steps.append(step) } }
        var all: [String] { lock.withLock { steps } }
    }

    /// d) The remote runtime's start wrapper dropped what a feature advertises besides itself, so `browser.thumbs`
    /// never reached the phone and its Browser cards had no pictures.
    @Test func theStartWrapperKeepsWhatAFeatureAdvertisesBesidesItself() async throws {
        let order = Order()
        let browser = BackendRemoteHostFeature(capability: "browser.control", messageTypes: ["browser.windows"], policy: .ownerOnly,
                                               additionalAdvertisedCapabilities: ["browser.thumbs"]) { _, _ in order.note("handled"); return [] }
        let wrapped = BackendRemoteServeRegistration.afterStart(browser) { order.note("started") }
        #expect(wrapped.additionalAdvertisedCapabilities == ["browser.thumbs"])
        #expect(wrapped.capability == "browser.control" && wrapped.messageTypes == ["browser.windows"] && wrapped.policy == .ownerOnly)
        let context = BackendRemoteHostContext(connectionID: UUID(), deviceID: "phone-1", kind: .mine, address: "relay", peerPublicKey: nil,
            claimedCapabilities: ["browser.thumbs"], reach: .init(kind: .mine, unrestricted: true, folders: [], accounts: nil, drivesWindows: true),
            phoneAccess: .full)
        _ = try await wrapped.handle(BackendRemoteClientMessage(.object([.init("t", .string("browser.windows"))])), context)
        #expect(order.all == ["started", "handled"])
    }

    private static func phone(_ level: BackendINT2PhoneAccessLevel?, kind: BackendRemoteDeviceKind = .mine) -> BackendRemoteHostContext {
        BackendRemoteHostContext(connectionID: UUID(), deviceID: "phone-1", kind: kind, address: "relay", peerPublicKey: nil, claimedCapabilities: [],
            reach: .init(kind: kind, unrestricted: kind == .mine, folders: ["/Projects/Phone"], accounts: nil, drivesWindows: false), phoneAccess: level)
    }
    private static func message(_ json: String) -> BackendRemoteClientMessage {
        guard case .message(let parsed) = BackendRemoteProtocol.parseClientMessage(json) else { preconditionFailure("unparsed: " + json) }
        return parsed
    }

    /// b) Switch account and usage from a phone: Full control only, run under the owner's own context (Decker D3, the
    /// 63dc2ad9 pattern). Below Full they are refused in plain words and the owner's context is never made.
    @Test func switchAndUsageAreFullControlOnlyAndRunAsTheMacsOwn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("walk-b-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trust = BackendRemoteTrustStore(directory: root)
        let gate = BackendRemoteServeSessionGate(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }))
        let order = Order()
        let owner: BackendRemoteOwnerScope.Owner = { order.note("owner"); return NativeRPCContext(caller: .nativeApp, ownerID: "test-owner") }
        let accounts = BackendRemoteServeAccountService(profiles: { [] }, attribution: { _ in nil },
            switchAccount: { _, _ in order.note("switch"); return .init(ok: true, message: "", session: nil) }, owner: owner)
        let account = try #require(accounts.accountFeature(trust: trust, gate: gate))
        let usage = BackendRemoteServeUsageService(plan: { _ in order.note("plan"); return .null }, refresh: { _, _ in .null },
                                                   context: { _, _ in .null }, owner: owner).feature(gate: gate)
        let switching = Self.message(#"{"t":"account.switch","rid":"r1","id":"s-1","accountId":"claude-work"}"#)
        let reading = Self.message(#"{"t":"usage.read","rid":"r2","id":"s-1","want":"plan"}"#)
        for level in [BackendINT2PhoneAccessLevel.work, .look] {
            let refused = try await account.handle(switching, Self.phone(level))
            #expect(refused.first?.value["code"].string == "unauthorized")
            #expect(refused.first?.value["message"].string == BackendRemoteOwnerScope.switchNeedsFull)
            let usageRefused = try await usage.handle(reading, Self.phone(level))
            #expect(usageRefused.first?.value["message"].string == BackendRemoteOwnerScope.usageNeedsFull)
        }
        #expect(order.all.isEmpty, "nothing ran and no owner context was made below Full")
        // At Full the request gets past the level and runs under the owner's context (here it then finds no such session).
        let answered = try await account.handle(switching, Self.phone(.full))
        #expect(answered.first?.value["code"].string == "unknown-session")
        #expect(order.all == ["owner"])
        // A Mac without levels: only its own device.
        #expect(BackendRemoteOwnerScope.permits(Self.phone(nil, kind: .mine)) && !BackendRemoteOwnerScope.permits(Self.phone(nil, kind: .guest)))
        // The owner's context is what the operation runs with; without an owner, the caller's own.
        let ran = try await BackendRemoteOwnerScope.run(owner, fallback: Self.phone(.full).rpcContext) { $0.ownerID }
        #expect(ran == "test-owner")
        let fallback = try await BackendRemoteOwnerScope.run(nil, fallback: Self.phone(.full).rpcContext) { $0.ownerID }
        #expect(fallback == "phone-1")
    }

    /// a) Decker D2: a phone at Full control starts chats and sessions like the Mac does, with no folder sandbox; every
    /// lower level (or none) keeps it.
    @Test func onlyFullControlStartsWithoutTheFolderSandbox() {
        #expect(!BackendINT2PhoneAccessLevel.sandboxesStarts(.full))
        for level in [BackendINT2PhoneAccessLevel.work, .hoot, .look] { #expect(BackendINT2PhoneAccessLevel.sandboxesStarts(level)) }
        #expect(BackendINT2PhoneAccessLevel.sandboxesStarts(nil))
    }

    /// a) Below Full the sandbox stays, but the per-session files the app hands the AI (its settings, its tool lease,
    /// its instructions) are readable by their exact paths, and only those inside the app's data folder. A real
    /// Seatbelt run proves the handed file opens and its neighbour does not.
    @Test func theSandboxReadsTheFilesTheAppHandsItAndNothingBeside() async throws {
        let root = URL(fileURLWithPath: BackendMacConfinement.kernelPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("walk-a-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data"), settings = data.appendingPathComponent("session-memory/settings")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        let handed = settings.appendingPathComponent("s-1.json"), neighbour = settings.appendingPathComponent("s-2.json")
        let outside = root.appendingPathComponent("outside.json")
        for file in [handed, neighbour, outside] { try Data("{}".utf8).write(to: file) }
        let work = root.appendingPathComponent("work"), home = root.appendingPathComponent("device-home")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let args = ["--settings", handed.path, "--mcp-config", outside.path, "--append-system-prompt-file", settings.path,
                    "--settings", "{\"inline\":true}", "--model", "opus"]
        let files = BackendMacConfinement.handedFiles(args, appDataRoot: data.path)
        #expect(files == [handed.path], "only the handed file inside the data folder; not one outside it, a folder or inline JSON")
        let plan = try BackendMacConfinement.plan(folder: work.path, home: home.path, accountHome: NSHomeDirectory(), path: "/usr/bin:/bin",
                                                  writable: [], files: files, projects: [])
        let profile = BackendMacConfinement.profile(plan)
        #expect(profile.contains("(allow file-read* (literal \(BackendMacConfinement.seatbeltString(handed.path))))"))
        #expect(!profile.contains(neighbour.path) && !profile.contains(outside.path))
        func cat(_ file: URL) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", profile, "/bin/cat", file.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); return process.terminationStatus
        }
        #expect(try cat(handed) == 0)
        #expect(try cat(neighbour) != 0)
        #expect(try cat(outside) != 0)
    }

    /// i) Usage on a chat in a folder that is not an open project (walk-scratch) was refused "That folder is not an
    /// open project". A session's own reading is scoped to that session's folder, never wider than the caller's grant.
    @Test func aSessionsUsageReadsItsOwnFolderWithoutAProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("walk-i-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("walk-scratch"), config = root.appendingPathComponent("login")
        let directory = config.appendingPathComponent("projects").appendingPathComponent(NativeTranscriptPaths.encodeProjectPath(folder.path))
        for path in [folder, directory] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let line = NativeRPCValue.object([.init("type", .string("user")), .init("cwd", .string(folder.path)), .init("sessionId", .string("chat-1")),
            .init("message", .object([.init("content", .string("hello"))]))]).compact
        try (line + "\n").write(to: directory.appendingPathComponent("chat-1.jsonl"), atomically: true, encoding: .utf8)
        let state = NativeStateStore(initialState: NativeStateStore.defaults)   // no project added: a plain folder
        let files = BackendFilesystemService(authority: BackendFilesystemAuthority { _ in .init(readRoots: [root], writeRoots: [root]) })
        let projects = try BackendProjectService(store: state, files: files, home: root.path, appDataRoot: root.appendingPathComponent("data"), liveSessions: { [] })
        func cost(_ granted: [String]?) -> BackendCostService {
            BackendCostService(projects: projects, scopeProvider: { project, _ in
                if project != nil { throw NativeRPCError(code: "access-denied", message: "That folder is not an open project") }
                return .init(configDirectory: config.path, projectFolders: granted)
            }, push: { _, _, _ in })
        }
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "walk-i")
        let owner = cost(nil)
        await #expect(throws: NativeRPCError.self) { _ = try await owner.files(project: folder.path, context: context) }
        let own = try await owner.sessionTranscripts(folder: folder.path, context: context)
        #expect(own.files.map(\.path) == [directory.appendingPathComponent("chat-1.jsonl").path])
        #expect(own.scope.projectFolders == [folder.path])
        // A caller limited to other folders never reads this session's transcripts.
        await #expect(throws: NativeRPCError.self) { _ = try await cost([root.appendingPathComponent("other").path]).sessionTranscripts(folder: folder.path, context: context) }
        let inside = try BackendCostService.sessionScope(.init(configDirectory: config.path, projectFolders: [root.path]), folder: folder.path)
        #expect(inside.projectFolders == [folder.path])
        await owner.stop(); await state.close()
    }

    /// h) Opening a Mac browser window from a phone at Full was refused "The current browser caller has no matching
    /// native grant" (the window-opening check took only this Mac's own window). At Full, the person's own device with
    /// its window grant passes that one check, as the Mac's window does; nothing else, and nothing below Full.
    @Test func aFullControlPhoneOpensMacBrowserWindowsAndNothingMore() {
        func opens(_ level: BackendINT2PhoneAccessLevel?, _ kind: BackendRemoteDeviceKind = .mine, drives: Bool = true,
                   _ operation: String = "browser:create", file: URL? = nil) -> Bool {
            BackendRemoteOwnerScope.opensBrowserWindows(level: level, kind: kind, drivesWindows: drives, operation: operation, file: file)
        }
        #expect(opens(.full) && opens(.full, .mine, "browser.workers"))
        for level in [BackendINT2PhoneAccessLevel.work, .hoot, .look] { #expect(!opens(level), "below Full the current rules stay") }
        #expect(!opens(nil))
        #expect(!opens(.full, .guest), "a guest device never")
        #expect(!opens(.full, drives: false), "the device's own window grant still binds it")
        #expect(!opens(.full, file: URL(fileURLWithPath: "/tmp/x")), "never a file")
        for other in ["browser.scraping.workers", "browser.scrape", "browser:pick", "browser.workers.release"] {
            #expect(!opens(.full, .mine, other), "only the window-opening checks: \(other)")
        }
    }
}
