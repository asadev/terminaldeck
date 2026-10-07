import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class BackendPluginsTests: XCTestCase {
    private func manifest(_ plugin: NativeRPCValue = .object([]), header: NativeRPCValue = .object([])) -> NativeRPCValue {
        .object([.init("terminaldeck", .number(1)), .init("id", .string("word-count")), .init("name", .string("Word count")), .init("summary", .string("Counts words.")), .init("version", .string("1.0.0")), .init("plugin", NativeRPCValue.object([.init("main", .string("index.js")), .init("runtime", .string("node")), .init("capabilities", .array([.string("tasks.read"), .string("tools.contribute")])), .init("tools", .array([.object([.init("name", .string("count")), .init("title", .string("Count words")), .init("description", .string("Counts task words.")), .init("tier", .string("read")), .init("inputSchema", .object([.init("type", .string("object")), .init("properties", .object([]))]))])]))]).merging(plugin))]).merging(header)
    }
    func testManifestClosedVocabularyAndLimits() throws {
        let parsed = try BackendPluginsManifestReader.parse(manifest().compact, folder: "word-count")
        XCTAssertEqual(parsed.tools[0].wire(parsed.id), "plugin_word-count_count")
        for raw in [manifest(header: .object([.init("command", .string("bad"))])), manifest(.object([.init("runtime", .string("python"))])), manifest(.object([.init("main", .string("../escape.js"))])), manifest(.object([.init("capabilities", .array([.string("network")]))])), manifest(.object([.init("tools", .array([]))]))] {
            XCTAssertThrowsError(try BackendPluginsManifestReader.parse(raw.compact, folder: "word-count"))
        }
        XCTAssertThrowsError(try BackendPluginsManifestReader.parse(manifest().compact, folder: "other"))
        let tool = manifest()["plugin"]["tools"].elements![0]
        let badSchema = tool.setting("inputSchema", .object([.init("type", .string("object")), .init("pattern", .string(".*"))]))
        XCTAssertThrowsError(try BackendPluginsManifestReader.parse(manifest(.object([.init("tools", .array([badSchema]))])).compact, folder: "word-count"))
        XCTAssertThrowsError(try BackendPluginsManifestReader.parse(String(repeating: "x", count: 65_537), folder: "word-count"))
    }
    func testFolderHashGrantInvalidationAndFinderException() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let code = dir.appendingPathComponent("main.js"); try Data("one".utf8).write(to: code)
        let first = try BackendPluginsFiles.hash(dir)
        try Data("finder".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(try BackendPluginsFiles.hash(dir).hash, first.hash)
        try Data("two".utf8).write(to: code)
        XCTAssertNotEqual(try BackendPluginsFiles.hash(dir).hash, first.hash)
        XCTAssertThrowsError(try BackendPluginsFiles.hash(dir, limits: .init(maxFiles: 0)))
        XCTAssertThrowsError(try BackendPluginsFiles.hash(dir, limits: .init(maxBytes: 2)))
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("link").path, withDestinationPath: code.path)
        XCTAssertThrowsError(try BackendPluginsFiles.hash(dir))
    }
    func testGrantFileDefaultsDenyAndKeepsFingerprint() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: dir) }
        let store = BackendPluginsGrants(userData: dir), hash = String(repeating: "a", count: 64)
        XCTAssertEqual(store.record("one")["enabled"], .bool(false))
        let grant = NativeRPCValue.object([.init("hash", .string(hash)), .init("capabilities", .array([.string("tasks.read")])), .init("projects", .array([])), .init("grantedAt", .number(1))])
        try store.grant("one", grant, enabled: true)
        XCTAssertNotNil(BackendPluginsGrants(userData: dir).valid("one", hash: hash))
        XCTAssertNil(store.valid("one", hash: String(repeating: "b", count: 64)))
        try store.forget("one"); XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("plugin-grants.json").path))
    }
    func testComposedEnvironmentAndMacSandbox() {
        let env = BackendPluginsSandbox.environment(home: "/plugin-data/one", parent: ["GITHUB_TOKEN": "secret", "NODE_OPTIONS": "bad", "LANG": "en_US.UTF-8", "LC_ALL": "bad/value"])
        XCTAssertNil(env["GITHUB_TOKEN"]); XCTAssertNil(env["NODE_OPTIONS"]); XCTAssertNil(env["LC_ALL"])
        XCTAssertEqual(env["LANG"], "en_US.UTF-8"); XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        let launch = BackendPluginsSandbox.command(runtime: "/runtime/bin/node", main: "/plugin/main.js", folder: "/plugin", data: "/plugin-data/one")
        XCTAssertEqual(launch.0, "/usr/bin/sandbox-exec")
        XCTAssertTrue(launch.1[1].hasSuffix("(deny network*)\n"))
        XCTAssertFalse(launch.1[1].contains("(allow file-read* file-write* (subpath \"/plugin\"))"))
    }
    func testNoConsentNoGrantAndChangedWhileDecidingRefuses() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), folder = dir.appendingPathComponent("plugins/word-count")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        try Data(manifest().compact.utf8).write(to: folder.appendingPathComponent("terminaldeck.json"))
        let code = folder.appendingPathComponent("index.js"); try Data("one".utf8).write(to: code)
        let declined = BackendPluginsHost(userData: dir, runtime: nil, environment: [:], consent: BackendPluginsFixtureConsent(granted: false), services: .init(projects: { [] }))
        let input = NativeRPCValue.object([.init("capabilities", .array([.string("tasks.read")])), .init("projects", .array([]))])
        let no = await declined.allow("word-count", input: input); XCTAssertEqual(no["ok"], .bool(false)); XCTAssertTrue(no["message"].string!.contains("You said no"))
        let edited = BackendPluginsHost(userData: dir, runtime: nil, environment: [:], consent: BackendPluginsFixtureConsent(granted: true, edit: code), services: .init(projects: { [] }))
        let changed = await edited.allow("word-count", input: input)
        XCTAssertEqual(changed["ok"], .bool(false)); XCTAssertTrue(changed["message"].string!.contains("files changed while you were deciding"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("plugin-grants.json").path))
    }
    func testSettingsRejectsOtherCallers() async throws {
        let host = BackendPluginsHost(userData: URL(fileURLWithPath: "/nonexistent-test-only"), runtime: nil, environment: [:], consent: BackendPluginsFixtureConsent(granted: false), services: .init(projects: { [] }))
        let registry = NativeChannelRegistry(); try await BackendPluginsChannels.register(registry: registry, ownerID: "owner", host: host)
        do { _ = try await registry.invoke("plugins:state", context: .init(caller: .pairedDevice, ownerID: "device", capabilities: ["plugins.write"]), arguments: []); XCTFail("Device reached owner settings") }
        catch { XCTAssertTrue(error.localizedDescription.contains("only the app’s own window")) }
    }
    func testProcessLineProtocolAndOutboundLimit() async throws {
        let process = BackendPluginsProcess(command: "/bin/sh", arguments: ["-c", #"read line; printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocol":1}}'; cat >/dev/null"#], cwd: "/private/tmp", environment: ["PATH": "/usr/bin:/bin"], timeoutMilliseconds: 1000, maximumBytes: 256, onRequest: { _, _ in .null }, onExit: { _ in })
        try await process.start()
        let initialized = try await process.request("initialize", params: .object([])); XCTAssertEqual(initialized["protocol"], .number(1))
        do { _ = try await process.request("tools/call", params: .string(String(repeating: "x", count: 300))); XCTFail("Oversized message accepted") }
        catch { XCTAssertEqual((error as? BackendPluginsError)?.code, -32005) }
        await process.stop()
    }
    func testFinalPipeReplyAndHugeUntrustedNumbersDoNotTrap() async throws {
        let script = #"read line; printf '%s\n' '{"jsonrpc":"2.0","id":9223372036854775808,"result":null}' '{"jsonrpc":"2.0","id":1,"error":{"code":1e100,"message":"refused"}}'"#
        let process = BackendPluginsProcess(command: "/bin/sh", arguments: ["-c", script], cwd: "/private/tmp", environment: ["PATH": "/usr/bin:/bin"], onRequest: { _, _ in .null }, onExit: { _ in })
        try await process.start()
        do { _ = try await process.request("initialize", params: .object([])); XCTFail("Error reply accepted") }
        catch { XCTAssertEqual((error as? BackendPluginsError)?.code, -32000); XCTAssertEqual(error.localizedDescription, "refused") }
        await process.stop()
    }
    func testFolderHashUsesJavaScriptUTF16Order() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let names = ["\u{E000}", "\u{10000}"]
        for name in names { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        let digest = BackendPluginsFiles.digest(Data("x".utf8))
        let expected = names.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }.map { $0 + "\0" + "1\0" + digest + "\n" }.joined()
        XCTAssertEqual(try BackendPluginsFiles.hash(dir).hash, BackendPluginsFiles.digest(Data(expected.utf8)))
    }
    func testContributedToolRefusesNonHootAndMissingRuntimeIsVisible() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), folder = dir.appendingPathComponent("plugins/word-count")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        try Data(manifest().compact.utf8).write(to: folder.appendingPathComponent("terminaldeck.json")); try Data("fixture".utf8).write(to: folder.appendingPathComponent("index.js"))
        let host = BackendPluginsHost(userData: dir, runtime: nil, environment: [:], consent: BackendPluginsFixtureConsent(granted: true), services: .init(projects: { [] }))
        let outcome = await host.allow("word-count", input: .object([.init("capabilities", .array([.string("tools.contribute")])), .init("projects", .array([]))]))
        let row = outcome["state"]["plugins"].elements![0]
        XCTAssertEqual(row["state"], .string("stopped")); XCTAssertTrue(row["note"].string!.contains("Node runtime is unavailable"))
        let registrations = try await BackendPluginsChannels.tools(host: host, authority: BackendPluginsFixtureAuthority())
        XCTAssertEqual(registrations[0].spec.id, "plugin.word-count.count")
        let context = BackendMCPCallContext(sessionID: "worker", machineID: "", projectRoot: nil, attended: true, allowedTools: ["plugin_word-count_count"], allowedTiers: [.read], cancellation: .init())
        let refused = try await registrations[0].handler(context, .object([]))
        XCTAssertTrue(refused.isError); XCTAssertTrue(refused.content[0]["text"].string!.contains("Hoot’s own"))
    }
}

private struct BackendPluginsFixtureConsent: BackendPluginsConsent {
    let granted: Bool
    var edit: URL? = nil
    func ask(_ question: BackendPluginsConsentRequest) async -> BackendPluginsConsentOutcome {
        if let edit { try? Data("changed".utf8).write(to: edit) }; return .init(granted: granted, at: 1)
    }
    func shutdown() async {}
}
private struct BackendPluginsFixtureAuthority: BackendPluginsCallerAuthority {
    func isLocalHoot(_ context: BackendMCPCallContext) async -> Bool { false }
    func authorize(_ context: BackendMCPCallContext, tool: String, arguments: NativeRPCValue, tier: BackendMCPTier) async throws { throw NativeRPCError(code: "not-granted", message: "Fixture refuses.") }
}
