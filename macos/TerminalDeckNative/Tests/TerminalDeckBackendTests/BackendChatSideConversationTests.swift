import XCTest
import Darwin
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendChatSideConversationTests: XCTestCase, @unchecked Sendable {
    // A local protocol fixture. It invokes no provider, reads no account state and spends no turns.
    private let fixture = #"""
import json,sys,os
mode=os.environ.get('TD_SIDE_MODE','')
pidfile=os.environ.get('TD_SIDE_PIDFILE')
if pidfile:
 with open(pidfile,'w') as f: f.write(str(os.getpid()))
def out(v): print(json.dumps(v),flush=True)
for line in sys.stdin:
 r=json.loads(line); m=r.get('method'); p=r.get('params',{})
 trace=os.environ.get('TD_SIDE_TRACE')
 if trace:
  with open(trace,'a') as f: f.write(str(m)+'\n')
 if m=='initialized': continue
 if m=='initialize': out({'id':r['id'],'result':{}})
 elif m=='config/read': out({'id':r['id'],'result':{'config':{'mcp_servers':{'global-server':{'enabled':True}},'apps':{'old-app':{'enabled':True}},'plugins':{'old-plugin':{'enabled':True}}}}})
 elif m=='thread/fork':
  c=p.get('config',{})
  valid=(mode!='fork-error' and p.get('threadId')=='parent' and p.get('ephemeral')==True and p.get('deferGoalContinuation')==True and p.get('sandbox')=='read-only' and p.get('approvalPolicy')=='never' and c.get('mcp_servers',{}).get('global-server',{}).get('enabled')==False and c.get('features',{}).get('apps')==False and c.get('features',{}).get('plugins')==False and c.get('apps',{}).get('_default',{}).get('enabled')==False and c.get('apps',{}).get('old-app',{}).get('enabled')==False and c.get('plugins',{}).get('old-plugin',{}).get('enabled')==False and c.get('sandbox_workspace_write',{}).get('network_access')==False and sys.argv[1:]==['--disable','apps','--disable','plugins'])
  sandbox={'type':'readOnly','networkAccess':False}
  if mode=='unknown-network': sandbox={'type':'readOnly'}
  elif mode=='network-restricted': sandbox={'type':'readOnly','networkAccess':'restricted'}
  elif mode=='network-enabled': sandbox={'type':'readOnly','networkAccess':True}
  elif mode=='ignored-sandbox': sandbox={'type':'workspaceWrite','networkAccess':False}
  elif mode=='external-sandbox': sandbox={'type':'externalSandbox','networkAccess':'restricted'}
  elif mode=='full-sandbox': sandbox={'type':'dangerFullAccess','networkAccess':False}
  elif mode=='missing-type': sandbox={'networkAccess':False}
  result={'thread':{'id':'side'}}
  if mode!='missing-sandbox': result['sandbox']=sandbox
  out({'id':r['id'],'result':result} if valid else {'id':r['id'],'error':{'message':'bad fork request'}})
 elif m=='thread/goal/clear':
  out({'id':r['id'],'result':{'cleared':True}} if p.get('threadId')=='side' and mode!='goal-error' else {'id':r['id'],'error':{'message':'goal not cleared'}})
 elif m=='mcpServerStatus/list':
  data=[] if mode not in ['tools','unknown-tools'] else [{'name':'surprise','tools':{'mutate':{}} if mode=='tools' else {},'runtimeStatus':'connected','toolsError':None if mode=='tools' else 'not verified'}]
  out({'id':r['id'],'result':{'data':data,'nextCursor':None}})
 elif m=='turn/start':
  if mode=='send-error': out({'id':r['id'],'error':{'message':'turn acceptance uncertain'}}); continue
  if p.get('threadId')!='side': out({'id':r['id'],'error':{'message':'parent was mutated'}}); continue
  if p.get('sandboxPolicy')!={'type':'readOnly','networkAccess':False} or p.get('approvalPolicy')!='never': out({'id':r['id'],'error':{'message':'side turn did not request read-only/no network'}}); continue
  out({'id':r['id'],'result':{'turn':{'id':'t'}}})
  out({'method':'turn/started','params':{'threadId':'side','turn':{'id':'t'}}})
  out({'method':'item/completed','params':{'threadId':'parent','turnId':'t','item':{'id':'private','type':'agentMessage','text':'DO NOT LEAK'}}})
  out({'method':'item/completed','params':{'threadId':'side','turnId':'t','item':{'id':'answer','type':'agentMessage','text':'Independent answer'}}})
  out({'method':'turn/completed','params':{'threadId':'side','turn':{'id':'t','status':'completed'}}})
 else: out({'id':r.get('id'),'error':{'message':'unexpected operation'}})
"""#

    func testIndependentEphemeralForkReadsOwnTranscriptAndCloseReapsIt() async throws {
        let side = try await BackendChatSideConversation.open(provider: .codex, conversation: "parent",
            launch: .init(command: "/usr/bin/python3", arguments: ["-u", "-c", fixture], cwd: "/tmp", environment: [:]))
        let opened = await side.read()
        XCTAssertEqual(opened["conversationId"].string, "side")
        XCTAssertEqual(opened["parentConversationId"].string, "parent")
        XCTAssertEqual(opened["alive"].bool, true)
        XCTAssertEqual(opened["effectiveSandbox"]["type"].string, "readOnly")
        XCTAssertEqual(opened["effectiveSandbox"]["networkAccess"].bool, false)
        _ = try await side.send(text: "A separate question")
        var result = await side.read()
        for _ in 0..<100 where result["busy"].bool == true {
            try await Task.sleep(for: .milliseconds(10)); result = await side.read()
        }
        XCTAssertEqual(result["busy"].bool, false)
        let events = try (result["events"].elements ?? []).map(HootChatEvent.init(wire:))
        XCTAssertTrue(events.allSatisfy { $0.conversationID == "side" })
        XCTAssertEqual(events.filter { $0.record.kind == .message }.map { $0.record.value["text"].string }, ["Independent answer"])
        XCTAssertFalse(result.compact.contains("DO NOT LEAK"))
        let closed = await side.close()
        XCTAssertEqual(closed["closed"].bool, true)
        XCTAssertEqual(closed["alive"].bool, false)
        XCTAssertEqual(closed["events"].elements?.count, 0)
        do { _ = try await side.send(text: "after close"); XCTFail("Closed side must reject sends") } catch { }
    }

    func testUnsupportedProviderDoesNotStartAProcess() async throws {
        do {
            _ = try await BackendChatSideConversation.open(provider: .claude, conversation: "parent",
                launch: .init(command: "/this/must/not/run", arguments: [], cwd: "/tmp", environment: [:]))
            XCTFail("Unavailable provider must reject before process launch")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable") }
    }

    func testIsolationUsesExplicitPerNameDisables() throws {
        let effective = try NativeRPCValue.parseJSON(Data(#"{"mcp_servers":{"global":{"url":"https://example.invalid"}},"apps":{"app":{"enabled":true}},"plugins":{"plugin":{"enabled":true}}}"#.utf8))
        let inherited = try NativeRPCValue.parseJSON(Data(#"{"mcp_servers":{"lease":{"url":"https://example.invalid"}},"model_reasoning_effort":"high","sandbox_workspace_write":{"network_access":true}}"#.utf8))
        let config = BackendChatSideConversation.isolatedConfig(effective: effective, inherited: inherited, disabledServers: ["parent-runtime"])
        for name in ["global", "lease", "parent-runtime"] { XCTAssertEqual(config["mcp_servers"][name]["enabled"].bool, false) }
        XCTAssertEqual(config["features"]["apps"].bool, false)
        XCTAssertEqual(config["features"]["plugins"].bool, false)
        XCTAssertEqual(config["apps"]["app"]["enabled"].bool, false)
        XCTAssertEqual(config["plugins"]["plugin"]["enabled"].bool, false)
        XCTAssertEqual(config["model_reasoning_effort"].string, "high")
        XCTAssertEqual(config["sandbox_workspace_write"]["network_access"].bool, false)
    }

    func testFailedForkGoalAndUnverifiableToolsAlwaysReapProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("td-side-failure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for mode in ["fork-error", "goal-error", "tools", "unknown-tools"] {
            let pidfile = directory.appendingPathComponent(mode)
            do {
                _ = try await BackendChatSideConversation.open(provider: .codex, conversation: "parent",
                    launch: .init(command: "/usr/bin/python3", arguments: ["-u", "-c", fixture], cwd: "/tmp",
                                  environment: ["TD_SIDE_MODE": mode, "TD_SIDE_PIDFILE": pidfile.path]))
                XCTFail("The side factory must reject " + mode)
            } catch { }
            let pid = try XCTUnwrap(Int32(String(contentsOf: pidfile, encoding: .utf8)))
            let result = kill(pid, 0), errorNumber = errno
            XCTAssertEqual(result, -1, "A failed side factory leaked its child for " + mode)
            XCTAssertEqual(errorNumber, ESRCH)
        }
    }

    func testUncertainSendFailureClosesAndReapsBeforeReturning() async throws {
        let side = try await BackendChatSideConversation.open(provider: .codex, conversation: "parent",
            launch: .init(command: "/usr/bin/python3", arguments: ["-u", "-c", fixture], cwd: "/tmp", environment: ["TD_SIDE_MODE": "send-error"]))
        do { _ = try await side.send(text: "Question"); XCTFail("Uncertain acceptance must fail") } catch { }
        let result = await side.read()
        XCTAssertEqual(result["closed"].bool, true)
        XCTAssertEqual(result["alive"].bool, false)
        XCTAssertEqual(result["events"].elements?.count, 0)
    }

    func testMissingIgnoredAndUnsafeEffectiveSandboxReapsBeforeAnyQuestion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("td-side-effective-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for mode in ["missing-sandbox", "unknown-network", "network-enabled", "ignored-sandbox", "external-sandbox", "full-sandbox", "missing-type"] {
            let pidfile = directory.appendingPathComponent(mode + ".pid"), trace = directory.appendingPathComponent(mode + ".trace")
            do {
                _ = try await BackendChatSideConversation.open(provider: .codex, conversation: "parent",
                    launch: .init(command: "/usr/bin/python3", arguments: ["-u", "-c", fixture], cwd: "/tmp",
                        environment: ["TD_SIDE_MODE": mode, "TD_SIDE_PIDFILE": pidfile.path, "TD_SIDE_TRACE": trace.path]))
                XCTFail("Unsafe effective side sandbox accepted: " + mode)
            } catch { }
            let pid = try XCTUnwrap(Int32(String(contentsOf: pidfile, encoding: .utf8)))
            let result = kill(pid, 0), errorNumber = errno
            XCTAssertEqual(result, -1, "Unsafe effective sandbox leaked a child: " + mode)
            XCTAssertEqual(errorNumber, ESRCH)
            let methods = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").map(String.init)
            XCTAssertTrue(methods.contains("thread/fork"))
            XCTAssertFalse(methods.contains("thread/goal/clear"))
            XCTAssertFalse(methods.contains("turn/start"))
        }
    }

    func testExplicitProviderRestrictedNetworkReceiptIsAccepted() async throws {
        let side = try await BackendChatSideConversation.open(provider: .codex, conversation: "parent",
            launch: .init(command: "/usr/bin/python3", arguments: ["-u", "-c", fixture], cwd: "/tmp", environment: ["TD_SIDE_MODE": "network-restricted"]))
        let opened = await side.read()
        XCTAssertEqual(opened["effectiveSandbox"]["type"].string, "readOnly")
        XCTAssertEqual(opened["effectiveSandbox"]["networkAccess"].string, "restricted")
        let closed = await side.close()
        XCTAssertEqual(closed["alive"].bool, false)
    }
}
