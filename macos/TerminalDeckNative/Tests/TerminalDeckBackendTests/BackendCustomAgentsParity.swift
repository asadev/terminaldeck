import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class BackendCustomAgentsParity: XCTestCase {
    private func draft(_ patch: NativeRPCValue = .object([])) -> NativeRPCValue { BackendGitHubParityObject([("label", .string("Grok")), ("description", .string("Grok from the command line.")), ("command", .string("grok")), ("args", .string("")), ("resumeArgs", .string(""))]).merging(patch) }
    private func store(_ dir: URL, commands: Set<String> = ["grok"]) throws -> BackendCustomAgentsStore { try BackendCustomAgentsStore(dataDirectory: dir, lookup: { command in commands.contains(command) ? "/usr/local/bin/" + command : nil }) }
    func testMissingCommandNeverWritesAndResolvedEvidenceIsStored() async throws {
        let dir = try BackendGitHubParityDirectory("agents-add"); defer { try? FileManager.default.removeItem(at: dir) }
        let missing = try store(dir, commands: []), refused = try await missing.add(draft()), empty = await missing.list()
        XCTAssertEqual(refused["ok"].bool, false); XCTAssertTrue(refused["problems"]["command"].string!.contains("grok")); XCTAssertEqual(refused["problems"]["label"], .missing); XCTAssertEqual(empty, .array([])); XCTAssertFalse(FileManager.default.fileExists(atPath: missing.file.path))
        let available = try store(dir), result = try await available.add(draft())
        XCTAssertEqual(result["ok"].bool, true); XCTAssertEqual(result["agent"]["resolvedPath"].string, "/usr/local/bin/grok"); XCTAssertTrue(BackendCustomAgentsRules.isCustom(result["agent"]["id"].string)); XCTAssertEqual(result["agent"]["id"].string, "custom:grok")
    }
    func testQuotedArgsBuiltinAndCustomDuplicateAndCommandLineRefusal() async throws {
        let dir = try BackendGitHubParityDirectory("agents-validation"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try self.store(dir, commands: ["grok", "amp", "grok --yes"])
        let builtin = try await store.add(draft(BackendGitHubParityObject([("label", .string("Claude Code"))])))
        XCTAssertEqual(builtin["ok"].bool, false); XCTAssertTrue(builtin["problems"]["label"].string!.contains("Claude Code")); XCTAssertTrue(CodingAICatalog.all.map(\.label).contains("Claude Code"))
        let result = try await store.add(draft(BackendGitHubParityObject([("args", .string(#"--model fast --system-prompt "answer in French""#))])))
        XCTAssertEqual(result["agent"]["args"], .array([.string("--model"), .string("fast"), .string("--system-prompt"), .string("answer in French")]))
        let duplicate = try await store.add(draft(BackendGitHubParityObject([("command", .string("amp"))])))
        XCTAssertEqual(duplicate["ok"].bool, false); XCTAssertNotEqual(duplicate["problems"]["label"], .missing)
        let lineDir = try BackendGitHubParityDirectory("command-line"); defer { try? FileManager.default.removeItem(at: lineDir) }
        let commandLine = try self.store(lineDir, commands: ["grok --yes"]), bad = try await commandLine.add(draft(BackendGitHubParityObject([("command", .string("grok --yes"))])))
        XCTAssertEqual(bad["ok"].bool, false); XCTAssertTrue(bad["problems"]["command"].string!.contains("Just the program"))
    }
    func testThirtyTwoAgentCap() async throws {
        let dir = try BackendGitHubParityDirectory("agents-cap"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try BackendCustomAgentsStore(dataDirectory: dir, lookup: { _ in "/usr/local/bin/x" })
        for index in 0..<32 {
            let result = try await store.add(draft(BackendGitHubParityObject([("label", .string("Agent \(index)")), ("command", .string("agent\(index)"))])))
            XCTAssertEqual(result["ok"].bool, true)
        }
        let overflow = try await store.add(draft(BackendGitHubParityObject([("label", .string("One too many")), ("command", .string("extra"))]))), rows = await store.list()
        XCTAssertEqual(overflow["ok"].bool, false); XCTAssertEqual(rows.elements?.count, 32)
    }
    func testPortableWindowsPathAndArgumentGrammarUsingFakeLookup() async throws {
        let dir = try BackendGitHubParityDirectory("portable-grammar"); defer { try? FileManager.default.removeItem(at: dir) }
        let path = #"C:\tools\agent.exe"#, store = try BackendCustomAgentsStore(dataDirectory: dir, lookup: { $0 })
        let result = try await store.add(draft(BackendGitHubParityObject([("command", .string(path)), ("args", .string(#"--config C:\tools\agent.json"#))])))
        XCTAssertEqual(result["ok"].bool, true); XCTAssertEqual(result["agent"]["command"].string, path); XCTAssertEqual(result["agent"]["args"], .array([.string("--config"), .string(#"C:\tools\agent.json"#)]))
        let unicodePath = #"C:\tools\é.exe"#
        let unicode = try await store.add(draft(BackendGitHubParityObject([("label", .string("Unicode path")), ("command", .string(unicodePath))])))
        XCTAssertEqual(unicode["ok"].bool, true); XCTAssertEqual(unicode["agent"]["command"].string, unicodePath)
    }
    func testUncRelativeAndCommandProcessorInstructionsStillRefused() async throws {
        let dir = try BackendGitHubParityDirectory("portable-refusals"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try BackendCustomAgentsStore(dataDirectory: dir, lookup: { _ in #"C:\anything"# })
        let unc = try await store.add(draft(BackendGitHubParityObject([("command", .string(#"\\server\share\agent.exe"#))])))
        XCTAssertEqual(unc["ok"].bool, false); XCTAssertTrue(unc["problems"]["command"].string!.contains("neither a plain command name"))
        for command in [#"tools\agent.exe"#, #"..\agent.exe"#, "tools/agent"] {
            let result = try await store.add(draft(BackendGitHubParityObject([("command", .string(command))])))
            XCTAssertEqual(result["ok"].bool, false); XCTAssertNotEqual(result["problems"]["command"], .missing)
        }
        for command in ["ſerver", "K-agent", #"K:\tools\agent.exe"#] {
            let result = try await store.add(draft(BackendGitHubParityObject([("command", .string(command))])))
            XCTAssertEqual(result["ok"].bool, false); XCTAssertTrue(result["problems"]["command"].string!.contains("neither a plain command name"))
        }
        for command in [#"C:\tools\agent.exe&del"#, #"C:\tools\agent.exe|more"#, #"C:\tools\%USERNAME%.exe"#, #"C:\tools\agent^.exe"#, #"C:\tools\(agent).exe"#] {
            let result = try await store.add(draft(BackendGitHubParityObject([("command", .string(command))])))
            XCTAssertEqual(result["ok"].bool, false); XCTAssertTrue(result["problems"]["command"].string!.contains("Just the program"))
        }
    }
    func testPosixExecutablePresenceUsesOnlyOwnedFixtureFiles() async throws {
        let dir = try BackendGitHubParityDirectory("executable-fixture"); defer { try? FileManager.default.removeItem(at: dir) }
        let runnable = dir.appendingPathComponent("agent"), plain = dir.appendingPathComponent("plain")
        try Data().write(to: runnable); try Data().write(to: plain)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runnable.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plain.path)
        let lookup = BackendCustomAgentsStore.nativeLookup(loginPath: { dir.path })
        let found = try await lookup(runnable.path), denied = try await lookup(plain.path)
        XCTAssertEqual(found, runnable.path); XCTAssertNil(denied)
        // No CLI or shell is launched. The files are staging fixtures with an
        // execute bit, not probes of an installed agent on this machine.
    }
    func testRestartDoesNotReprobeAndBadDiskRowIsDroppedAlone() async throws {
        let dir = try BackendGitHubParityDirectory("agents-disk"); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try store(dir); _ = try await first.add(draft())
        let second = try store(dir, commands: []), restored = await second.list()
        XCTAssertEqual(restored.elements?.map { $0["label"].string }, ["Grok"]); XCTAssertEqual(restored.elements?.first?["command"].string, "grok")
        let disk = try NativeRPCValue.parseJSON(Data(contentsOf: first.file))
        let bad = try BackendGitHubParityJSON(#"{"id":"custom:evil","label":"Evil","description":"","command":"rm -rf ~ & echo","args":[],"resumeArgs":[],"addedAt":1,"resolvedPath":"/bin/sh"}"#)
        try disk.setting("agents", .array((disk["agents"].elements ?? []) + [bad])).encodedJSON().write(to: first.file)
        let reopened = try store(dir, commands: []), valid = await reopened.list()
        XCTAssertEqual(valid.elements?.map { $0["id"].string }, ["custom:grok"])
    }
    func testUnreadableFileIsEmptyAndRemovalTouchesOnlyRequestedRow() async throws {
        let brokenDir = try BackendGitHubParityDirectory("agents-corrupt"); defer { try? FileManager.default.removeItem(at: brokenDir) }
        try Data("{ not json".utf8).write(to: brokenDir.appendingPathComponent("custom-agents.json"))
        let broken = try store(brokenDir), empty = await broken.list(); XCTAssertEqual(empty, .array([]))
        let dir = try BackendGitHubParityDirectory("agents-remove"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try self.store(dir, commands: ["grok", "amp"])
        _ = try await store.add(draft()); _ = try await store.add(draft(BackendGitHubParityObject([("label", .string("Amp")), ("command", .string("amp"))])))
        let removed = try await store.remove("custom:grok"), absent = try await store.remove("custom:grok"), rows = await store.list()
        XCTAssertTrue(removed); XCTAssertFalse(absent); XCTAssertEqual(rows.elements?.map { $0["id"].string }, ["custom:amp"])
        let reopened = try self.store(dir, commands: []), persisted = await reopened.list(); XCTAssertEqual(persisted.elements?.map { $0["id"].string }, ["custom:amp"])
    }
    func testCatalogueWithdrawsEveryUnmeasuredFeatureWithEvidence() async throws {
        let dir = try BackendGitHubParityDirectory("agents-entry"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try self.store(dir), result = try await store.add(draft()), entry = BackendCustomAgentsRules.entry(result["agent"])
        for key in ["statusArgs", "statusFormat", "signInArgs", "configEnv", "credentialFile", "versionArgs", "install", "url"] { XCTAssertEqual(entry[key], .null) }
        XCTAssertEqual(entry["logins"].string, "unmeasured"); XCTAssertNotEqual(entry["loginsNote"], .null); XCTAssertTrue(entry["verified"].string!.contains("/usr/local/bin/grok"))
    }
    func testNativeLauncherReadsSameAgentAndNoResumeStaysEmpty() async throws {
        let dir = try BackendGitHubParityDirectory("agents-launch"); defer { try? FileManager.default.removeItem(at: dir) }
        let fakeBinary = dir.appendingPathComponent("grok")
        try Data().write(to: fakeBinary); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeBinary.path)
        let store = try BackendCustomAgentsStore(dataDirectory: dir, lookup: { _ in fakeBinary.path })
        let added = try await store.add(draft(BackendGitHubParityObject([("args", .string("--fast")), ("resumeArgs", .string("--continue"))])))
        let providers = try BackendNativeProviders(store: NativeStateStore(), dataRoot: dir, inheritedEnvironment: [:], home: dir.path, runner: BackendCommandRunner())
        let input = BackendCreateSessionInput(cwd: dir.path, provider: added["agent"]["id"].string)
        let spec = try await providers.resolve(input, loginPath: dir.path)
        XCTAssertEqual(spec.command, fakeBinary.path); XCTAssertEqual(spec.args, ["--fast"]); XCTAssertEqual(spec.resumeArgs, ["--continue"])
        let emptyDir = try BackendGitHubParityDirectory("no-resume"); defer { try? FileManager.default.removeItem(at: emptyDir) }
        let noResumeStore = try self.store(emptyDir), outcome = try await noResumeStore.add(draft()), entry = BackendCustomAgentsRules.entry(outcome["agent"])
        XCTAssertEqual(entry["resumeArgs"], .array([]))
        let noResumeProviders = try BackendNativeProviders(store: NativeStateStore(), dataRoot: emptyDir, inheritedEnvironment: [:], home: emptyDir.path, runner: BackendCommandRunner())
        let noResume = try await noResumeProviders.resolve(BackendCreateSessionInput(cwd: emptyDir.path, provider: outcome["agent"]["id"].string), loginPath: dir.path)
        XCTAssertEqual(noResume.resumeArgs, [])
    }
    func testExactThreeChannelsNoBulkWriteAndRemoveRejectsBuiltinOrNumber() async throws {
        let dir = try BackendGitHubParityDirectory("agents-ipc"); defer { try? FileManager.default.removeItem(at: dir) }
        let registry = NativeChannelRegistry(), store = try self.store(dir), names = try await BackendCustomAgentsChannels.register(registry: registry, ownerID: "fixture", store: store)
        XCTAssertEqual(names.sorted(), ["agents:add", "agents:list", "agents:remove"])
        let added = try await registry.invoke("agents:add", context: .init(caller: .nativeApp, ownerID: "fixture"), arguments: [draft()]); XCTAssertEqual(added["ok"].bool, true)
        let rows = try await registry.invoke("agents:list", context: .init(caller: .nativeApp, ownerID: "fixture"), arguments: []); XCTAssertEqual(rows.elements?.count, 1)
        for value in [NativeRPCValue.string("claude"), .number(42)] {
            let removed = try await registry.invoke("agents:remove", context: .init(caller: .nativeApp, ownerID: "fixture"), arguments: [value]); XCTAssertEqual(removed, .bool(false))
        }
        let removed = try await registry.invoke("agents:remove", context: .init(caller: .nativeApp, ownerID: "fixture"), arguments: [.string("custom:grok")]); XCTAssertEqual(removed, .bool(true))
    }
}
