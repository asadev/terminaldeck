import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// Actual helper integration regressions, written for the one combined gate.
/// TD_JSCORE_TEST_HELPER must name the newly built native helper; no Node fallback.
final class BackendJSCoreTransportTests: XCTestCase {
    private func fixture(script: String, maximum: Int = BackendJSCoreRuntimeLimits.messageBytes) throws -> (URL, BackendPluginsProcess) {
        guard let path = ProcessInfo.processInfo.environment["TD_JSCORE_TEST_HELPER"], path.hasPrefix("/") else {
            throw XCTSkip("The combined gate must supply TD_JSCORE_TEST_HELPER pointing at the built native helper.")
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("BackendJSCoreTransport-" + UUID().uuidString)
        let folder = root.appendingPathComponent("plugin"), data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: folder.appendingPathComponent("main.cjs"))
        let factory = try BackendJSCoreTransportFactory(helperExecutable: URL(fileURLWithPath: path))
        let launch = try factory.launch(folder: folder, data: data, main: "main.cjs", parentEnvironment: ["GH_TOKEN": "synthetic-secret", "LANG": "en_US.UTF-8"])
        let process = BackendPluginsProcess(command: launch.command, arguments: launch.arguments, cwd: launch.cwd, environment: launch.environment,
            maximumBytes: maximum, onRequest: { method, _ in
                guard method == "tasks.list" else { throw BackendPluginsError(-32601, "there is no \(method)") }
                try await Task.sleep(for: .milliseconds(100))
                return .object([.init("tasks", .array([]))])
            }, onExit: { _ in })
        return (root, process)
    }
    private var peer: String {
        #"""
        let buffer = '', next = 1000;
        const pending = new Map();
        function send(m) { process.stdout.write(JSON.stringify(Object.assign({jsonrpc:'2.0'}, m)) + '\n'); }
        function ask(method, params) { return new Promise(resolve => { let id = next++; pending.set(id, resolve); send({id,method,params}); }); }
        async function handle(m) {
            if (!m.method) { const resolve = pending.get(m.id); pending.delete(m.id); if (resolve) resolve(m.error ? {error:m.error} : {result:m.result}); return; }
            if (m.method === 'shutdown') { process.exit(0); return; }
            if (m.method === 'initialize') { send({id:m.id,result:{protocol:1}}); return; }
            if (m.method === 'tools/call') {
                if (m.params.name === 'env') { send({id:m.id,result:{env:process.env,cwd:process.cwd()}}); return; }
                if (m.params.name === 'ask') { send({id:m.id,result:await ask('tasks.list',{})}); return; }
                if (m.params.name === 'burst') { send({id:m.id,result:await Promise.all(Array.from({length:9},()=>ask('tasks.list',{})))}); return; }
                if (m.params.name === 'loop') { while (true) {} }
                if (m.params.name === 'big') { send({id:m.id,result:'x'.repeat(8192)}); return; }
                if (m.params.name === 'garbage') { process.stdout.write('not-json\n'); return; }
                send({id:m.id,result:{echoed:m.params.arguments.text}});
            }
        }
        process.stdin.on('data', chunk => { buffer += chunk.toString('utf8'); let n; while ((n = buffer.indexOf('\n')) >= 0) { const line = buffer.slice(0,n); buffer = buffer.slice(n+1); if (line.trim()) void handle(JSON.parse(line)); } });
        process.stdin.on('end',()=>process.exit(0));
        """#
    }
    private func initialize(_ process: BackendPluginsProcess) async throws -> NativeRPCValue {
        try await process.request("initialize", params: .object([.init("protocol", .number(1))]), timeoutMilliseconds: BackendJSCoreRuntimeLimits.handshakeMilliseconds)
    }
    func testActualHelperHandshakesEchoesHandlesBidirectionalRequestAndCleanEnvironment() async throws {
        let (root, process) = try fixture(script: peer); defer { try? FileManager.default.removeItem(at: root) }
        try await process.start(); let hello = try await initialize(process); XCTAssertEqual(hello["protocol"].number, 1)
        let echo = try await process.request("tools/call", params: .object([.init("name", .string("echo")), .init("arguments", .object([.init("text", .string("hello"))]))]))
        XCTAssertEqual(echo["echoed"].string, "hello")
        let answer = try await process.request("tools/call", params: .object([.init("name", .string("ask")), .init("arguments", .object([]))]))
        XCTAssertEqual(answer["result"]["tasks"].elements?.count, 0)
        let env = try await process.request("tools/call", params: .object([.init("name", .string("env")), .init("arguments", .object([]))]))
        XCTAssertEqual(env["cwd"].string, root.appendingPathComponent("plugin").path); XCTAssertNil(env["env"]["GH_TOKEN"].string)
        XCTAssertEqual(env["env"]["HOME"].string, root.appendingPathComponent("data").path)
        await process.stop()
    }
    func testExistingProcessRefusesNinthIncomingRequest() async throws {
        let (root, process) = try fixture(script: peer); defer { try? FileManager.default.removeItem(at: root) }
        try await process.start(); _ = try await initialize(process)
        let result = try await process.request("tools/call", params: .object([.init("name", .string("burst")), .init("arguments", .object([]))]))
        XCTAssertEqual(result.elements?.filter { $0["error"]["code"].number == -32004 }.count, 1)
        XCTAssertEqual(result.elements?.filter { $0["result"].fields != nil }.count, 8)
        await process.stop()
    }
    func testInfiniteJavaScriptStartupIsKilledOutsideVM() async throws {
        let (root, process) = try fixture(script: "while (true) {}")
        defer { try? FileManager.default.removeItem(at: root) }
        try await process.start()
        do { _ = try await process.request("initialize", params: .object([]), timeoutMilliseconds: 200); XCTFail("An infinite VM must time out") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not answer initialize")) }
        let alive = await process.alive; XCTAssertFalse(alive)
        await process.stop()
    }
    func testInfiniteToolCallIsKilledOutsideVM() async throws {
        let (root, process) = try fixture(script: peer); defer { try? FileManager.default.removeItem(at: root) }
        try await process.start(); _ = try await initialize(process)
        do { _ = try await process.request("tools/call", params: .object([.init("name", .string("loop")), .init("arguments", .object([]))]), timeoutMilliseconds: 200); XCTFail("An infinite callback must time out") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not answer tools/call")) }
        let alive = await process.alive; XCTAssertFalse(alive)
    }
    func testOversizedAndMalformedOutputUseExistingKillReasons() async throws {
        for operation in ["big", "garbage"] {
            let (root, process) = try fixture(script: peer, maximum: 4096)
            try await process.start(); _ = try await initialize(process)
            do { _ = try await process.request("tools/call", params: .object([.init("name", .string(operation)), .init("arguments", .object([]))])); XCTFail("Invalid plugin output must stop it") }
            catch { XCTAssertTrue(error.localizedDescription.contains(operation == "big" ? "larger than 4096 bytes" : "not a message")) }
            let alive = await process.alive; XCTAssertFalse(alive)
            await process.stop(); try? FileManager.default.removeItem(at: root)
        }
    }
    func testIgnoredShutdownIsKilledAfterExistingGrace() async throws {
        let refusing = peer.replacingOccurrences(of: "process.exit(0); return;", with: "while(true) {}")
        let (root, process) = try fixture(script: refusing); defer { try? FileManager.default.removeItem(at: root) }
        try await process.start(); _ = try await initialize(process)
        await process.stop("it was stopped")
        let alive = await process.alive; XCTAssertFalse(alive)
    }
}
