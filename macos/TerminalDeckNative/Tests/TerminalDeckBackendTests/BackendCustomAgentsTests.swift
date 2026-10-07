import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@MainActor
final class BackendCustomAgentsTests: XCTestCase {
    private func directory() throws -> URL { let path = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCustomAgentsTests-" + UUID().uuidString); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); return path }
    private func draft(_ patch: NativeRPCValue = .object([])) -> NativeRPCValue { BackendGitHubRules.object([("label", .string("Grok")), ("description", .string("A command line agent.")), ("command", .string("grok")), ("args", .string("")), ("resumeArgs", .string(""))]).merging(patch) }
    func testSplitterAndSlug() {
        XCTAssertEqual(BackendCustomAgentsRules.splitArgs(#"--flag "" --prompt "answer in French" unclosed 'rest of line"#), ["--flag", "", "--prompt", "answer in French", "unclosed", "rest of line"])
        XCTAssertEqual(BackendCustomAgentsRules.id(label: "An Agent", taken: ["custom:an-agent", "custom:an-agent-2"]), "custom:an-agent-3")
        XCTAssertEqual(BackendCustomAgentsRules.id(label: "中文"), "custom:agent")
    }
    func testValidationKeepsLimitsAndRefusals() {
        for command in ["grok --yes", "rm;echo", "./agent", #"\\server\share\agent.exe"#, "grok\0"] {
            XCTAssertNotNil(BackendCustomAgentsRules.validate(draft(BackendGitHubRules.object([("command", .string(command))])))["command"].string)
        }
        let windows = BackendCustomAgentsRules.validate(draft(BackendGitHubRules.object([("command", .string(#"C:\tools\agent.exe"#)), ("args", .string(#"--config C:\tools\agent.json"#))])))
        XCTAssertTrue(windows.fields?.isEmpty == true) // Portable file grammar stays readable on a Mac.
        XCTAssertNotNil(BackendCustomAgentsRules.validate(draft(), takenLabels: ["grok"])["label"].string)
        XCTAssertNotNil(BackendCustomAgentsRules.validate(draft(BackendGitHubRules.object([("args", .string(String(repeating: "x ", count: 25)))])))["args"].string)
        XCTAssertNotNil(BackendCustomAgentsRules.validate(draft(BackendGitHubRules.object([("description", .string(String(repeating: "x", count: 121)))])))["description"].string)
    }
    func testMissingCommandNeverWrites() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try BackendCustomAgentsStore(dataDirectory: dir, lookup: { _ in nil })
        let result = try await store.add(draft()), listed = await store.list()
        XCTAssertEqual(result["ok"].bool, false); XCTAssertTrue(result["problems"]["command"].string?.contains("grok") == true); XCTAssertEqual(listed, .array([]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
    }
    func testRoundTripSchemaAndUnknownFeaturesWithdrawn() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try BackendCustomAgentsStore(dataDirectory: dir, lookup: { _ in "/fixture/grok" }, now: { 123 })
        let result = try await store.add(draft(BackendGitHubRules.object([("args", .string(#"--prompt "answer in French""#)), ("resumeArgs", .string("--continue"))])))
        XCTAssertEqual(result["agent"]["id"].string, "custom:grok"); XCTAssertEqual(result["agent"]["resolvedPath"].string, "/fixture/grok")
        XCTAssertEqual(result["agent"]["args"], .array([.string("--prompt"), .string("answer in French")]))
        let bytes = try Data(contentsOf: store.file), disk = try NativeRPCValue.parseJSON(bytes)
        XCTAssertEqual(bytes.last, 10); XCTAssertEqual(disk["version"].number, 1); XCTAssertEqual(disk["agents"].elements?.count, 1)
        let reopened = try BackendCustomAgentsStore(dataDirectory: dir, lookup: { _ in nil }), listed = await reopened.list()
        XCTAssertEqual(listed.elements?.first, result["agent"])
        let entry = BackendCustomAgentsRules.entry(result["agent"])
        for key in ["versionArgs", "statusArgs", "signInArgs", "signOutArgs", "configEnv", "credentialFile", "install", "url"] { XCTAssertEqual(entry[key], .null) }
        XCTAssertEqual(entry["logins"].string, "unmeasured"); XCTAssertTrue(entry["verified"].string?.contains("/fixture/grok") == true)
    }
    func testDuplicateBuiltinAndCustomNamesRejected() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try BackendCustomAgentsStore(dataDirectory: dir, lookup: { _ in "/fixture/grok" })
        let builtin = try await store.add(draft(BackendGitHubRules.object([("label", .string("Claude Code"))])))
        XCTAssertNotNil(builtin["problems"]["label"].string)
        _ = try await store.add(draft())
        let second = try await store.add(draft()); XCTAssertNotNil(second["problems"]["label"].string)
    }
    func testBadDiskEntryCostsOnlyThatRowAndDuplicatesKeepFirst() throws {
        let good = BackendGitHubRules.object([("id", .string("custom:a")), ("label", .string("A")), ("command", .string("grok")), ("args", .array([])), ("resumeArgs", .array([]))])
        let bad = good.setting("id", .string("custom:b")).setting("command", .string("rm -rf ~ & echo"))
        let parsed = BackendCustomAgentsRules.parseAgents(.array([good, bad, good]))
        XCTAssertEqual(parsed.count, 1); XCTAssertEqual(parsed.first?["id"].string, "custom:a")
    }
    func testCapAndTargetedRemoval() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try BackendCustomAgentsStore(dataDirectory: dir, lookup: { _ in "/fixture/bin" })
        for index in 0..<32 { _ = try await store.add(draft(BackendGitHubRules.object([("label", .string("Agent \(index)"))]))) }
        let overflow = try await store.add(draft()), listed = await store.list()
        XCTAssertEqual(listed.elements?.count, 32); XCTAssertTrue(overflow["problems"]["label"].string?.contains("32 added agents") == true)
        let removed = try await store.remove("custom:agent-0"), absent = try await store.remove("custom:agent-0")
        XCTAssertTrue(removed); XCTAssertFalse(absent)
    }
    func testChannelSetHasNoBulkWrite() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try BackendCustomAgentsStore(dataDirectory: dir, lookup: { _ in "/fixture/bin" }), registry = NativeChannelRegistry()
        let names = try await BackendCustomAgentsChannels.register(registry: registry, ownerID: "fixture", store: store)
        XCTAssertEqual(names.sorted(), ["agents:add", "agents:list", "agents:remove"])
        let removed = try await registry.invoke("agents:remove", context: .init(caller: .nativeApp, ownerID: "fixture"), arguments: [.string("claude")]); XCTAssertEqual(removed, .bool(false))
    }
}
