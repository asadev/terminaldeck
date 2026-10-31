import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ChatOwnedTerminalsTests: XCTestCase, @unchecked Sendable {
    private let fake = #"""
import json,sys,os,time,base64
pidfile=os.environ.get('TD_OWNED_PID')
if pidfile:
 with open(pidfile,'a') as f: f.write(str(os.getpid())+'\n')
trace=os.environ.get('TD_OWNED_TRACE')
mode=os.environ.get('TD_OWNED_MODE','')
def out(x): print(json.dumps(x),flush=True)
def log(x):
 if trace:
  with open(trace,'a') as f: f.write(json.dumps(x)+'\n')
proc=None; execution=None
for line in sys.stdin:
 r=json.loads(line); log(r); m=r.get('method'); p=r.get('params',{})
 if m=='initialize':
  if mode=='hold-init':
   while not os.path.exists(os.environ['TD_OWNED_RELEASE']): time.sleep(.01)
  out({'id':r['id'],'result':{}})
 elif m=='initialized': pass
 elif m=='command/exec':
  proc=p.get('processId'); execution=r['id']
  policy=p.get('sandboxPolicy',{})
  valid=(bool(proc) and p.get('cwd')==os.environ.get('TD_EXPECT_CWD') and p.get('tty')==True and p.get('streamStdin')==True and p.get('streamStdoutStderr')==True and policy.get('type')=='workspaceWrite' and policy.get('networkAccess')==False and policy.get('excludeSlashTmp')==True and policy.get('excludeTmpdirEnvVar')==True and p.get('outputBytesCap')==262144 and p.get('command')==['/bin/zsh','-f','-i'])
  if not valid: out({'id':execution,'error':{'message':'invalid owned terminal scope'}}); continue
  out({'method':'command/exec/outputDelta','params':{'processId':'foreign','deltaBase64':base64.b64encode(b'DO NOT LEAK').decode(),'stream':'stdout','capReached':False}})
  if mode!='silent':
   data=b'x'*300000 if mode=='large' else b'own prompt> '
   out({'method':'command/exec/outputDelta','params':{'processId':proc,'deltaBase64':base64.b64encode(data).decode(),'stream':'stdout','capReached':mode=='large'}})
 elif m=='command/exec/write':
  if p.get('processId')!=proc: out({'id':r['id'],'error':{'message':'foreign ID'}}); continue
  data=base64.b64decode(p.get('deltaBase64') or '')
  out({'method':'command/exec/outputDelta','params':{'processId':proc,'deltaBase64':base64.b64encode(data).decode(),'stream':'stdout','capReached':False}})
  out({'id':r['id'],'result':{}})
 elif m=='command/exec/resize': out({'id':r['id'],'result':{}})
 elif m=='command/exec/terminate':
  out({'id':r['id'],'result':{}})
  if execution: out({'id':execution,'result':{'exitCode':0,'stdout':'','stderr':''}})
 else: out({'id':r.get('id'),'error':{'message':'no model or thread operation permitted'}})
log({'eof':True})
"""#
    private struct Fixture: Sendable {
        let scope: BackendChatOwnedTerminals.Scope, root: URL, pidfile: URL, trace: URL
    }
    private func fixture(mode: String = "", generation: UUID = UUID()) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-owned-terminal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let pidfile = root.appendingPathComponent("pids"), trace = root.appendingPathComponent("trace")
        let launch = BackendHootChatLaunch(command: "/usr/bin/python3", arguments: ["-u", "-c", fake], cwd: root.path,
            environment: ["TD_OWNED_PID": pidfile.path, "TD_OWNED_TRACE": trace.path, "TD_OWNED_MODE": mode,
                "TD_EXPECT_CWD": root.path, "TD_OWNED_RELEASE": root.appendingPathComponent("release").path])
        let response = NativeRPCValue.object([.init("thread", .object([.init("id", .string("own-thread"))])),
            .init("cwd", .string(root.path)), .init("approvalPolicy", .string("on-request")),
            .init("activePermissionProfile", .object([.init("id", .string(":workspace")), .init("extends", .null)])),
            .init("sandbox", .object([.init("type", .string("workspaceWrite")), .init("networkAccess", .bool(true)),
                .init("writableRoots", .array([.string(root.path)])), .init("excludeSlashTmp", .bool(false)), .init("excludeTmpdirEnvVar", .bool(false))]))])
        let receipt = try XCTUnwrap(BackendChatProviderPolicy.resolvedSession(response, provider: .codex, conversation: "own-thread", source: "thread/start"))
        let evidence = try XCTUnwrap(BackendChatOwnedTerminals.executionEvidence(response, conversation: "own-thread", source: "thread/start"))
        let scope = BackendChatOwnedTerminals.Scope(sessionID: "own-app", conversation: "own-thread", generation: generation,
            cwd: root.path, launch: launch, effectivePolicy: receipt, executionEvidence: evidence)
        return .init(scope: scope, root: root, pidfile: pidfile, trace: trace)
    }
    private func owner(_ fixture: Fixture) throws -> BackendChatOwnedTerminals {
        let owner = try BackendChatOwnedTerminals(scope: fixture.scope)
        addTeardownBlock { _ = await owner.closeAll(reason: "Test cleanup") }
        return owner
    }
    private func approved(_ owner: BackendChatOwnedTerminals, scope: BackendChatOwnedTerminals.Scope, operation: String,
                          arguments: NativeRPCValue = .object([])) async throws -> NativeRPCValue {
        let approval = try BackendChatOwnedTerminals.AppApproval.mint(sessionID: scope.sessionID, scopeID: scope.scopeID,
            operation: operation, arguments: arguments, origin: .nativeUser)
        return try await owner.invoke(operation: operation, arguments: arguments, approval: approval)
    }
    private func read(_ owner: BackendChatOwnedTerminals, handle: String) async throws -> NativeRPCValue {
        try await owner.invoke(operation: "read", arguments: .object([.init("handle", .string(handle))]))
    }
    private func wait(_ predicate: () async throws -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < end { if try await predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw NativeRPCError(code: "test-timeout", message: "Owned terminal fixture did not settle")
    }
    private func pid(_ file: URL) throws -> Int32 {
        try XCTUnwrap(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").last.flatMap { Int32($0) })
    }
    func testApprovedPrivateTerminalSupportsIOWithoutAnyModelOrThreadTurn() async throws {
        let f = try fixture(), terminal = try owner(f)
        let created = try await approved(terminal, scope: f.scope, operation: "create")
        let handle = try XCTUnwrap(created["handle"].string)
        try await wait { try await self.read(terminal, handle: handle)["state"].string == "running" }
        let write = NativeRPCValue.object([.init("handle", .string(handle)), .init("text", .string("hello\n"))])
        let written = try await approved(terminal, scope: f.scope, operation: "write", arguments: write)
        XCTAssertEqual(written["inputAcknowledged"].bool, true)
        XCTAssertEqual(written["inputProcessed"].bool, false)
        _ = try await approved(terminal, scope: f.scope, operation: "resize", arguments: .object([.init("handle", .string(handle)), .init("cols", .number(80)), .init("rows", .number(24))]))
        let output = try await read(terminal, handle: handle)
        XCTAssertEqual(output["handle"].string, handle)
        XCTAssertTrue(output["output"].string?.contains("hello") == true)
        XCTAssertFalse(output["output"].string?.contains("DO NOT LEAK") == true)
        XCTAssertEqual(output["providerNativeApproval"].bool, false)
        XCTAssertTrue(output["processId"].isNullish)
        let listed = try await terminal.invoke(operation: "list", arguments: .object([]))
        XCTAssertEqual(listed["terminals"].elements?.count, 1)
        XCTAssertTrue(listed["terminals"].elements?.first?["output"].isNullish == true, "Inventory must not copy terminal output buffers")
        let stopped = try await approved(terminal, scope: f.scope, operation: "stop", arguments: .object([.init("handle", .string(handle))]))
        XCTAssertEqual(stopped["connectionAlive"].bool, false)
        let privatePID = try pid(f.pidfile)
        XCTAssertEqual(kill(privatePID, 0), -1)
        let records = try String(contentsOf: f.trace, encoding: .utf8).split(separator: "\n").map { try NativeRPCValue.parseJSON(Data($0.utf8)) }
        let methods = records.compactMap { $0["method"].string }
        XCTAssertTrue(methods.contains("initialize")); XCTAssertTrue(methods.contains("command/exec")); XCTAssertTrue(methods.contains("command/exec/write")); XCTAssertTrue(methods.contains("command/exec/terminate"))
        XCTAssertFalse(methods.contains(where: { $0.hasPrefix("thread/") || $0.hasPrefix("turn/") }))
    }
    func testSilentExecStaysStartingUntilProviderAcknowledgesInput() async throws {
        let f = try fixture(mode: "silent"), terminal = try owner(f)
        let created = try await approved(terminal, scope: f.scope, operation: "create")
        let handle = try XCTUnwrap(created["handle"].string)
        XCTAssertEqual(created["state"].string, "starting")
        let eof = NativeRPCValue.object([.init("handle", .string(handle)), .init("closeStdin", .bool(true))])
        let accepted = try await approved(terminal, scope: f.scope, operation: "write", arguments: eof)
        XCTAssertEqual(accepted["state"].string, "running")
        XCTAssertEqual(accepted["inputAcknowledged"].bool, true)
    }
    func testMissingReplayChangedArgumentsSessionAndExpiredPermitsAreDenied() async throws {
        let f = try fixture(), terminal = try owner(f)
        let args = NativeRPCValue.object([])
        do { _ = try await terminal.invoke(operation: "create", arguments: args); XCTFail("Missing permit accepted") } catch {}
        let permit = try BackendChatOwnedTerminals.AppApproval.mint(sessionID: f.scope.sessionID, scopeID: f.scope.scopeID, operation: "create", arguments: args, origin: .toolConsent)
        _ = try await terminal.invoke(operation: "create", arguments: args, approval: permit)
        do { _ = try await terminal.invoke(operation: "create", arguments: args, approval: permit); XCTFail("Replayed permit accepted") } catch {}
        let wrongArgs = try BackendChatOwnedTerminals.AppApproval.mint(sessionID: f.scope.sessionID, scopeID: f.scope.scopeID, operation: "create", arguments: args, origin: .nativeUser)
        do { _ = try await terminal.invoke(operation: "create", arguments: .object([.init("title", .string("changed"))]), approval: wrongArgs); XCTFail("Changed arguments accepted") } catch {}
        let wrongSession = try BackendChatOwnedTerminals.AppApproval.mint(sessionID: "foreign", scopeID: f.scope.scopeID, operation: "create", arguments: args, origin: .nativeUser)
        do { _ = try await terminal.invoke(operation: "create", arguments: args, approval: wrongSession); XCTFail("Foreign session accepted") } catch {}
        let expired = try BackendChatOwnedTerminals.AppApproval.mint(sessionID: f.scope.sessionID, scopeID: f.scope.scopeID, operation: "create", arguments: args, origin: .nativeUser, now: 0)
        do { _ = try await terminal.invoke(operation: "create", arguments: args, approval: expired); XCTFail("Expired permit accepted") } catch {}
        let inventory = try await terminal.invoke(operation: "list", arguments: args)
        XCTAssertEqual(inventory["terminals"].elements?.count, 1)
    }
    func testPermitCannotCrossProviderGenerationOrHelperPolicyRevision() async throws {
        let f = try fixture(), terminal = try owner(f)
        let changed = BackendChatOwnedTerminals.Scope(sessionID: f.scope.sessionID, conversation: f.scope.conversation, generation: UUID(), cwd: f.scope.cwd,
            launch: f.scope.launch, effectivePolicy: f.scope.effectivePolicy, executionEvidence: f.scope.executionEvidence)
        let permit = try BackendChatOwnedTerminals.AppApproval.mint(sessionID: f.scope.sessionID, scopeID: changed.scopeID, operation: "create", arguments: .object([]), origin: .nativeUser)
        do { _ = try await terminal.invoke(operation: "create", arguments: .object([]), approval: permit); XCTFail("Stale generation permit accepted") } catch {}
        let revised = BackendChatOwnedTerminals.Scope(sessionID: f.scope.sessionID, conversation: f.scope.conversation, generation: f.scope.generation, cwd: f.scope.cwd,
            launch: f.scope.launch, effectivePolicy: f.scope.effectivePolicy, executionEvidence: f.scope.executionEvidence.setting("helperScopeRevision", .string(UUID().uuidString)))
        XCTAssertNotEqual(revised.scopeID, f.scope.scopeID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.pidfile.path))
    }
    func testUnknownAndCustomOrIncompleteRawPoliciesAreRefusedBeforeSpawn() throws {
        let f = try fixture()
        let evidence = f.scope.executionEvidence
        let bad = [evidence.setting("activePermissionProfileReported", .bool(false)), evidence.setting("activePermissionProfile", .null),
            evidence.setting("activePermissionProfile", .object([.init("id", .string("custom"))])),
            evidence.setting("activePermissionProfile", .object([.init("id", .string(":workspace")), .init("extends", .string("restricted"))])),
            evidence.setting("sandbox", evidence["sandbox"].setting("readOnlyRoots", .array([.string("/private")]))),
            evidence.setting("sandbox", evidence["sandbox"].removing("networkAccess"))]
        for value in bad {
            let scope = BackendChatOwnedTerminals.Scope(sessionID: f.scope.sessionID, conversation: f.scope.conversation, generation: f.scope.generation,
                cwd: f.scope.cwd, launch: f.scope.launch, effectivePolicy: f.scope.effectivePolicy, executionEvidence: value)
            XCTAssertThrowsError(try BackendChatOwnedTerminals(scope: scope))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.pidfile.path))
    }
    func testPolicyCaptureRequiresMatchedActualResponseNotRequestedConfig() throws {
        let response = NativeRPCValue.object([.init("thread", .object([.init("id", .string("own-thread"))])), .init("sandbox", .object([.init("type", .string("readOnly"))]))])
        XCTAssertNil(BackendChatOwnedTerminals.executionEvidence(response, conversation: "foreign", source: "thread/start"))
        XCTAssertNil(BackendChatOwnedTerminals.executionEvidence(response, conversation: "own-thread", source: "config/read"))
        let actual = try XCTUnwrap(BackendChatOwnedTerminals.executionEvidence(response, conversation: "own-thread", source: "thread/start"))
        XCTAssertEqual(actual["activePermissionProfileReported"].bool, false)
    }
    func testParentCleanupReapsAPrivateConnectionDuringPendingInitialization() async throws {
        let f = try fixture(mode: "hold-init"), terminal = try owner(f)
        let permit = try BackendChatOwnedTerminals.AppApproval.mint(sessionID: f.scope.sessionID, scopeID: f.scope.scopeID, operation: "create", arguments: .object([]), origin: .nativeUser)
        let pending = Task { try await terminal.invoke(operation: "create", arguments: .object([]), approval: permit) }
        try await wait { FileManager.default.fileExists(atPath: f.pidfile.path) }
        let privatePID = try pid(f.pidfile)
        let cleanup = await terminal.closeAll(reason: "Parent generation ended")
        XCTAssertEqual(cleanup["closed"].bool, true)
        do { _ = try await pending.value; XCTFail("Closed startup returned a live terminal") } catch {}
        XCTAssertEqual(kill(privatePID, 0), -1)
        let records = try String(contentsOf: f.trace, encoding: .utf8)
        XCTAssertFalse(records.contains("command/exec"))
    }
    func testOutputIsBoundedAndExplicitlyTruncated() async throws {
        let f = try fixture(mode: "large"), terminal = try owner(f)
        let created = try await approved(terminal, scope: f.scope, operation: "create")
        let handle = try XCTUnwrap(created["handle"].string)
        try await wait { try await self.read(terminal, handle: handle)["truncated"].bool == true }
        let output = try await read(terminal, handle: handle)
        XCTAssertLessThanOrEqual(output["output"].string?.utf8.count ?? .max, 262_144)
        XCTAssertEqual(output["outputBytes"].number, 300_000)
        XCTAssertGreaterThan(output["droppedBefore"].number ?? 0, 0)
    }
    func testTrustedApprovalWireRoundTripPreservesArgumentBinding() throws {
        let f = try fixture()
        let args = NativeRPCValue.object([.init("text", .string("hello")), .init("handle", .string("minted"))])
        let permit = try BackendChatOwnedTerminals.AppApproval.mint(sessionID: f.scope.sessionID, scopeID: f.scope.scopeID, operation: "write", arguments: args, origin: .toolConsent)
        let decoded = try BackendChatOwnedTerminals.AppApproval(trustedWire: permit.wireValue)
        XCTAssertEqual(decoded.nonce, permit.nonce)
        XCTAssertEqual(decoded.digest, permit.digest)
        XCTAssertEqual(decoded.scopeID, f.scope.scopeID)
        XCTAssertThrowsError(try BackendChatOwnedTerminals.AppApproval(trustedWire: permit.wireValue.setting("origin", .string("callerBoolean"))))
    }
}
