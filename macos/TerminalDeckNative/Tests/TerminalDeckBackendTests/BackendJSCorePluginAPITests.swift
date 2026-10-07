import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

private struct BackendJSCorePluginAPITestConsent: BackendPluginsConsent {
    func ask(_ question: BackendPluginsConsentRequest) async -> BackendPluginsConsentOutcome { .init(granted: true) }
    func shutdown() async {}
}
private enum BackendJSCorePluginAPITestFixture {
    static var helper: String? { ProcessInfo.processInfo.environment["TD_JSCORE_TEST_HELPER"] }
    static let source = #"""
    const fs = require('fs');
    const next = { id: 1000 }, waiting = new Map(); let buffer = '';
    const send = message => process.stdout.write(JSON.stringify({jsonrpc:'2.0', ...message}) + '\n');
    const ask = (method, params) => new Promise(resolve => { const id=next.id++; waiting.set(id,resolve); send({id,method,params}); });
    async function handle(message) {
      if (message.method === undefined) { const resolve=waiting.get(message.id); waiting.delete(message.id); if(resolve)resolve(message.error?{error:message.error}:{result:message.result}); return; }
      if (message.method === 'shutdown') process.exit(0);
      if (message.method === 'initialize') return send({id:message.id,result:{protocol:1}});
      if (message.method !== 'tools/call') return;
      const {name,arguments:args}=message.params;
      if(name==='echo')return send({id:message.id,result:{echoed:args.text}});
      if(name==='ask')return send({id:message.id,result:await ask(args.method,args.params)});
      if(name==='read'){try{return send({id:message.id,result:{text:fs.readFileSync(args.path,'utf8')}});}catch(error){return send({id:message.id,result:{error:error.code}});}}
      if(name==='decoder'){
        const {StringDecoder}=require('node:string_decoder'), decoder=new StringDecoder('utf8');
        const a=decoder.write(Buffer.from([240,159])), b=decoder.write(Buffer.from([152,128]));
        const EventEmitter=require('node:events'), input=new EventEmitter(), readline=require('node:readline').createInterface({input}), lines=[];
        readline.on('line',line=>lines.push(line)); input.emit('data',Buffer.from([240,159])); input.emit('data',Buffer.from([152,128,10])); input.emit('end');
        return send({id:message.id,result:{a,b,end:decoder.end(),lines}});
      }
    }
    process.stdin.setEncoding('utf8');
    process.stdin.on('data',chunk=>{buffer+=chunk;let newline;while((newline=buffer.indexOf('\n'))!==-1){const line=buffer.slice(0,newline);buffer=buffer.slice(newline+1);if(line.trim()!=='')void handle(JSON.parse(line));}});
    process.stdin.on('end',()=>process.exit(0));
    """#
    static func placed(main: String = source, esm: Bool = false) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendJSCorePluginAPI-" + UUID().uuidString)
        let folder = root.appendingPathComponent("plugins/fake")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = esm ? "main.mjs" : "main.cjs"
        let tools: [NativeRPCValue] = ["echo", "ask", "read", "decoder"].map { name in
            .object([.init("name", .string(name)), .init("title", .string(name)), .init("description", .string("Test " + name)), .init("tier", .string("read")),
                .init("inputSchema", .object([.init("type", .string("object"))]))])
        }
        let manifest = NativeRPCValue.object([.init("terminaldeck", .number(1)), .init("id", .string("fake")), .init("name", .string("Fake")),
            .init("summary", .string("Protocol test")), .init("version", .string("1.0.0")), .init("plugin", .object([.init("main", .string(filename)),
                .init("runtime", .string("node")), .init("capabilities", .array([.string("tasks.read"), .string("tools.contribute")])), .init("tools", .array(tools))]))])
        try manifest.encodedJSON().write(to: folder.appendingPathComponent("terminaldeck.json"))
        let text = esm ? "import fs from 'node:fs';\n" + main.replacingOccurrences(of: "const fs = require('fs');", with: "") : main
        try Data(text.utf8).write(to: folder.appendingPathComponent(filename))
        return (root, folder)
    }
    static func host(_ root: URL) throws -> BackendPluginsHost {
        guard let helper else { throw BackendPluginsError(-32003, "Set TD_JSCORE_TEST_HELPER to the freshly staged native helper for the combined integration gate") }
        return BackendPluginsHost(userData: root, runtime: helper, environment: ["OPENAI_API_KEY": "must-not-inherit"], consent: BackendJSCorePluginAPITestConsent(),
            services: .init(projects: { [] }, tasks: { [.object([.init("id", .string("t1")), .init("title", .string("Write the tests"))])] }))
    }
    static var allow: NativeRPCValue { .object([.init("capabilities", .array([.string("tasks.read"), .string("tools.contribute")])), .init("projects", .array([]))]) }
    static func asked(_ host: BackendPluginsHost, _ method: String) async throws -> NativeRPCValue {
        try await host.callTool("fake", tool: "ask", arguments: .object([.init("method", .string(method)), .init("params", .object([]))]))
    }
}

/// Integration tests are intentionally gated on the newly built helper. A skip
/// is NOT compatibility evidence and must not satisfy native-only packaging.
@Suite("Actual plugin host grants and protocol through native JSCore helper")
struct BackendJSCorePluginAPITests: Sendable {
    @Test(.enabled(if: BackendJSCorePluginAPITestFixture.helper != nil))
    func realCommonJSProtocolPreservesHandshakeHostPermissionChecksAndNextRequestNarrowing() async throws {
        let (root, _) = try BackendJSCorePluginAPITestFixture.placed(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try BackendJSCorePluginAPITestFixture.host(root)
        let allowed = await host.allow("fake", input: BackendJSCorePluginAPITestFixture.allow)
        #expect(allowed["ok"].bool == true); #expect(allowed["state"]["plugins"].elements?.first?["state"].string == "running")
        let echo = try await host.callTool("fake", tool: "echo", arguments: .object([.init("text", .string("hello 😀"))]))
        #expect(echo["echoed"].string == "hello 😀")
        #expect(try await BackendJSCorePluginAPITestFixture.asked(host, "tasks.list")["result"]["tasks"].elements?.first?["id"].string == "t1")
        #expect(try await BackendJSCorePluginAPITestFixture.asked(host, "goals.list")["error"]["code"].number == -32001)
        #expect(try await BackendJSCorePluginAPITestFixture.asked(host, "shell.run")["error"]["code"].number == -32601)
        _ = await host.allow("fake", input: .object([.init("capabilities", .array([.string("tools.contribute")])), .init("projects", .array([]))]))
        #expect(try await BackendJSCorePluginAPITestFixture.asked(host, "tasks.list")["error"]["code"].number == -32002)
        await host.stopAll()
    }
    @Test(.enabled(if: BackendJSCorePluginAPITestFixture.helper != nil))
    func actualHelperKeepsReadConfinementAndIncrementalUnicodeDecoder() async throws {
        let (root, folder) = try BackendJSCorePluginAPITestFixture.placed(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.txt"); try Data("owner-canary".utf8).write(to: outside)
        let host = try BackendJSCorePluginAPITestFixture.host(root); _ = await host.allow("fake", input: BackendJSCorePluginAPITestFixture.allow)
        let refused = try await host.callTool("fake", tool: "read", arguments: .object([.init("path", .string(outside.path))]))
        #expect(refused["error"].string == "EPERM")
        let own = try await host.callTool("fake", tool: "read", arguments: .object([.init("path", .string(folder.appendingPathComponent("main.cjs").path))]))
        #expect(own["text"].string?.contains("process.stdin") == true)
        let decoded = try await host.callTool("fake", tool: "decoder", arguments: .object([]))
        #expect(decoded["a"].string == ""); #expect(decoded["b"].string == "😀"); #expect(decoded["end"].string == "")
        #expect(decoded["lines"].elements == [.string("😀")])
        await host.stopAll()
    }
    @Test(.enabled(if: BackendJSCorePluginAPITestFixture.helper != nil))
    func supportedESMEntryUsesSameUnchangedManifestAndHost() async throws {
        let (root, _) = try BackendJSCorePluginAPITestFixture.placed(esm: true); defer { try? FileManager.default.removeItem(at: root) }
        let host = try BackendJSCorePluginAPITestFixture.host(root)
        let state = await host.allow("fake", input: BackendJSCorePluginAPITestFixture.allow)
        #expect(state["state"]["plugins"].elements?.first?["state"].string == "running")
        #expect(try await host.callTool("fake", tool: "echo", arguments: .object([.init("text", .string("ESM"))]))["echoed"].string == "ESM")
        await host.stopAll()
    }
    @Test(.enabled(if: BackendJSCorePluginAPITestFixture.helper != nil))
    func unsupportedNodeAndMalformedConsoleOutputProduceStoppedRows() async throws {
        for main in ["require('node:child_process');", "console.log('not JSON-RPC');", "for(let i=0;i<1025;i++)__td_timer(()=>{},100000000,false);"] {
            let (root, _) = try BackendJSCorePluginAPITestFixture.placed(main: main)
            let host = try BackendJSCorePluginAPITestFixture.host(root)
            let state = await host.allow("fake", input: BackendJSCorePluginAPITestFixture.allow)
            #expect(state["state"]["plugins"].elements?.first?["state"].string == "stopped")
            #expect(state["state"]["plugins"].elements?.first?["note"].string?.contains("Not running") == true)
            await host.stopAll(); try? FileManager.default.removeItem(at: root)
        }
    }
}
