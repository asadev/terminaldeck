import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckCoreTestPortSecurityStorage: BackendDeckCoreTestPortSecurityCase {
    private func keys(_ directory: URL? = nil, clock: BackendDeckCoreTestPortSecurityClock = .init()) throws -> BackendDeckCoreSecurityAccessKeys {
        BackendDeckCoreSecurityAccessKeys(directory: try directory ?? scratch(), now: { clock.now() })
    }
    private func disk(_ directory: URL) throws -> String { try String(contentsOf: directory.appendingPathComponent("access-keys.json"), encoding: .utf8) }
    func testAccessKeysL33() async throws {
        let dir = try scratch(), store = try keys(dir), made = try await made(store, level: "work")
        let secret = try XCTUnwrap(made["key"].string), text = try disk(dir)
        XCTAssertTrue(secret.hasPrefix("ak_")); XCTAssertGreaterThan(secret.count, 40)
        XCTAssertFalse(text.contains(secret)); XCTAssertFalse(text.contains(String(secret.dropFirst(3))))
        XCTAssertNotNil(text.range(of: #""hash": "[0-9a-f]{64}""#, options: .regularExpression))
        let list = await store.list(); XCTAssertFalse(V.array(list).compact.contains(secret)); XCTAssertFalse(V.array(list).compact.contains("hash"))
    }
    // access-keys:47 maps to the existing exact private-file/directory assertion.
    func testAccessKeysL55() async throws {
        let store = try keys(), a = try await made(store, name: "A", level: "look"), b = try await made(store, name: "B", level: "look")
        XCTAssertNotEqual(a["key"], b["key"])
    }
    func testAccessKeysL62() async throws {
        let store = try keys(), a = try await made(store, name: "A"), b = try await made(store, name: "B", extras: o([("askFirst", .string("no"))])), c = try await made(store, name: "C", extras: o([("askFirst", .bool(false))]))
        XCTAssertEqual(a["view"]["askFirst"], .bool(true)); XCTAssertEqual(b["view"]["askFirst"], .bool(true)); XCTAssertEqual(c["view"]["askFirst"], .bool(false))
    }
    func testAccessKeysL69() async throws {
        let store = try keys()
        await assertAsyncError({ _ = try await self.made(store, name: "   ", level: "look") }, code: "key-refused")
        await assertAsyncError({ _ = try await self.made(store, name: String(repeating: "x", count: 61), level: "look") }, code: "key-refused")
        await assertAsyncError({ _ = try await self.made(store, name: "A", level: "admin") }, code: "key-refused")
    }
    func testAccessKeysL76() async throws { let result = try await made(keys(), name: "Chat\nGPT", level: "look"); XCTAssertEqual(result["view"]["name"], .string("Chat GPT")) }
    func testAccessKeysL82() async throws {
        let store = try keys(); for index in 0..<50 { _ = try await made(store, name: "K\(index)", level: "look") }
        await assertAsyncError({ _ = try await self.made(store, name: "one too many", level: "look") }, code: "key-refused")
    }
    func testAccessKeysL90() async throws {
        let store = try keys(), result = try await made(store, level: "work"), secret = try XCTUnwrap(result["key"].string)
        let found = await store.match(secret); XCTAssertEqual(found?["id"], result["view"]["id"])
        for value in [secret + "x", String(secret.dropLast()), "", String(secret.dropFirst(3))] { let found = await store.match(value); XCTAssertNil(found, value) }
        let absent = await store.match(nil); XCTAssertNil(absent)
    }
    func testAccessKeysL101() async throws {
        let dir = try scratch(), first = try keys(dir), result = try await made(first, level: "work"), reopened = try keys(dir)
        let found = await reopened.match(result["key"].string); XCTAssertEqual(found?["name"], .string("ChatGPT"))
    }
    func testAccessKeysL108() async throws {
        let dir = try scratch(), store = try keys(dir), result = try await made(store, name: "Claude Desktop"), id = try XCTUnwrap(result["view"]["id"].string)
        let initial = await store.get(id: id); XCTAssertEqual(initial?["tasks"], .bool(false))
        _ = try await store.setTasks(id: id, on: .string("yes")); let no = await store.get(id: id); XCTAssertEqual(no?["tasks"], .bool(false))
        _ = try await store.setTasks(id: id, on: .bool(true)); let yes = await store.get(id: id); XCTAssertEqual(yes?["tasks"], .bool(true))
        let restored = try await keys(dir).get(id: id); XCTAssertEqual(restored?["tasks"], .bool(true))
        _ = try await store.setTasks(id: id, on: .bool(false)); let off = try await keys(dir).get(id: id); XCTAssertEqual(off?["tasks"], .bool(false))
        try await store.flush(); let file = dir.appendingPathComponent("access-keys.json"), raw = try V.parseJSON(Data(contentsOf: file))
        try raw.setting("keys", .array((raw["keys"].elements ?? []).map { $0.removing("tasks") })).encodedJSON().write(to: file)
        let old = try await keys(dir).get(id: id); XCTAssertEqual(old?["tasks"], .bool(false))
    }
    func testAccessKeysL128() async throws {
        let dir = try scratch(), store = try keys(dir), result = try await made(store), id = try XCTUnwrap(result["view"]["id"].string)
        let revoked = try await store.revoke(id: id); XCTAssertTrue(revoked)
        let match = await store.match(result["key"].string), view = await store.get(id: id), diskMatch = try await keys(dir).match(result["key"].string)
        XCTAssertNil(match); XCTAssertNil(view); XCTAssertNil(diskMatch)
        let again = try await store.revoke(id: id); XCTAssertFalse(again)
    }
    func testAccessKeysL139() async throws {
        let dir = try scratch(), store = try keys(dir), result = try await made(store, name: "Cursor", level: "look"), id = try XCTUnwrap(result["view"]["id"].string)
        _ = try await store.setLevel(id: id, level: .string("full")); let local = await store.get(id: id), restored = try await keys(dir).get(id: id)
        XCTAssertEqual(local?["level"], .string("full")); XCTAssertEqual(restored?["level"], .string("full"))
        await assertAsyncError({ _ = try await store.setLevel(id: id, level: .string("root")) }, code: "key-refused")
    }
    func testAccessKeysL148() async throws {
        let store = try keys(), result = try await made(store, name: "A"), id = try XCTUnwrap(result["view"]["id"].string)
        let renamed = try await store.rename(id: id, name: .string("Claude on the web")); XCTAssertEqual(renamed["name"], .string("Claude on the web"))
        let no = try await store.setAskFirst(id: id, askFirst: .bool(false)); XCTAssertEqual(no["askFirst"], .bool(false))
        let yes = try await store.setAskFirst(id: id, askFirst: .missing); XCTAssertEqual(yes["askFirst"], .bool(true))
        let folder = try await store.setFolders(id: id, folders: .array([.string("/work/site"), .string("relative/ignored")])); XCTAssertEqual(folder["folders"], .array([.string("/work/site")]))
        let all = try await store.setFolders(id: id, folders: .null), empty = try await store.setFolders(id: id, folders: .array([])); XCTAssertEqual(all["folders"], .null); XCTAssertEqual(empty["folders"], .null)
    }
    func testAccessKeysL159() async throws { let store = try keys(); await assertAsyncError({ _ = try await store.rename(id: "nope", name: .string("x")) }, code: "key-refused") }
    func testAccessKeysL163() async throws {
        let store = try keys(), count = BackendDeckCoreSecurityTestBox(0); _ = await store.onChange { count.edit { $0 += 1 } }
        let result = try await made(store, name: "A", level: "look"), id = try XCTUnwrap(result["view"]["id"].string)
        _ = try await store.setLevel(id: id, level: .string("work")); _ = try await store.revoke(id: id); _ = try await store.setInternet(.bool(true)); XCTAssertEqual(count.get(), 4)
    }
    func testAccessKeysL176() {
        XCTAssertEqual(BackendDeckCoreSecurityAccessKeys.tiersFor("look"), [.read])
        XCTAssertEqual(BackendDeckCoreSecurityAccessKeys.tiersFor("work"), [.read, .act])
        XCTAssertEqual(BackendDeckCoreSecurityAccessKeys.tiersFor("full"), [.read, .act, .alter])
    }
    func testAccessKeysL184() async throws {
        let dir = try scratch(), store = try keys(dir); let initial = await store.internet(); XCTAssertFalse(initial)
        let wrong = try await store.setInternet(.string("yes")), yes = try await store.setInternet(.bool(true)); XCTAssertFalse(wrong); XCTAssertTrue(yes)
        let restored = try await keys(dir).internet(); XCTAssertTrue(restored)
        _ = try await store.setInternet(.bool(false)); let off = try await keys(dir).internet(); XCTAssertFalse(off)
    }
    func testAccessKeysL194() async throws {
        let dir = try scratch(), store = try keys(dir), initial = await store.port(); XCTAssertNil(initial)
        try await store.setPort(47_821); let first = try await keys(dir).port(); XCTAssertEqual(first, 47_821)
        try await store.setPort(-1); let second = try await keys(dir).port(); XCTAssertEqual(second, 47_821)
    }
    func testAccessKeysL205() async throws {
        let clock = BackendDeckCoreTestPortSecurityClock(1000), dir = try scratch(), store = try keys(dir, clock: clock), result = try await made(store, name: "A", level: "look"), id = try XCTUnwrap(result["view"]["id"].string)
        clock.set(5000); await store.noteUsed(id: id, via: "internet", app: "claude-ai 0.1.0")
        let view = await store.get(id: id); XCTAssertEqual(view?["lastUsedAt"], .number(5000)); XCTAssertEqual(view?["lastVia"], .string("internet")); XCTAssertEqual(view?["lastApp"], .string("claude-ai 0.1.0"))
        let restored = try await keys(dir).get(id: id); XCTAssertEqual(restored?["lastApp"], .string("claude-ai 0.1.0"))
    }
    func testAccessKeysL215() async throws {
        let clock = BackendDeckCoreTestPortSecurityClock(1000), dir = try scratch(), store = try keys(dir, clock: clock), result = try await made(store, name: "A", level: "look"), id = try XCTUnwrap(result["view"]["id"].string)
        await store.noteUsed(id: id, via: "this-mac", app: "cursor"); let before = try disk(dir)
        clock.advance(1000); await store.noteUsed(id: id, via: "this-mac", app: nil); XCTAssertEqual(try disk(dir), before)
        try await store.flush(); XCTAssertNotEqual(try disk(dir), before)
    }
    func testAccessKeysL228() async throws {
        let store = try keys(), result = try await made(store, name: "A", level: "look"), id = try XCTUnwrap(result["view"]["id"].string)
        await store.noteUsed(id: id, via: "internet", app: "evil\nrow " + String(repeating: "x", count: 200))
        let view = await store.get(id: id), label = view?["lastApp"].string ?? ""; XCTAssertFalse(label.contains("\n")); XCTAssertLessThanOrEqual(label.utf16.count, 80)
    }
    func testAccessKeysL239() async throws {
        let dir = try scratch(), store = try keys(dir), result = try await made(store, name: "A"); _ = try await store.setInternet(.bool(true))
        try Data("{ this is not json".utf8).write(to: dir.appendingPathComponent("access-keys.json"))
        let reopened = try keys(dir), match = await reopened.match(result["key"].string), internet = await reopened.internet(), problem = await reopened.loadProblem()
        XCTAssertNil(match); XCTAssertFalse(internet); XCTAssertTrue(problem?.contains("could not be read") == true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains(".unreadable-") })
    }
    func testAccessKeysL251() async throws {
        let dir = try scratch(), store = try keys(dir), result = try await made(store, name: "A"), file = dir.appendingPathComponent("access-keys.json")
        let raw = try V.parseJSON(Data(contentsOf: file)), bad = raw.setting("keys", .array((raw["keys"].elements ?? []).map { $0.setting("level", .string("superuser")) }))
        try bad.encodedJSON().write(to: file); let match = try await keys(dir).match(result["key"].string); XCTAssertNil(match)
    }
    func testAccessKeysL262() async throws {
        // access-keys.test.ts:267 `realpathSync(dir)`: the kernel path the records fence names.
        let root = URL(fileURLWithPath: BackendMacConfinement.kernelPath(try scratch().path)), directory = root.appendingPathComponent("remote"), store = try keys(directory)
        _ = try await made(store, name: "A", level: "look")
        let paths = BackendMacConfinement.recordsFencePaths(root), file = await store.file
        let expected = [root.appendingPathComponent("routines"), root.appendingPathComponent("routine-state.json"), root.appendingPathComponent("hoot-log"), file].map { BackendMacConfinement.kernelPath($0.path) }
        XCTAssertTrue(expected.allSatisfy(paths.contains))
        let profile = BackendMacConfinement.recordsFenceProfile(root)
        XCTAssertTrue(profile.contains("(deny file-write* (literal " + BackendMacConfinement.seatbeltString(BackendMacConfinement.kernelPath(file.path)) + "))"))
    }
    func testAccessKeysL282() async throws {
        let store = try keys(), result = try await made(store, name: "A", level: "work"), id = try XCTUnwrap(result["view"]["id"].string)
        XCTAssertEqual(result["view"]["notify"], o([("mode", .string("wait")), ("url", .null), ("hasSecret", .bool(false))]))
        await assertAsyncError({ _ = try await store.setNotify(id: id, input: self.o([("mode", .string("webhook"))])) }, code: "key-refused")
        await assertAsyncError({ _ = try await store.setNotify(id: id, input: self.o([("mode", .string("webhook")), ("url", .string("http://hooks.example.com/x"))])) }, contains: "https")
        let first = try await store.setNotify(id: id, input: o([("mode", .string("webhook")), ("url", .string("https://hooks.example.com/x"))]))
        XCTAssertTrue(first["secret"].string?.hasPrefix("whsec_") == true)
        XCTAssertEqual(first["view"]["notify"], o([("mode", .string("webhook")), ("url", .string("https://hooks.example.com/x")), ("hasSecret", .bool(true))]))
        _ = try await store.setNotify(id: id, input: o([("mode", .string("off"))])); let again = try await store.setNotify(id: id, input: o([("mode", .string("webhook"))])); XCTAssertEqual(again["secret"], .null)
        let settings = await store.notifySettings(id: id); XCTAssertEqual(settings, o([("mode", .string("webhook")), ("url", .string("https://hooks.example.com/x")), ("secret", first["secret"])]))
    }
    func testAccessKeysL298() async throws {
        let dir = try scratch(), store = try keys(dir), result = try await made(store, name: "A", level: "work"), id = try XCTUnwrap(result["view"]["id"].string)
        let first = try await store.setNotify(id: id, input: o([("mode", .string("webhook")), ("url", .string("https://hooks.example.com/x"))])); let list = await store.list()
        XCTAssertFalse(V.array(list).compact.contains(first["secret"].string ?? "missing"))
        let rotated = try await store.rotateWebhookSecret(id: id); XCTAssertNotEqual(rotated["secret"], first["secret"])
        let settings = await store.notifySettings(id: id), restored = try await keys(dir).notifySettings(id: id); XCTAssertEqual(settings?["secret"], rotated["secret"]); XCTAssertEqual(restored?["secret"], rotated["secret"])
    }
    func testAccessKeysL310() async throws {
        let store = try keys(), result = try await made(store, name: "A", level: "work"), id = try XCTUnwrap(result["view"]["id"].string)
        _ = try await store.setNotify(id: id, input: o([("mode", .string("webhook")), ("url", .string("http://127.0.0.1:9000/hook"))]))
        await assertAsyncError({ _ = try await store.setNotify(id: id, input: self.o([("mode", .string("webhook")), ("url", .string("https://u:p@hooks.example.com/x"))])) }, contains: "password")
    }
    private func row(_ patch: V = .object([])) -> V {
        o([("at", .string("2026-08-17T09:00:00.000Z")), ("action", .string("tool.projects.list")), ("detail", .string("List the open projects — done")), ("id", .string("call-1")), ("tool", .string("projects.list")), ("tier", .string("read")),
            ("args", .object([])), ("outcome", .string("ok")), ("confirmed", o([("required", .bool(false)), ("granted", .bool(false)), ("by", .null), ("at", .null), ("reason", .null)])), ("ms", .number(3)), ("result", o([("count", .number(2))])), ("error", .null)]).merging(patch)
    }
    private func lines(_ file: URL) throws -> [String] { try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty } }
    func testActionLogL54() async throws {
        let dir = try scratch(), log = BackendDeckCoreSecurityActionLog(directory: dir); await log.record(row()); await log.record(row(o([("id", .string("call-2"))])))
        let written = try lines(dir.appendingPathComponent("actions.jsonl")); XCTAssertEqual(written.count, 2)
        let first = try json(written[0]); XCTAssertEqual(first["v"], .number(1)); XCTAssertEqual(first["at"], .string("2026-08-17T09:00:00.000Z")); XCTAssertEqual(first["action"], .string("tool.projects.list")); XCTAssertEqual(first["tool"], .string("projects.list")); XCTAssertEqual(first["tier"], .string("read")); XCTAssertEqual(first["outcome"], .string("ok"))
    }
    func testActionLogL71() async throws { let log = BackendDeckCoreSecurityActionLog(directory: try scratch()); await log.record(row()); let written = await log.tail(1); XCTAssertEqual(written[0]["confirmed"], row()["confirmed"]) }
    func testActionLogL86() async throws {
        let dir = try scratch(), file = dir.appendingPathComponent("actions.jsonl"), log = BackendDeckCoreSecurityActionLog(directory: dir); await log.record(row())
        try (Data(contentsOf: file) + Data("{\"half a row\"\n".utf8)).write(to: file); await log.record(row(o([("id", .string("call-3"))])))
        let tail = await log.tail(10); XCTAssertEqual(tail.map { $0["id"].string }, ["call-1", "call-3"])
    }
    func testActionLogL99() { XCTAssertEqual(BackendDeckCoreSecurityActionLog.scrubArguments(o([("token", .string("abc123")), ("apiKey", .string("x")), ("authorization", .string("Bearer y")), ("cwd", .string("/work"))])), o([("token", .string("[redacted]")), ("apiKey", .string("[redacted]")), ("authorization", .string("[redacted]")), ("cwd", .string("/work"))])) }
    func testActionLogL108() { let scrubbed = BackendDeckCoreSecurityActionLog.scrubArguments(o([("text", .string("use sk-ant-api03-" + String(repeating: "Q", count: 40) + " please"))])); XCTAssertFalse(scrubbed["text"].string?.contains("sk-ant-api03") == true); XCTAssertTrue(scrubbed["text"].string?.contains("[redacted]") == true) }
    func testActionLogL114() { let scrubbed = BackendDeckCoreSecurityActionLog.scrubArguments(o([("note", .string("the deploy failed, GH_TOKEN=ghp_" + String(repeating: "Q", count: 36) + " is stale"))])); XCTAssertFalse(scrubbed["note"].string?.contains("ghp_QQQQ") == true); XCTAssertTrue(scrubbed["note"].string?.contains("[redacted]") == true); XCTAssertTrue(scrubbed["note"].string?.contains("the deploy failed") == true) }
    func testActionLogL133() {
        let scrubbed = BackendDeckCoreSecurityActionLog.scrubArguments(o([("cwd", .string("/Users/asad/Projects/terminaldeck")), ("sessionId", .string("0f9c1d2e-4a5b-6c7d-8e9f-a0b1c2d3e4f5"))]))
        XCTAssertEqual(scrubbed["cwd"], .string("/Users/asad/Projects/terminaldeck")); XCTAssertEqual(scrubbed["sessionId"], .string("0f9c1d2e-4a5b-6c7d-8e9f-a0b1c2d3e4f5"))
    }
    func testActionLogL150() { let value = BackendDeckCoreSecurityActionLog.scrubArguments(o([("note", .string(String(repeating: "x", count: 4000)))]))["note"].string ?? ""; XCTAssertLessThan(value.utf16.count, 2040); XCTAssertTrue(value.contains("chars]")) }
    func testActionLogL156() { XCTAssertEqual(BackendDeckCoreSecurityActionLog.scrubArguments(o([("patch", o([("theme", .string("light")), ("deep", o([("a", .number(1))]))]))])), o([("patch", o([("theme", .string("light")), ("deep", .string("[object]"))]))])) }
    func testActionLogL162() async throws { let log = BackendDeckCoreSecurityActionLog(directory: try scratch()); await log.record(row(o([("args", o([("note", .string(String(repeating: "y", count: 200_000)))]))]))); let written = await log.tail(1); XCTAssertEqual(written[0]["tool"], .string("projects.list")); XCTAssertEqual(written[0]["args"], o([("note", .string("arguments were too large to record"))])) }
    func testActionLogL175() async throws {
        let dir = try scratch(), file = dir.appendingPathComponent("actions.jsonl"), log = BackendDeckCoreSecurityActionLog(directory: dir, maximumBytes: 4096)
        for index in 0..<200 { await log.record(row(o([("id", .string("call-\(index)"))]))) }
        let live = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber, old = try FileManager.default.attributesOfItem(atPath: file.path + ".1")[.size] as? NSNumber
        XCTAssertLessThanOrEqual(live?.intValue ?? .max, 4096); XCTAssertGreaterThan(old?.intValue ?? 0, 0)
    }
    func testActionLogL183() async throws {
        let dir = try scratch(), file = dir.appendingPathComponent("actions.jsonl"), log = BackendDeckCoreSecurityActionLog(directory: dir, maximumBytes: 4096)
        for index in 0..<200 { await log.record(row(o([("id", .string("call-\(index)"))]))) }
        let live = try lines(file).count, tail = await log.tail(60); XCTAssertGreaterThan(tail.count, live); XCTAssertEqual(tail.last?["id"], .string("call-199")); XCTAssertEqual(tail.count, live + (try lines(URL(fileURLWithPath: file.path + ".1"))).count)
    }
    func testActionLogL202() async throws { let log = BackendDeckCoreSecurityActionLog(directory: try scratch()); await log.record(row()); for count in [0.0, -5, .nan] { let rows = await log.tail(count); XCTAssertTrue(rows.isEmpty) } }
    // action-log:214 maps to the existing broken-log assertion and nonthrowing record contract.
    func testActionLogL229() async throws {
        let dir = try scratch(), log = BackendDeckCoreSecurityActionLog(directory: dir), lifecycle = o([("at", .string("2026-08-17T09:00:00.000Z")), ("action", .string("home.created")), ("detail", .string("Made the copilot folder"))])
        await log.append(lifecycle); await log.record(row()); let tail = await log.tail(10)
        XCTAssertEqual(tail.count, 2); XCTAssertEqual(tail[0]["action"], .string("home.created")); XCTAssertEqual(tail[0]["detail"], .string("Made the copilot folder")); XCTAssertEqual(tail[1]["action"], .string("tool.projects.list")); XCTAssertTrue(tail.allSatisfy { $0["at"].string != nil })
    }
    func testActionLogL246() async throws { let dir = try scratch().appendingPathComponent("copilot-log"), log = BackendDeckCoreSecurityActionLog(directory: dir); await log.record(row()); let file = await log.file; XCTAssertEqual(file, dir.appendingPathComponent("actions.jsonl")); XCTAssertTrue(file.path.hasSuffix(BackendDeckCoreSecurityActionLog.fileName)) }
    func testActionLogL256() async throws {
        let dir = try scratch(), file = dir.appendingPathComponent("actions.jsonl"), log = BackendDeckCoreSecurityActionLog(directory: dir, maximumBytes: 4096); await log.record(row())
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        for index in 0..<50 { try handle.write(contentsOf: try o([("at", .string("2026-08-17T09:00:00.000Z")), ("action", .string("session.started")), ("detail", .string("session \(index)"))]).encodedJSON() + Data([10])) }; try handle.close()
        await log.record(row(o([("id", .string("after"))]))); let tail = await log.tail(200); XCTAssertEqual(tail.filter { $0["action"] == .string("session.started") }.count, 50); XCTAssertEqual(tail.last?["id"], .string("after"))
    }
}
