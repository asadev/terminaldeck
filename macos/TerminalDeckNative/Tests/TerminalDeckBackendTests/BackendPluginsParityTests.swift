import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendPluginsParityConsent: BackendPluginsConsent {
    var yes = true
    private(set) var questions: [BackendPluginsConsentRequest] = []
    func set(_ value: Bool) { yes = value }
    func ask(_ question: BackendPluginsConsentRequest) -> BackendPluginsConsentOutcome {
        questions.append(question); return .init(granted: yes, at: 1)
    }
    func shutdown() async {}
}
private actor BackendPluginsParityPeer: BackendPluginsRunningProcess {
    let launch: BackendPluginsProcessLaunch, number: Int32
    private let answer: BackendPluginsProcess.RequestHandler, exit: @Sendable (String) async -> Void
    private let silent: Bool
    private var active = false
    private(set) var requests: [String] = [], initializeTimeout: Int?
    var alive: Bool { active }
    var pid: Int32? { active ? number : nil }
    init(launch: BackendPluginsProcessLaunch, number: Int32, silent: Bool,
         answer: @escaping BackendPluginsProcess.RequestHandler, exit: @escaping @Sendable (String) async -> Void) {
        self.launch = launch; self.number = number; self.silent = silent; self.answer = answer; self.exit = exit
    }
    func start() async throws { active = true }
    func stop(_ why: String) async { await close(why) }
    func kill(_ why: String) async { await close(why) }
    private func close(_ why: String) async { guard active else { return }; active = false; await exit(why) }
    func request(_ method: String, params: NativeRPCValue, timeoutMilliseconds: Int?) async throws -> NativeRPCValue {
        requests.append(method)
        if method == "initialize" {
            initializeTimeout = timeoutMilliseconds
            if silent { throw BackendPluginsError(-32000, "it did not answer initialize within 0.5 seconds") }
            return .object([.init("protocol", .number(1))])
        }
        guard active else { throw BackendPluginsError(-32000, "the plugin is not running") }
        let args = params["arguments"]
        switch params["name"].string {
        case "echo": return .object([.init("echoed", args["text"])])
        case "env":
            return .object([.init("env", .object(launch.environment.keys.sorted().map { .init($0, .string(launch.environment[$0]!)) })),
                .init("cwd", .string(launch.cwd))])
        case "ask":
            do { return .object([.init("result", try await answer(args["method"].string ?? "", args["params"]))]) }
            catch {
                let failure = error as? BackendPluginsError ?? .init(-32000, error.localizedDescription)
                return .object([.init("error", .object([.init("code", .number(Double(failure.code))), .init("message", .string(failure.message))]))])
            }
        case "hang":
            let why = "it did not answer tools/call within 0.6 seconds"
            await close(why); throw BackendPluginsError(-32000, "the plugin stopped: " + why)
        case "big":
            let raw = args["bytes"].number ?? 0
            let size = raw > Double(launch.maximumMessageBytes) ? launch.maximumMessageBytes + 1 : Int(max(0, raw).rounded(.towardZero))
            if size > launch.maximumMessageBytes {
                let why = "it sent a message larger than \(launch.maximumMessageBytes) bytes"
                await close(why); throw BackendPluginsError(-32000, "the plugin stopped: " + why)
            }
            return .string(String(repeating: "x", count: max(0, size)))
        case "read":
            let path = BackendPluginsFiles.real(args["path"].string ?? ""), folder = BackendPluginsFiles.real(launch.cwd)
            let data = launch.environment["HOME"] ?? ""
            guard path.hasPrefix(folder + "/") || path.hasPrefix(data + "/") else { return .object([.init("error", .string("EPERM"))]) }
            return .object([.init("text", .string(try BackendMemoryFiles.text(path)))])
        default: throw BackendPluginsError(-32601, "unknown fake tool")
        }
    }
}
private final class BackendPluginsParityFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [BackendPluginsParityPeer] = [], plans: [BackendPluginsProcessLaunch] = []
    func make(_ launch: BackendPluginsProcessLaunch, answer: @escaping BackendPluginsProcess.RequestHandler,
              exit: @escaping @Sendable (String) async -> Void) -> any BackendPluginsRunningProcess {
        lock.withLock {
            let silent = (try? BackendMemoryFiles.text(launch.cwd + "/main.js"))?.contains("MODE silent") == true
            let peer = BackendPluginsParityPeer(launch: launch, number: Int32(1000 + peers.count), silent: silent, answer: answer, exit: exit)
            plans.append(launch); peers.append(peer); return peer
        }
    }
    var count: Int { lock.withLock { peers.count } }
    var last: BackendPluginsParityPeer? { lock.withLock { peers.last } }
    var lastPlan: BackendPluginsProcessLaunch? { lock.withLock { plans.last } }
}
private final class BackendPluginsParityAuthority: BackendPluginsCallerAuthority, @unchecked Sendable {
    private let lock = NSLock(); private var ids: [String] = []
    func isLocalHoot(_ context: BackendMCPCallContext) async -> Bool { context.sessionID == "hoot" }
    func authorize(_ context: BackendMCPCallContext, tool: String, arguments: NativeRPCValue, tier: BackendMCPTier) async throws {
        lock.withLock { ids.append(tool) }
    }
    var tools: [String] { lock.withLock { ids } }
}
@MainActor final class BackendPluginsParityTests: XCTestCase {
    private let all = ["tasks.read", "notify", "tools.contribute"]
    private func tool(_ name: String, properties: NativeRPCValue = .object([])) -> NativeRPCValue {
        BackendMemoryParsing.object([("name", .string(name)), ("title", .string("Fake " + name)),
            ("description", .string("The fake plugin's " + name + ".")), ("tier", .string("read")),
            ("inputSchema", BackendMemoryParsing.object([("type", .string("object")), ("properties", properties)]))])
    }
    private func manifest(id: String = "fake", plugin: NativeRPCValue = .object([]), header: NativeRPCValue = .object([])) -> NativeRPCValue {
        let string = BackendMemoryParsing.object([("type", .string("string"))])
        let object = BackendMemoryParsing.object([("type", .string("object")), ("properties", .object([]))])
        let tools = [tool("echo", properties: BackendMemoryParsing.object([("text", string)])), tool("env"),
            tool("ask", properties: BackendMemoryParsing.object([("method", string), ("params", object)])), tool("hang"),
            tool("big", properties: BackendMemoryParsing.object([("bytes", BackendMemoryParsing.object([("type", .string("integer"))]))])),
            tool("read", properties: BackendMemoryParsing.object([("path", string)]))]
        let block = BackendMemoryParsing.object([("main", .string("main.js")), ("runtime", .string("node")),
            ("capabilities", BackendMemoryParsing.strings(["tasks.read", "knowledge.read", "notify", "tools.contribute"])),
            ("tools", .array(tools))]).merging(plugin)
        return BackendMemoryParsing.object([("terminaldeck", .number(1)), ("id", .string(id)), ("name", .string("Fake")),
            ("summary", .string("A plugin that exists for the tests.")), ("version", .string("1.0.0")), ("plugin", block)]).merging(header)
    }
    private func temp(silent: Bool = false) throws -> (root: URL, data: URL, project: String, folder: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-plugins-parity-" + UUID().uuidString)
        let data = root.appendingPathComponent("userData"), folder = data.appendingPathComponent("plugins/fake"), project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(manifest().compact.utf8).write(to: folder.appendingPathComponent("terminaldeck.json"))
        try Data((silent ? "MODE silent" : "MODE normal").utf8).write(to: folder.appendingPathComponent("main.js"))
        return (root, data, BackendPluginsFiles.real(project.path), folder)
    }
    private func make(data: URL, project: String, consent: BackendPluginsParityConsent, factory: BackendPluginsParityFactory,
                      env: [String: String] = [:], request: Int = 30_000, handshake: Int = 8_000, maximum: Int = 256 * 1024,
                      trash: (@Sendable (URL) async throws -> Void)? = nil) -> BackendPluginsHost {
        let row = BackendMemoryParsing.object([("id", .string("t1")), ("title", .string("Write the tests")), ("project", .string(project)),
            ("status", .string("open")), ("updatedAt", .number(1))])
        let desktop = trash.map { value in BackendPluginsDesktop(openFolder: { _ in }, trash: value) }
        return BackendPluginsHost(userData: data, runtime: "/fixture/runtime/bin/node", environment: env, consent: consent,
            services: .init(projects: { [project] }, tasks: { [row] }, notify: { _, _, _ in true }), desktop: desktop,
            now: { 1000 }, processFactory: { factory.make($0, answer: $1, exit: $2) },
            requestTimeoutMilliseconds: request, handshakeTimeoutMilliseconds: handshake, maximumMessageBytes: maximum)
    }
    private func allow(_ host: BackendPluginsHost, _ capabilities: [String], projects: [String] = []) async -> NativeRPCValue {
        await host.allow("fake", input: BackendMemoryParsing.object([("capabilities", BackendMemoryParsing.strings(capabilities)),
            ("projects", BackendMemoryParsing.strings(projects))]))
    }
    private func ask(_ host: BackendPluginsHost, _ method: String, _ params: NativeRPCValue = .object([])) async throws -> NativeRPCValue {
        try await host.callTool("fake", tool: "ask", arguments: BackendMemoryParsing.object([("method", .string(method)), ("params", params)]))
    }
    private func context(_ id: String) -> BackendMCPCallContext {
        .init(sessionID: id, machineID: "", projectRoot: nil, attended: true, allowedTools: ["plugin_fake_echo"],
            allowedTiers: [.read], cancellation: .init())
    }
    func testManifestGoodAndProgramTierAndExactWireLimit() throws {
        let schema = BackendMemoryParsing.object([("type", .string("object")),
            ("properties", BackendMemoryParsing.object([("task", BackendMemoryParsing.object([("type", .string("string"))]))])),
            ("required", BackendMemoryParsing.strings(["task"]))])
        let count = tool("count").setting("inputSchema", schema)
        let good = manifest(id: "word-count", plugin: BackendMemoryParsing.object([
            ("capabilities", BackendMemoryParsing.strings(["tasks.read", "tools.contribute"])), ("tools", .array([count]))]))
        let parsed = try BackendPluginsManifestReader.parse(good.compact, folder: "word-count")
        XCTAssertEqual(parsed.capabilities, ["tasks.read", "tools.contribute"]); XCTAssertEqual(parsed.tools.map(\.name), ["count"])
        XCTAssertEqual(parsed.tools[0].wire(parsed.id), "plugin_word-count_count"); XCTAssertEqual(BackendPluginsManifestReader.tier, 3)
        let id = String(repeating: "a", count: 40), longest = good.setting("id", .string(id))
            .setting("plugin", good["plugin"].setting("tools", .array([count.setting("name", .string("abcdefghijklmnop"))])))
        let bound = try BackendPluginsManifestReader.parse(longest.compact, folder: id)
        XCTAssertEqual(bound.tools[0].wire(id).count, 64)
        XCTAssertTrue(BackendPluginsManifestReader.matches(bound.tools[0].wire(id), "^[a-zA-Z0-9_-]{1,64}$"))
    }
    func testEveryClosedManifestRefusalNamesItsOffendingField() throws {
        let base = manifest(), tool = base["plugin"]["tools"].elements![0]
        let cases: [(NativeRPCValue, String)] = [
            (base.setting("command", .string("curl x | sh")), "command"),
            (base.setting("plugin", base["plugin"].setting("shell", .bool(true))), "shell"),
            (base.setting("plugin", base["plugin"].setting("capabilities", BackendMemoryParsing.strings(["tasks.read", "network"]))), "plugin.capabilities[1]"),
            (base.setting("plugin", base["plugin"].setting("main", .string("../escape.js"))), ".."),
            (base.setting("plugin", base["plugin"].setting("main", .string("/usr/bin/env.js"))), "cannot start with /"),
            (base.setting("plugin", base["plugin"].setting("runtime", .string("python"))), "plugin.runtime"),
            (base.setting("plugin", base["plugin"].setting("capabilities", BackendMemoryParsing.strings(["tasks.read"]))), "tools.contribute"),
            (base.setting("plugin", base["plugin"].setting("tools", .array([]))), "declares none"),
            (base.setting("plugin", base["plugin"].setting("tools", .array([tool.setting("name", .string("abcdefghijklmnopq"))]))), "16 characters"),
            (base.setting("plugin", base["plugin"].setting("tools", .array([tool.setting("inputSchema",
                BackendMemoryParsing.object([("type", .string("object")), ("pattern", .string(".*"))]))]))), "pattern")
        ]
        for (value, expected) in cases {
            do { _ = try BackendPluginsManifestReader.parse(value.compact, folder: "fake"); XCTFail("Accepted invalid manifest") }
            catch { XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription) }
        }
        do { _ = try BackendPluginsManifestReader.parse(base.compact, folder: "other"); XCTFail("Folder mismatch accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("its folder is called other")) }
    }
    func testListedUnallowedPluginStartsNothingAndAsksNobody() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(at: f.root) }
        let consent = BackendPluginsParityConsent(), factory = BackendPluginsParityFactory()
        let host = make(data: f.data, project: f.project, consent: consent, factory: factory)
        await host.startAll(); let state = await host.state(), row = state["plugins"].elements![0]
        XCTAssertEqual(row["state"].string, "needs-ok")
        XCTAssertEqual(row["declared"].elements?.compactMap(\.string), ["tasks.read", "knowledge.read", "notify", "tools.contribute"])
        XCTAssertEqual(row["granted"], .array([]))
        let pid = await host.pidOf("fake"); XCTAssertNil(pid)
        let questions = await consent.questions; XCTAssertTrue(questions.isEmpty); XCTAssertEqual(factory.count, 0)
        let contributors = await host.contributors(); XCTAssertTrue(contributors.isEmpty); await host.stopAll()
    }
    func testConsentNoThenYesFingerprintAndHandshake() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(at: f.root) }
        let consent = BackendPluginsParityConsent(), factory = BackendPluginsParityFactory()
        let host = make(data: f.data, project: f.project, consent: consent, factory: factory)
        await host.scan(); await consent.set(false); let no = await allow(host, all)
        XCTAssertEqual(no["ok"].bool, false); XCTAssertTrue(no["message"].string?.contains("You said no") == true)
        XCTAssertEqual(no["state"]["plugins"].elements?.first?["state"].string, "needs-ok")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.data.appendingPathComponent("plugin-grants.json").path))
        await consent.set(true); let yes = await allow(host, all)
        XCTAssertEqual(yes["ok"].bool, true); XCTAssertEqual(yes["state"]["plugins"].elements?.first?["state"].string, "running")
        XCTAssertEqual(yes["state"]["plugins"].elements?.first?["granted"].elements?.compactMap(\.string), all)
        let questions = await consent.questions; XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(questions[1].capabilities, all); XCTAssertTrue(BackendPluginsManifestReader.matches(questions[1].hash, "^[0-9a-f]{64}$"))
        XCTAssertTrue(questions[1].detail.contains("Give Hoot new tools"))
        let pid = await host.pidOf("fake"); XCTAssertNotNil(pid)
        let peer = try XCTUnwrap(factory.last), alive = await peer.alive; XCTAssertTrue(alive)
        let reply = try await host.callTool("fake", tool: "echo", arguments: .object([.init("text", .string("hello"))]))
        XCTAssertEqual(reply, .object([.init("echoed", .string("hello"))]))
        let methods = await peer.requests; XCTAssertEqual(methods.first, "initialize"); await host.stopAll()
    }
    func testHandshakeFailureStopsAndKeepsExactTimeoutDependency() async throws {
        let f = try temp(silent: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let consent = BackendPluginsParityConsent(), factory = BackendPluginsParityFactory()
        let host = make(data: f.data, project: f.project, consent: consent, factory: factory, handshake: 500)
        await host.scan(); let result = await allow(host, all), row = result["state"]["plugins"].elements![0]
        XCTAssertEqual(row["state"].string, "stopped"); XCTAssertTrue(row["note"].string?.contains("did not answer initialize") == true)
        let pid = await host.pidOf("fake"); XCTAssertNil(pid)
        let timeout = await factory.last?.initializeTimeout; XCTAssertEqual(timeout, 500); await host.stopAll()
    }
    func testDeclaredGrantedAvailableAndUnknownRequestBoundaries() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(at: f.root) }
        let consent = BackendPluginsParityConsent(), factory = BackendPluginsParityFactory()
        let host = make(data: f.data, project: f.project, consent: consent, factory: factory)
        await host.scan(); _ = await allow(host, ["tools.contribute"])
        let undeclared = try await ask(host, "goals.list")
        XCTAssertEqual(undeclared["error"]["code"].number, -32001); XCTAssertTrue(undeclared["error"]["message"].string?.contains("does not ask for") == true)
        let denied = try await ask(host, "tasks.list")
        XCTAssertEqual(denied["error"]["code"].number, -32002); XCTAssertTrue(denied["error"]["message"].string?.contains("has not allowed") == true)
        let notify = try await ask(host, "notify", .object([.init("title", .string("hi"))])); XCTAssertEqual(notify["error"]["code"].number, -32002)
        _ = await allow(host, all)
        let granted = try await ask(host, "tasks.list"), row = granted["result"]["tasks"].elements![0]
        XCTAssertEqual(row["id"].string, "t1"); XCTAssertEqual(row["title"].string, "Write the tests")
        XCTAssertEqual(row["project"].string, f.project); XCTAssertEqual(row["status"].string, "open"); XCTAssertEqual(row["updatedAt"].number, 1)
        let unknown = try await ask(host, "shell.run", .object([.init("command", .string("id"))]))
        XCTAssertEqual(unknown["error"]["code"].number, -32601); await host.stopAll()
    }
    func testProjectGrantsAndMissingKnowledgeAndWidenNarrowWithoutRestart() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(at: f.root) }
        let consent = BackendPluginsParityConsent(), factory = BackendPluginsParityFactory()
        let host = make(data: f.data, project: f.project, consent: consent, factory: factory)
        await host.scan(); _ = await allow(host, ["tools.contribute"])
        let first = await consent.questions; XCTAssertEqual(first.count, 1)
        _ = await allow(host, all); let widened = await consent.questions; XCTAssertEqual(widened.count, 2)
        _ = await allow(host, ["tools.contribute"]); let narrowed = await consent.questions; XCTAssertEqual(narrowed.count, 2)
        let denied = try await ask(host, "tasks.list"); XCTAssertEqual(denied["error"]["code"].number, -32002)
        _ = await allow(host, ["knowledge.read", "tools.contribute"], projects: [f.project])
        let other = try await ask(host, "knowledge.search", .object([.init("project", .string(f.root.appendingPathComponent("other").path)), .init("query", .string("x"))]))
        XCTAssertEqual(other["error"]["code"].number, -32002)
        let unavailable = try await ask(host, "knowledge.search", .object([.init("project", .string(f.project)), .init("query", .string("x"))]))
        XCTAssertEqual(unavailable["error"]["code"].number, -32003); await host.stopAll()
    }
    func testCodeChangeRevokesStopsAndNeedsFreshConsentIncludingRelaunch() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(at: f.root) }
        let consent = BackendPluginsParityConsent(), factory = BackendPluginsParityFactory()
        let host = make(data: f.data, project: f.project, consent: consent, factory: factory)
        await host.scan(); _ = await allow(host, all)
        let peer = try XCTUnwrap(factory.last), pid = await host.pidOf("fake")
        try Data("MODE normal\n// one more line\n".utf8).write(to: f.folder.appendingPathComponent("main.js"))
        let state = await host.state(), row = state["plugins"].elements![0]
        XCTAssertEqual(row["state"].string, "changed"); XCTAssertEqual(row["allowed"].bool, false); XCTAssertEqual(row["granted"], .array([]))
        let alive = await peer.alive; XCTAssertFalse(alive)
        let contributors = await host.contributors(); XCTAssertTrue(contributors.isEmpty)
        do { _ = try await host.callTool("fake", tool: "echo", arguments: .object([.init("text", .string("x"))])); XCTFail("Changed code invoked") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not allowed")) }
        let enable = await host.setEnabled("fake", true); XCTAssertTrue(enable["message"].string?.contains("Allow it first") == true)
        let relaunch = make(data: f.data, project: f.project, consent: consent, factory: factory)
        await relaunch.startAll(); let relaunchedPID = await relaunch.pidOf("fake"); XCTAssertNil(relaunchedPID)
        _ = await allow(host, all); let questions = await consent.questions
        XCTAssertEqual(questions.count, 2); XCTAssertNotEqual(questions[1].hash, questions[0].hash)
        let next = await host.pidOf("fake"); XCTAssertNotEqual(next, pid)
        await relaunch.stopAll(); await host.stopAll()
    }
    func testFinderDotStoreNeverRevokesFingerprint() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(at: f.root) }
        let consent = BackendPluginsParityConsent(), factory = BackendPluginsParityFactory()
        let host = make(data: f.data, project: f.project, consent: consent, factory: factory)
        await host.scan(); _ = await allow(host, all)
        try Data("finder".utf8).write(to: f.folder.appendingPathComponent(".DS_Store"))
        let state = await host.state(); XCTAssertEqual(state["plugins"].elements?.first?["state"].string, "running"); await host.stopAll()
    }
    func testRequestFailureStopsAndNextCallCreatesNewPeer() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(at: f.root) }
        let consent = BackendPluginsParityConsent(), factory = BackendPluginsParityFactory()
        let host = make(data: f.data, project: f.project, consent: consent, factory: factory, request: 600)
        await host.scan(); _ = await allow(host, all); let pid = await host.pidOf("fake")
        do { _ = try await host.callTool("fake", tool: "hang", arguments: .object([])); XCTFail("Timeout succeeded") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not answer tools/call")) }
        let state = await host.state(); XCTAssertEqual(state["plugins"].elements?.first?["state"].string, "stopped")
        XCTAssertTrue(state["plugins"].elements?.first?["note"].string?.contains("did not answer tools/call") == true)
        let reply = try await host.callTool("fake", tool: "echo", arguments: .object([.init("text", .string("back"))]))
        XCTAssertEqual(reply["echoed"].string, "back"); let next = await host.pidOf("fake")
        XCTAssertNotEqual(next, pid); XCTAssertEqual(factory.lastPlan?.requestTimeoutMilliseconds, 600); await host.stopAll()
    }
    func testOversizedPeerContractStopsWithActualConfiguredByteLimit() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(at: f.root) }
        let consent = BackendPluginsParityConsent(), factory = BackendPluginsParityFactory()
        let host = make(data: f.data, project: f.project, consent: consent, factory: factory, maximum: 4096)
        await host.scan(); _ = await allow(host, all)
        do {
            _ = try await host.callTool("fake", tool: "big", arguments: .object([.init("bytes", .number(20_000))]))
            XCTFail("Oversized reply accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("larger than 4096 bytes")) }
        let state = await host.state(); XCTAssertTrue(state["plugins"].elements?.first?["note"].string?.contains("larger than 4096 bytes") == true)
        let pid = await host.pidOf("fake"); XCTAssertNil(pid)
        XCTAssertEqual(factory.lastPlan?.maximumMessageBytes, 4096); await host.stopAll()
    }
    func testEnvironmentHasNoSuppliedSecretsAndMacLaunchUsesOnlyArgv() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(at: f.root) }
        let secrets = ["ANTHROPIC_API_KEY": "test-ant", "OPENAI_API_KEY": "test-openai", "GITHUB_TOKEN": "test-gh",
            "GH_TOKEN": "test-gho", "TERMINALDECK_RELAY_TOKEN": "test-relay", "CLAUDE_CONFIG_DIR": "/fixture/profile",
            "AWS_SECRET_ACCESS_KEY": "test-aws", "NODE_OPTIONS": "--require /fixture/evil.js"]
        let consent = BackendPluginsParityConsent(), factory = BackendPluginsParityFactory()
        let host = make(data: f.data, project: f.project, consent: consent, factory: factory, env: secrets)
        await host.scan(); _ = await allow(host, all)
        let value = try await host.callTool("fake", tool: "env", arguments: .object([])), environment = value["env"]
        for (name, secret) in secrets {
            XCTAssertFalse(environment.has(name)); XCTAssertFalse((environment.fields ?? []).contains { $0.value.string == secret })
        }
        let names = Set((environment.fields ?? []).map(\.key))
        XCTAssertTrue(names.isSubset(of: ["HOME", "TMPDIR", "PATH", "ELECTRON_RUN_AS_NODE", "LANG", "LC_ALL", "LC_CTYPE"]))
        XCTAssertEqual(BackendPluginsFiles.real(value["cwd"].string!), BackendPluginsFiles.real(f.folder.path))
        XCTAssertEqual(environment["HOME"].string, BackendPluginsFiles.real(f.data.appendingPathComponent("plugin-data/fake").path))
        let plan = try XCTUnwrap(factory.lastPlan); XCTAssertEqual(factory.count, 1)
        XCTAssertEqual(plan.command, "/usr/bin/sandbox-exec"); XCTAssertEqual(plan.arguments[0], "-p")
        XCTAssertEqual(Array(plan.arguments.suffix(2)), ["/fixture/runtime/bin/node", BackendPluginsFiles.real(f.folder.path) + "/main.js"])
        await host.stopAll()
    }
    func testOffPersistsRelaunchAndReenableNeedsNoSecondQuestion() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(at: f.root) }
        let consent = BackendPluginsParityConsent(), factory = BackendPluginsParityFactory()
        let host = make(data: f.data, project: f.project, consent: consent, factory: factory)
        await host.scan(); _ = await allow(host, all); let off = await host.setEnabled("fake", false)
        XCTAssertEqual(off["state"]["plugins"].elements?.first?["state"].string, "off")
        do { _ = try await host.callTool("fake", tool: "echo", arguments: .object([.init("text", .string("x"))])); XCTFail("Off plugin invoked") }
        catch { XCTAssertTrue(error.localizedDescription.contains("turned off")) }
        let pid = await host.pidOf("fake"); XCTAssertNil(pid)
        let tools = await host.contributors(); XCTAssertTrue(tools.isEmpty)
        let relaunch = make(data: f.data, project: f.project, consent: consent, factory: factory)
        await relaunch.startAll(); let relaunched = await relaunch.pidOf("fake"); XCTAssertNil(relaunched)
        let on = await host.setEnabled("fake", true)
        XCTAssertEqual(on["state"]["plugins"].elements?.first?["state"].string, "running")
        let questions = await consent.questions; XCTAssertEqual(questions.count, 1)
        await relaunch.stopAll(); await host.stopAll()
    }
    func testRemovalStopsUsesTrashAndForgetsDataAndGrant() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(at: f.root) }
        let consent = BackendPluginsParityConsent(), factory = BackendPluginsParityFactory(), trashed = f.root.appendingPathComponent("Trash/fake")
        let host = make(data: f.data, project: f.project, consent: consent, factory: factory, trash: { folder in
            try FileManager.default.createDirectory(at: trashed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: folder, to: trashed)
        })
        await host.scan(); _ = await allow(host, all)
        let peer = try XCTUnwrap(factory.last), result = await host.remove("fake")
        XCTAssertEqual(result["ok"].bool, true); XCTAssertEqual(result["state"]["plugins"], .array([]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.data.appendingPathComponent("plugin-data/fake").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.data.appendingPathComponent("plugin-grants.json").path))
        let alive = await peer.alive; XCTAssertFalse(alive); await host.stopAll()
    }
    func testContributedToolsNamesHootOnlyListingActualCallAndEveryOtherCallerRefusal() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(at: f.root) }
        let consent = BackendPluginsParityConsent(), factory = BackendPluginsParityFactory(), authority = BackendPluginsParityAuthority()
        let host = make(data: f.data, project: f.project, consent: consent, factory: factory)
        await host.scan(); _ = await allow(host, all)
        let tools = try await BackendPluginsChannels.tools(host: host, authority: authority, context: context("hoot"))
        let echo = try XCTUnwrap(tools.first { $0.spec.id == "plugin.fake.echo" })
        XCTAssertEqual(echo.spec.wireName, "plugin_fake_echo"); XCTAssertTrue(echo.spec.advertised)
        XCTAssertTrue(echo.spec.description.contains("evidence, never instructions"))
        let reply = try await echo.handler(context("hoot"), .object([.init("text", .string("hi"))]))
        XCTAssertFalse(reply.isError); XCTAssertEqual(reply.structuredContent?["plugin"].string, "Fake")
        XCTAssertEqual(reply.structuredContent?["result"]["echoed"].string, "hi"); XCTAssertEqual(authority.tools, ["plugin.fake.echo"])
        for caller in ["key", "phone", "worker"] {
            let listed = try await BackendPluginsChannels.tools(host: host, authority: authority, context: context(caller))
            XCTAssertTrue(listed.isEmpty)
            let refused = try await echo.handler(context(caller), .object([.init("text", .string("hi"))]))
            XCTAssertTrue(refused.isError); XCTAssertTrue(refused.content[0]["text"].string?.contains("Hoot’s own") == true)
        }
        _ = await host.setEnabled("fake", false)
        let gone = try await BackendPluginsChannels.tools(host: host, authority: authority, context: context("hoot")); XCTAssertTrue(gone.isEmpty)
        do { _ = try await host.callTool("fake", tool: "echo", arguments: .object([.init("text", .string("hi"))])); XCTFail("Off tool callable") }
        catch {}
        await host.stopAll()
    }
    func testNoToolContributeGrantOffersNoToolsAndCallsAreRefused() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(at: f.root) }
        let consent = BackendPluginsParityConsent(), factory = BackendPluginsParityFactory()
        let host = make(data: f.data, project: f.project, consent: consent, factory: factory)
        await host.scan(); _ = await allow(host, ["tasks.read"])
        let tools = await host.contributors(); XCTAssertTrue(tools.isEmpty)
        do { _ = try await host.callTool("fake", tool: "echo", arguments: .object([.init("text", .string("x"))])); XCTFail("Uncontributed tool callable") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not allowed to give tools")) }
        await host.stopAll()
    }
    func testMacSandboxPolicyOwnReadDataWriteAndFakePeerDeniesCanary() async throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(at: f.root) }
        let canary = f.root.appendingPathComponent("outside.txt"); try Data("the person’s own file".utf8).write(to: canary)
        let consent = BackendPluginsParityConsent(), factory = BackendPluginsParityFactory()
        let host = make(data: f.data, project: f.project, consent: consent, factory: factory)
        await host.scan(); let result = await allow(host, all)
        XCTAssertEqual(result["state"]["plugins"].elements?.first?["state"].string, "running")
        let profile = try XCTUnwrap(factory.lastPlan?.arguments[1]), folder = BackendPluginsFiles.real(f.folder.path)
        let data = BackendPluginsFiles.real(f.data.appendingPathComponent("plugin-data/fake").path)
        XCTAssertTrue(profile.contains("(allow file-read* (subpath \"" + folder + "\"))"))
        XCTAssertFalse(profile.contains("(allow file-read* (subpath \"/\"))"))
        XCTAssertTrue(profile.contains("(allow file-read* file-write* (subpath \"" + data + "\"))"))
        XCTAssertFalse(profile.contains("(allow file-read* file-write* (subpath \"" + folder + "\"))"))
        XCTAssertTrue(profile.hasSuffix("(deny network*)\n"))
        let outside = try await host.callTool("fake", tool: "read", arguments: .object([.init("path", .string(canary.path))]))
        XCTAssertEqual(outside["error"].string, "EPERM")
        let own = try await host.callTool("fake", tool: "read", arguments: .object([.init("path", .string(f.folder.appendingPathComponent("main.js").path))]))
        XCTAssertTrue(own["text"].string?.contains("MODE") == true); await host.stopAll()
    }
    func testGrantsFileMatchesActualRecordsFencePathsAndDeniesWrites() throws {
        let f = try temp(); defer { try? FileManager.default.removeItem(at: f.root) }
        let actual = BackendMacConfinement.recordsFencePaths(f.data)
        for name in ["routines", "routine-state.json", "copilot-log", "plugin-grants.json"] {
            XCTAssertTrue(actual.contains(BackendPluginsFiles.real(f.data.appendingPathComponent(name).path)))
        }
        let profile = BackendMacConfinement.recordsFenceProfile(f.data)
        let grants = BackendPluginsFiles.real(f.data.appendingPathComponent("plugin-grants.json").path)
        XCTAssertTrue(profile.contains("(deny file-write* (literal \"" + grants + "\"))"))
    }
}
