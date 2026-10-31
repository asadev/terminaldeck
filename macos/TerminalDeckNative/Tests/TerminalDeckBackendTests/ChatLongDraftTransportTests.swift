import Foundation
import CryptoKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ChatLongDraftTransportTests: XCTestCase, @unchecked Sendable {
    private let fake = #"""
import json,sys,os,hashlib,base64
held=None
def out(v): print(json.dumps(v),flush=True)
for line in sys.stdin:
 r=json.loads(line); m=r.get('method')
 if r.get('type')=='control_request':
  out({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{}}}); continue
 if m=='initialize':
  result={'protocolVersion':1,'agentCapabilities':{'loadSession':True,'mcpCapabilities':{'http':True},'promptCapabilities':{'embeddedContext':True,'image':True}}} if r.get('params',{}).get('protocolVersion')==1 else {}
  out({'id':r['id'],'result':result}); continue
 if m in ['session/new','session/load']: out({'id':r['id'],'result':{'sessionId':'own-thread'}}); continue
 if m=='session/cancel':
  open(os.environ['TD_DRAFT_CANCEL'],'w').write('cancelled')
  if held: out({'id':held,'result':{'stopReason':'cancelled'}})
  held=None; continue
 if m in ['thread/start','thread/resume']: out({'id':r['id'],'result':{'thread':{'id':'own-thread'}}}); continue
 if m=='skills/list': out({'id':r['id'],'result':{'data':[]}}); continue
 if r.get('type')=='user' or m in ['turn/start','session/prompt']:
  content=r.get('message',{}).get('content',[]) if r.get('type')=='user' else r.get('params',{}).get('input',r.get('params',{}).get('prompt',[]))
  text=''.join(x.get('text','') for x in content if x.get('type')=='text')
  if m=='session/prompt' and text=='hold parent':
   held=r['id']; open(os.environ['TD_DRAFT_WORKING'],'w').write('working'); continue
  receipt={'textBytes':len(text.encode()),'sha256':hashlib.sha256(text.encode()).hexdigest(),'attachmentCount':sum(x.get('type')!='text' for x in content),'lineBytes':len(line.encode())}
  with open(os.environ['TD_DRAFT_RECEIPT'],'a') as f: f.write(json.dumps(receipt)+'\n')
  if r.get('type')=='user':
   out({'type':'assistant','message':{'content':[{'type':'text','text':'received'}]}})
   out({'type':'result','subtype':'success','session_id':'own-thread','is_error':False})
  elif m=='session/prompt':
   out({'id':r['id'],'result':{'stopReason':'end_turn'}})
  else:
   out({'id':r['id'],'result':{'turn':{'id':'turn-1'}}})
   out({'method':'turn/started','params':{'threadId':'own-thread','turn':{'id':'turn-1'}}})
   out({'method':'item/completed','params':{'threadId':'own-thread','turnId':'turn-1','item':{'id':'answer','type':'agentMessage','text':'received'}}})
   out({'method':'turn/completed','params':{'threadId':'own-thread','turn':{'id':'turn-1','status':'completed'}}})
