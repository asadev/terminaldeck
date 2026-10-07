import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

private actor BackendJSCoreTransportTestConsent: BackendPluginsConsent {
    private var questions = 0
    func ask(_ question: BackendPluginsConsentRequest) async -> BackendPluginsConsentOutcome { questions += 1; return .init(granted: true) }
    func shutdown() async {}
    func count() -> Int { questions }
}
/// Reuses the existing real plugin host, grant file and private request gate.
/// Only the human consent answer and task data are fixtures.
final class BackendJSCoreTransportHostTests: XCTestCase {
    private func fixture() throws -> (URL, URL, BackendPluginsHost, BackendJSCoreTransportTestConsent) {
        guard let helper = ProcessInfo.processInfo.environment["TD_JSCORE_TEST_HELPER"], helper.hasPrefix("/") else {
            throw XCTSkip("The combined gate must supply the built native JavaScriptCore helper.")
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("BackendJSCoreHost-" + UUID().uuidString)
        let folder = root.appendingPathComponent("plugins/fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: NativeRPCValue = .object([.init("terminaldeck", .number(1)), .init("id", .string("fixture")), .init("name", .string("Fixture")),
            .init("summary", .string("Synthetic helper integration plugin")), .init("version", .string("1.0.0")),
            .init("plugin", .object([.init("runtime", .string("node")), .init("main", .string("main.cjs")),
                .init("capabilities", .array([.string("tasks.read"), .string("tools.contribute")])),
                .init("tools", .array([.object([.init("name", .string("ask")), .init("title", .string("Ask")), .init("description", .string("Ask through stdio")),
                    .init("tier", .string("read")), .init("inputSchema", .object([.init("type", .string("object"))]))])]))]))])
        try manifest.encodedJSON().write(to: folder.appendingPathComponent("terminaldeck.json"))
        let script = #"""
        let buffer = '', next = 1000; const waiting = new Map();
        const send = m => process.stdout.write(JSON.stringify(Object.assign({jsonrpc:'2.0'},m))+'\n');
        const ask = (method,params) => new Promise(resolve=>{let id=next++;waiting.set(id,resolve);send({id,method,params});});
        async function handle(m) {
            if (!m.method) { const resolve=waiting.get(m.id);waiting.delete(m.id);if(resolve)resolve(m.error?{error:m.error}:{result:m.result});return; }
            if(m.method==='shutdown'){process.exit(0);return;}
            if(m.method==='initialize'){send({id:m.id,result:{protocol:1}});return;}
            if(m.method==='tools/call'){send({id:m.id,result:await ask(m.params.arguments.method,{})});}
        }
        process.stdin.on('data',chunk=>{buffer+=chunk.toString('utf8');let n;while((n=buffer.indexOf('\n'))!==-1){const line=buffer.slice(0,n);buffer=buffer.slice(n+1);if(line.trim())void handle(JSON.parse(line));}});
        process.stdin.on('end',()=>process.exit(0));
        """#
        try Data(script.utf8).write(to: folder.appendingPathComponent("main.cjs"))
        let consent = BackendJSCoreTransportTestConsent()
        let runtime = try BackendJSCoreTransportFactory(helperExecutable: URL(fileURLWithPath: helper)).runtimePath()
        let host = BackendPluginsHost(userData: root, runtime: runtime, environment: ["GH_TOKEN": "synthetic-secret"], consent: consent,
            services: .init(projects: { [] }, tasks: { [.object([.init("id", .string("t1")), .init("title", .string("A fixture task"))])] }))
        return (root, folder, host, consent)
    }
    private func allow(_ host: BackendPluginsHost, capabilities: [String]) async -> NativeRPCValue {
        await host.allow("fixture", input: .object([.init("capabilities", .array(capabilities.map(NativeRPCValue.string))), .init("projects", .array([]))]))
    }
    private func ask(_ host: BackendPluginsHost, method: String) async throws -> NativeRPCValue {
        try await host.callTool("fixture", tool: "ask", arguments: .object([.init("method", .string(method))]))
    }
    func testExistingHostOwnsStartConsentAndCapabilityRequest() async throws {
        let (root, _, host, consent) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await host.startAll()
        let initial = await host.state(); XCTAssertEqual(initial["plugins"].elements?.first?["state"].string, "needs-ok")
        let before = await consent.count(); XCTAssertEqual(before, 0)
        let allowed = await allow(host, capabilities: ["tasks.read", "tools.contribute"])
        XCTAssertEqual(allowed["ok"].bool, true); XCTAssertEqual(allowed["state"]["plugins"].elements?.first?["state"].string, "running")
        let result = try await ask(host, method: "tasks.list")
        XCTAssertEqual(result["result"]["tasks"].elements?.first?["id"].string, "t1")
        let count = await consent.count(); XCTAssertEqual(count, 1)
        await host.stopAll()
    }
    func testPrivateHostRefusesUndeclaredUngrantedAndUnknownMethods() async throws {
        let (root, _, host, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await host.scan(); _ = await allow(host, capabilities: ["tools.contribute"])
        let ungranted = try await ask(host, method: "tasks.list"), undeclared = try await ask(host, method: "goals.list"), unknown = try await ask(host, method: "shell.run")
        XCTAssertEqual(ungranted["error"]["code"].number, -32002); XCTAssertEqual(undeclared["error"]["code"].number, -32001); XCTAssertEqual(unknown["error"]["code"].number, -32601)
        await host.stopAll()
    }
    func testChangedCodeRevokesGrantAndOffNeverStarts() async throws {
        let (root, folder, host, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await host.scan(); _ = await allow(host, capabilities: ["tasks.read", "tools.contribute"])
        let file = folder.appendingPathComponent("main.cjs")
        var bytes = try Data(contentsOf: file); bytes.append(Data("\n// different bytes\n".utf8)); try bytes.write(to: file)
        let changed = await host.state(); XCTAssertEqual(changed["plugins"].elements?.first?["state"].string, "changed")
        do { _ = try await ask(host, method: "tasks.list"); XCTFail("Changed code must not retain its grant") }
        catch { XCTAssertTrue(error.localizedDescription.contains("not allowed")) }
        let off = await host.setEnabled("fixture", false)
        XCTAssertEqual(off["state"]["plugins"].elements?.first?["state"].string, "changed")
        let contributors = await host.contributors(); XCTAssertTrue(contributors.isEmpty)
        await host.stopAll()
    }
}
