import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckCoreSecurityTestBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ value: T) { lock.withLock { self.value = value } }
    func edit(_ body: (inout T) -> Void) { lock.withLock { body(&value) } }
}
final class BackendDeckCoreSecurityStorageTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckCoreSecurity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func make(_ keys: BackendDeckCoreSecurityAccessKeys, name: String = "ChatGPT", level: String = "full", extra: NativeRPCValue = .object([])) async throws -> NativeRPCValue {
        try await keys.create(.object([.init("name", .string(name)), .init("level", .string(level))]).merging(extra))
    }
    func testSecretOnlyReturnedOnceHashOnlyOnDiskAndPrivateModes() async throws {
        let directory = try temporary().appendingPathComponent("remote")
        let keys = BackendDeckCoreSecurityAccessKeys(directory: directory)
        let made = try await make(keys)
        let secret = try XCTUnwrap(made["key"].string)
        XCTAssertTrue(secret.hasPrefix("ak_"))
        let text = try String(contentsOf: directory.appendingPathComponent("access-keys.json"), encoding: .utf8)
        XCTAssertFalse(text.contains(secret)); XCTAssertNotNil(text.range(of: #""hash": "[0-9a-f]{64}""#, options: .regularExpression))
        let views = await keys.list(); XCTAssertFalse(NativeRPCValue.array(views).compact.contains("hash"))
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("access-keys.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)
    }
    func testSecretPersistsThroughHashMatchAndRevokePersists() async throws {
        let dir = try temporary(); let keys = BackendDeckCoreSecurityAccessKeys(directory: dir)
        let made = try await make(keys); let id = try XCTUnwrap(made["view"]["id"].string); let secret = made["key"].string
        let reopened = BackendDeckCoreSecurityAccessKeys(directory: dir)
        let found = await reopened.match(secret); XCTAssertEqual(found?["id"].string, id)
        let bad = await keys.match((secret ?? "") + "x"); XCTAssertNil(bad)
        let revoked = try await keys.revoke(id: id); XCTAssertTrue(revoked)
        let after = BackendDeckCoreSecurityAccessKeys(directory: dir); let missing = await after.match(secret); XCTAssertNil(missing)
    }
    func testTasksDefaultOffLiteralTrueOnlyAndOlderFileStaysOff() async throws {
        let dir = try temporary(); let keys = BackendDeckCoreSecurityAccessKeys(directory: dir)
        let made = try await make(keys); let id = try XCTUnwrap(made["view"]["id"].string)
        XCTAssertEqual(made["view"]["tasks"], .bool(false))
        let no = try await keys.setTasks(id: id, on: .string("yes")); XCTAssertEqual(no["tasks"], .bool(false))
        let yes = try await keys.setTasks(id: id, on: .bool(true)); XCTAssertEqual(yes["tasks"], .bool(true))
        let file = dir.appendingPathComponent("access-keys.json")
        let raw = try NativeRPCValue.parseJSON(Data(contentsOf: file)); let old = raw.setting("keys", .array((raw["keys"].elements ?? []).map { $0.removing("tasks") }))
        try old.encodedJSON().write(to: file)
        let reopened = BackendDeckCoreSecurityAccessKeys(directory: dir); let view = await reopened.get(id: id); XCTAssertEqual(view?["tasks"], .bool(false))
    }
    func testStrictLevelsNamesAskingAndFolderLimits() async throws {
        let keys = BackendDeckCoreSecurityAccessKeys(directory: try temporary())
        let made = try await make(keys, name: "Chat\nGPT", extra: .object([.init("askFirst", .string("no")), .init("folders", .array([.string("/work/a"), .string("/work/a"), .string("relative")]))]))
        XCTAssertEqual(made["view"]["name"], .string("Chat GPT")); XCTAssertEqual(made["view"]["askFirst"], .bool(true))
        XCTAssertEqual(made["view"]["folders"], .array([.string("/work/a")]))
        do { _ = try await make(keys, level: "admin"); XCTFail("An unknown level must refuse") } catch {}
        do { _ = try await make(keys, name: String(repeating: "x", count: 61)); XCTFail("A long name must refuse") } catch {}
        XCTAssertEqual(BackendDeckCoreSecurityAccessKeys.tiersFor("look"), [.read])
        XCTAssertEqual(BackendDeckCoreSecurityAccessKeys.tiersFor("work"), [.read, .act])
        XCTAssertEqual(BackendDeckCoreSecurityAccessKeys.tiersFor("full"), [.read, .act, .alter])
    }
    func testUnreadableStoreFailsClosedAndPreservesCopy() async throws {
        let dir = try temporary(); let file = dir.appendingPathComponent("access-keys.json")
        try Data("{bad json".utf8).write(to: file)
        let keys = BackendDeckCoreSecurityAccessKeys(directory: dir); let views = await keys.list(); let internet = await keys.internet()
        XCTAssertTrue(views.isEmpty); XCTAssertFalse(internet)
        let problem = await keys.loadProblem(); XCTAssertTrue(problem?.contains("could not be read") == true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.contains(".unreadable-") })
    }
    func testWebhookSecretOnceThenRotationAndPrivateView() async throws {
        let keys = BackendDeckCoreSecurityAccessKeys(directory: try temporary())
        let made = try await make(keys); let id = try XCTUnwrap(made["view"]["id"].string)
        let first = try await keys.setNotify(id: id, input: .object([.init("mode", .string("webhook")), .init("url", .string("https://hooks.example.com/x"))]))
        XCTAssertTrue(first["secret"].string?.hasPrefix("whsec_") == true)
        XCTAssertFalse(first["view"].compact.contains(first["secret"].string ?? "missing"))
        _ = try await keys.setNotify(id: id, input: .object([.init("mode", .string("off"))]))
        let again = try await keys.setNotify(id: id, input: .object([.init("mode", .string("webhook"))])); XCTAssertEqual(again["secret"], .null)
        let rotated = try await keys.rotateWebhookSecret(id: id); XCTAssertNotEqual(rotated["secret"], first["secret"])
        XCTAssertNotNil(BackendDeckCoreSecurityAccessKeys.webhookURLProblem("http://remote.example.com/x"))
        XCTAssertNil(BackendDeckCoreSecurityAccessKeys.webhookURLProblem("http://127.0.0.1:9000/hook"))
    }
    func testLastUsedFlushThrottleAndCleanLabel() async throws {
        let clock = BackendDeckCoreSecurityTestBox<Double>(1000); let dir = try temporary()
        let keys = BackendDeckCoreSecurityAccessKeys(directory: dir, now: { clock.get() })
        let made = try await make(keys); let id = try XCTUnwrap(made["view"]["id"].string)
        await keys.noteUsed(id: id, via: "this-mac", app: "cursor"); let file = dir.appendingPathComponent("access-keys.json")
        let before = try Data(contentsOf: file); clock.set(2000); await keys.noteUsed(id: id, via: "this-mac", app: nil)
        XCTAssertEqual(try Data(contentsOf: file), before); try await keys.flush(); XCTAssertNotEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(BackendDeckCoreSecurityAccessKeys.cleanAppLabel("evil\nrow " + String(repeating: "x", count: 200))?.utf16.count, 80)
    }
    func testKeyCapAndLiteralInternetSwitch() async throws {
        let keys = BackendDeckCoreSecurityAccessKeys(directory: try temporary())
        for index in 0..<50 { _ = try await make(keys, name: "K\(index)") }
        do { _ = try await make(keys); XCTFail("The fifty-first key must refuse") } catch {}
        let no = try await keys.setInternet(.string("yes")); XCTAssertFalse(no)
        let yes = try await keys.setInternet(.bool(true)); XCTAssertTrue(yes)
        try await keys.setPort(47821); try await keys.setPort(-1); let port = await keys.port(); XCTAssertEqual(port, 47821)
    }
    func testArgumentScrubbingKeepsIDsDropsSecretsAndCapsDepth() {
        let args = NativeRPCValue.object([.init("token", .string("secret")), .init("cwd", .string("/Users/asad/Projects/x")), .init("sessionId", .string("0f9c1d2e-4a5b-6c7d-8e9f-a0b1c2d3e4f5")),
            .init("note", .string("the deploy failed GH_TOKEN=ghp_" + String(repeating: "Q", count: 40))), .init("patch", .object([.init("theme", .string("light")), .init("deep", .object([.init("a", .number(1))]))]))])
        let scrubbed = BackendDeckCoreSecurityActionLog.scrubArguments(args)
        XCTAssertEqual(scrubbed["token"], .string("[redacted]")); XCTAssertEqual(scrubbed["cwd"], args["cwd"]); XCTAssertEqual(scrubbed["sessionId"], args["sessionId"])
        XCTAssertFalse(scrubbed["note"].compact.contains("ghp_")); XCTAssertEqual(scrubbed["patch"]["deep"], .string("[object]"))
    }
    func testLogRotationTornLinesAndLifecycleRows() async throws {
        let dir = try temporary(); let log = BackendDeckCoreSecurityActionLog(directory: dir, maximumBytes: 4096)
        for index in 0..<100 { await log.record(.object([.init("id", .string("call-\(index)")), .init("action", .string("tool.projects.list")), .init("detail", .string(String(repeating: "x", count: 80)))])) }
        let tail = await log.tail(100); XCTAssertEqual(tail.last?["id"], .string("call-99")); XCTAssertGreaterThan(tail.count, 1)
        let file = dir.appendingPathComponent("actions.jsonl"); let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("{torn\n".utf8)); try handle.close()
        await log.record(.object([.init("action", .string("home.created")), .init("detail", .string("Made the copilot folder"))]))
        let final = await log.tail(200); XCTAssertEqual(final.last?["action"], .string("home.created"))
        let empty = await log.tail(0); XCTAssertTrue(empty.isEmpty)
    }
    func testOversizedRowStillRecordsCallAndBrokenLogDoesNotThrow() async throws {
        let dir = try temporary(); let log = BackendDeckCoreSecurityActionLog(directory: dir)
        await log.record(.object([.init("tool", .string("projects.list")), .init("args", .object([.init("note", .string(String(repeating: "y", count: 200_000)))]))]))
        let rows = await log.tail(1); XCTAssertEqual(rows.first?["args"]["note"], .string("arguments were too large to record"))
        let blocked = dir.appendingPathComponent("blocked"); try Data("file".utf8).write(to: blocked)
        let failed = BackendDeckCoreSecurityActionLog(directory: blocked); await failed.record(.object([])); let broken = await failed.broken(); XCTAssertTrue(broken)
    }
}