"""#
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-long-draft-transport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func start(_ provider: HootChatProvider = .claude, root: URL, instructions: String = "") async throws -> BackendHootChatStore {
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat.json"), provider: provider, retainAllHistory: true)
        addTeardownBlock { await store.stop() }
        try await store.attach(.init(command: "/usr/bin/python3", arguments: ["-u", "-c", fake], cwd: root.path,
            environment: ["TD_DRAFT_RECEIPT": root.appendingPathComponent("receipt").path,
                "TD_DRAFT_CANCEL": root.appendingPathComponent("cancelled").path, "TD_DRAFT_WORKING": root.appendingPathComponent("working").path],
            setup: .init(cwd: root.path, instructions: instructions)))
        try await store.initialize()
        return store
    }
    private func attachment(bytes: Int = ChatAttachmentLimits.payloadBytes, padding: Int = 0) -> NativeRPCValue {
        .object([.init("type", .string("image")), .init("source", .object([.init("type", .string("base64")),
            .init("media_type", .string("image/png")), .init("data", .string(Data(repeating: 66, count: bytes).base64EncodedString()))])),
            .init("padding", .string(String(repeating: "x", count: padding)))])
    }
    private func until(_ check: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline { if try await check() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw NativeRPCError(code: "test-timeout", message: "Long draft transport fixture did not finish")
    }
    func testMaximumUTF8DraftAndFourAdvertisedFilesReachProviderExactly() async throws {
        let root = try directory(), store = try await start(root: root)
        let draft = String(repeating: "\u{01}", count: 262_144)
        let attachments = (0..<ChatAttachmentLimits.count).map { _ in attachment() }
        let wire = try BackendHootChatProcess.inputData(BackendHootChatCLI.user(draft, attachments: attachments))
        XCTAssertGreaterThan(wire.count, 1_048_576)
        XCTAssertLessThanOrEqual(wire.count, HootChatJSONLines.maximumInputBytes)
        _ = try await store.say(draft, attachments: attachments)
        try await until { await store.snapshot()["busy"].bool == false }
        let line = try XCTUnwrap(try String(contentsOf: root.appendingPathComponent("receipt"), encoding: .utf8).split(separator: "\n").first)
        let receipt = try NativeRPCValue.parseJSON(Data(line.utf8))
        XCTAssertEqual(receipt["textBytes"].number, 262_144)
        XCTAssertEqual(receipt["attachmentCount"].number, 4)
        let hash = SHA256.hash(data: Data(draft.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(receipt["sha256"].string, hash)
        let snapshot = await store.snapshot(limit: 500)
        let users = (snapshot["events"].elements ?? []).filter { $0["kind"].string == "user" }
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users.first?["value"]["text"].string, draft)
        let alive = await store.alive
        XCTAssertTrue(alive)
    }
    func testCodexMaximumDraftAndAttachmentsFitProviderEnvelope() throws {
        let root = try directory()
        var rpc = BackendHootChatRPC(provider: .codex, setup: .init(cwd: root.path))
        let hello = try rpc.begin(id: "init", resume: nil)
        let start = try rpc.receive(.object([.init("id", hello["id"]), .init("result", .object([]))]))
        let request = try XCTUnwrap(start.send.last)
        _ = try rpc.receive(.object([.init("id", request["id"]), .init("result", .object([.init("thread", .object([.init("id", .string("own-thread"))]))]))]))
        let draft = String(repeating: "\u{01}", count: 262_144), files = (0..<4).map { _ in attachment() }
        let envelope = try rpc.user(draft, attachments: files, id: "long-draft")
        XCTAssertLessThanOrEqual(try BackendHootChatProcess.inputData(envelope).count, HootChatJSONLines.maximumInputBytes)
        XCTAssertEqual(envelope["params"]["input"].elements?.first?["text"].string, draft)
        XCTAssertEqual(envelope["params"]["input"].elements?.count, 5)
    }
    func testWorstSupportedMessageFitsActualHelperResourceEnvelope() throws {
        let draft = String(repeating: "\u{01}", count: 262_144), files = (0..<4).map { _ in attachment() }
        let args = NativeRPCValue.object([.init("id", .string(UUID().uuidString)), .init("text", .string(draft)),
            .init("attachments", .array(files)), .init("context", .object([]))])
        var frame = BackendHOSTProtocol.Request(secret: "scratch-transport-secret", operation: .resource)
        frame.resourceMethod = "chats.say"; frame.resourcePayload = try args.encodedJSON()
        let encoded = try JSONEncoder().encode(frame)
        XCTAssertLessThanOrEqual(encoded.count, BackendHOSTProtocol.maximumRequestBytes)
        XCTAssertLessThanOrEqual(frame.resourcePayload?.count ?? .max, BackendHOSTProtocol.maximumRequestBytes)
    }
    func testCodexSlashExpandedMaximumDraftAndFilesFitTheProviderBound() throws {
        let root = try directory()
        var rpc = BackendHootChatRPC(provider: .codex, setup: .init(cwd: root.path))
        let hello = try rpc.begin(id: "init", resume: nil)
        let start = try rpc.receive(.object([.init("id", hello["id"]), .init("result", .object([]))]))
        let request = try XCTUnwrap(start.send.last)
        _ = try rpc.receive(.object([.init("id", request["id"]), .init("result", .object([.init("thread", .object([.init("id", .string("own-thread"))]))]))]))
        let draft = "/init " + String(repeating: "\u{01}", count: 262_144 - 6)
        XCTAssertEqual(draft.utf8.count, 262_144)
        let files = (0..<4).map { _ in attachment() }
        let envelope = try rpc.user(draft, attachments: files, id: "expanded-draft", commandText: draft)
        let bytes = try BackendHootChatProcess.inputData(envelope)
        XCTAssertGreaterThan(bytes.count, 5 * 1_048_576)
        XCTAssertLessThanOrEqual(bytes.count, HootChatJSONLines.maximumInputBytes)
        let expanded = try XCTUnwrap(envelope["params"]["input"].elements?.first?["text"].string)
        XCTAssertTrue(expanded.hasPrefix(draft))
        XCTAssertTrue(expanded.hasSuffix(String(draft.dropFirst(6))))
        XCTAssertEqual(envelope["params"]["input"].elements?.count, 5)
    }
    func testOversizedEnvelopeRejectedBeforeJournalWithoutStoppingParent() async throws {
        let root = try directory(), store = try await start(root: root)
        let pid = await store.processPID
        let before = await store.snapshot(limit: 500)
        do {
            _ = try await store.say("valid draft", attachments: [attachment(bytes: 1, padding: HootChatJSONLines.maximumInputBytes)])
            XCTFail("Oversized complete envelope accepted")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "provider-input-limit") }
        let after = await store.snapshot(limit: 500)
        XCTAssertEqual(after["sequence"], before["sequence"])
        XCTAssertEqual(after["busy"].bool, false)
        let currentPID = await store.processPID
        XCTAssertEqual(currentPID, pid)
        let alive = await store.alive
        XCTAssertTrue(alive)
        _ = try await store.say("small follow-up")
        try await until { await store.snapshot()["busy"].bool == false }
        let followupPID = await store.processPID
        XCTAssertEqual(followupPID, pid)
    }
    func testOversizedGeminiSendNowCannotInterruptTheExistingParentTurn() async throws {
        let root = try directory()
        let store = try await start(.gemini, root: root, instructions: String(repeating: "x", count: HootChatJSONLines.maximumInputBytes - 1_048_576))
        _ = try await store.say("hold parent")
        try await until { FileManager.default.fileExists(atPath: root.appendingPathComponent("working").path) }
        let pid = await store.processPID, before = await store.snapshot(limit: 500)
        do {
            _ = try await store.steer(String(repeating: "\u{01}", count: 262_144))
            XCTFail("Oversized Gemini Send now was accepted")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "provider-input-limit") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled").path))
        let after = await store.snapshot(limit: 500), currentPID = await store.processPID
        XCTAssertEqual(after["sequence"], before["sequence"])
        XCTAssertEqual(after["busy"].bool, true)
        XCTAssertEqual(currentPID, pid)
        XCTAssertEqual((after["events"].elements ?? []).filter { $0["kind"].string == "user" }.count, 1)
    }
    func testFinalHiddenEnvelopePreflightRestoresReservedTurnWithoutClosingParent() async throws {
        let root = try directory(), store = try await start(root: root)
        let pid = await store.processPID
        let base = try BackendHootChatProcess.inputData(BackendHootChatCLI.user("draft", attachments: [attachment(bytes: 1)])).count
        let nearLimit = attachment(bytes: 1, padding: HootChatJSONLines.maximumInputBytes - base - 1024)
        await store.setDesk(lines: { _, _ in String(repeating: "\u{01}", count: 4096) })
        let before = await store.snapshot(limit: 500)
        do {
            _ = try await store.say("draft", attachments: [nearLimit])
            XCTFail("Final hidden envelope bypassed preflight")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "provider-input-limit") }
        let rejected = await store.snapshot(limit: 500)
        XCTAssertEqual(rejected["sequence"], before["sequence"])
        XCTAssertEqual(rejected["busy"].bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("receipt").path))
        await store.setDesk(lines: nil)
        _ = try await store.say("next valid draft")
        try await until { await store.snapshot()["busy"].bool == false }
        let currentPID = await store.processPID, alive = await store.alive
        XCTAssertEqual(currentPID, pid)
        XCTAssertTrue(alive)
    }
}
