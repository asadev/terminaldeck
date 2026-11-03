import Foundation
import Testing
import TerminalDeckNativeCore

@Suite("Foundation: transcript paths, stores and renderer read boundary")
struct BackendFoundationTestsTranscriptsPaths {
    let project = "/Users/apple/ClaudeAsad", copilot = "/fake/user-data/copilot", other = "/fake/someone-else"
    private func scope(_ scratch: BackendFoundationTestsSessionsScratch, devices: [String: [String]] = [:], scoped: Bool = false) throws -> NativeTranscriptScope {
        for (device, projects) in devices {
            try FileManager.default.createDirectory(at: scratch.root.appendingPathComponent("homes/" + device + "/tmp"), withIntermediateDirectories: true)
            for cwd in projects { try FileManager.default.createDirectory(at: scratch.root.appendingPathComponent("homes/" + device + "/.claude/projects/" + NativeTranscriptPaths.encodeProjectPath(cwd)), withIntermediateDirectories: true) }
        }
        return NativeTranscriptScope(configDirectory: scratch.root.appendingPathComponent("config").path, deviceHomesRoot: scratch.root.appendingPathComponent("homes").path,
            homeScopes: scoped ? [.init(home: scratch.root.appendingPathComponent("homes/copilot").path, folder: copilot)] : [])
    }
    // TS transcript.test.ts:56
    @Test func symlinkedFolderLookedUpUnderBothSpellings() throws {
        let s = try BackendFoundationTestsSessionsScratch(), real = s.root.appendingPathComponent("real-project"), link = s.root.appendingPathComponent("linked-project")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let spellings = NativeTranscriptPaths.projectSpellings(link.path), config = s.root.appendingPathComponent("config").path
        #expect(spellings.first == link.path); #expect(spellings.contains(NativeTranscriptPaths.canonical(real.path)))
        let dirs = try NativeTranscriptPaths.projectDirectories(link.path, scope: .init(configDirectory: config))
        #expect(dirs.contains(config + "/projects/" + NativeTranscriptPaths.encodeProjectPath(link.path)))
        #expect(dirs.contains(config + "/projects/" + NativeTranscriptPaths.encodeProjectPath(NativeTranscriptPaths.canonical(real.path))))
    }
    // TS transcript.test.ts:75
    @Test func ordinaryDirectoriesDeduplicatedAndMissingFolderSafe() throws {
        let s = try BackendFoundationTestsSessionsScratch(), dirs = try NativeTranscriptPaths.projectDirectories(s.root.path, scope: .init(configDirectory: s.root.appendingPathComponent("config").path))
        #expect(Set(dirs).count == dirs.count)
        _ = NativeTranscriptPaths.projectSpellings(s.root.appendingPathComponent("not/created/yet").path)
        #expect(NativeTranscriptPaths.projectSpellings(s.root.appendingPathComponent("nope").path).count == 1)
    }
    // TS transcript.test.ts:94
    @Test func separatorsEncodedAsHyphens() {
        #expect(NativeTranscriptPaths.encodeProjectPath("/Users/apple/ClaudeAsad") == "-Users-apple-ClaudeAsad")
        #expect(NativeTranscriptPaths.encodeProjectPath("/Users/apple/Projects/terminaldeck") == "-Users-apple-Projects-terminaldeck")
    }
    // TS transcript.test.ts:99
    @Test func dotDirectoryEncodedAsDoubleHyphen() { #expect(NativeTranscriptPaths.encodeProjectPath("/Users/apple/ClaudeKiwi/.claude/worktrees/focused-lumiere-5424d6") == "-Users-apple-ClaudeKiwi--claude-worktrees-focused-lumiere-5424d6") }
    // TS transcript.test.ts:105
    @Test func allNonAlphanumericsRewritten() { #expect(NativeTranscriptPaths.encodeProjectPath("/Users/apple/Library/Mobile Documents/com~apple~CloudDocs/OpenClaw/workspace") == "-Users-apple-Library-Mobile-Documents-com-apple-CloudDocs-OpenClaw-workspace") }
    // TS transcript.test.ts:131
    @Test func trailingSeparatorNormalized() { #expect(NativeTranscriptPaths.encodeProjectPath("/Users/apple/ClaudeAsad/") == NativeTranscriptPaths.encodeProjectPath("/Users/apple/ClaudeAsad")) }
    // TS transcript.test.ts:137
    @Test func lossyPathEncodingCannotBeDecoded() { #expect(NativeTranscriptPaths.encodeProjectPath("/a/b") == NativeTranscriptPaths.encodeProjectPath("/a.b")) }
    // TS transcript.test.ts:159
    @Test func transcriptDirectoryUnderConfigProjects() throws { #expect(try NativeTranscriptPaths.projectDirectories(project, scope: .init(configDirectory: "/tmp/cfg")) == ["/tmp/cfg/projects/-Users-apple-ClaudeAsad"]) }
    // TS transcript.test.ts:165
    @Test func deliberateConfigOverrideHonored() throws {
        let scope = NativeTranscriptScope.environment(["HOME": "/fixture/home", "CLAUDE_CONFIG_DIR": "/tmp/work-profile"])
        #expect(scope.configDirectory == "/tmp/work-profile"); #expect(try NativeTranscriptPaths.projectDirectories(project, scope: scope) == ["/tmp/work-profile/projects/-Users-apple-ClaudeAsad"])
    }
    // TS transcript.test.ts:171
    @Test func blankConfigOverrideIgnored() { #expect(NativeTranscriptScope.environment(["HOME": "/fixture/home", "CLAUDE_CONFIG_DIR": "   "]).configDirectory.hasSuffix(".claude")) }
    // TS transcript.test.ts:218
    @Test func profileOnlyWhenNoDevices() throws {
        let scope = NativeTranscriptScope(configDirectory: "/tmp/cfg")
        #expect(try NativeTranscriptPaths.configDirectories(scope) == ["/tmp/cfg"])
        #expect(try NativeTranscriptPaths.projectDirectories(project, scope: scope) == ["/tmp/cfg/projects/-Users-apple-ClaudeAsad"])
    }
    // TS transcript.test.ts:227
    @Test func eachDeviceAddsStoreAfterProfile() throws {
        let s = try BackendFoundationTestsSessionsScratch(), scoped = try scope(s, devices: ["dev-a": [project], "dev-b": [project]]), dirs = try NativeTranscriptPaths.configDirectories(scoped)
        #expect(dirs.first == scoped.configDirectory)
        #expect(Array(dirs.dropFirst()).sorted() == [s.root.appendingPathComponent("homes/dev-a/.claude").path, s.root.appendingPathComponent("homes/dev-b/.claude").path].sorted())
    }
    // TS transcript.test.ts:238
    @Test func freshDeviceWithoutAgentStoreIgnored() throws {
        let s = try BackendFoundationTestsSessionsScratch(), scoped = try scope(s, devices: ["dev-a": [project], "dev-fresh": []])
        #expect(try NativeTranscriptPaths.configDirectories(scoped) == [scoped.configDirectory, s.root.appendingPathComponent("homes/dev-a/.claude").path])
    }
    // TS transcript.test.ts:248
    @Test func missingDeviceHomesRootSafe() throws {
        let s = try BackendFoundationTestsSessionsScratch(), scoped = NativeTranscriptScope(configDirectory: "/tmp/cfg", deviceHomesRoot: s.root.appendingPathComponent("never-made").path)
        #expect(try NativeTranscriptPaths.configDirectories(scoped) == ["/tmp/cfg"])
    }
    // TS transcript.test.ts:256
    @Test func newlyPairedDeviceSeenOnNextRead() throws {
        let s = try BackendFoundationTestsSessionsScratch(), scoped = try scope(s)
        #expect(try NativeTranscriptPaths.configDirectories(scoped) == [scoped.configDirectory])
        try FileManager.default.createDirectory(at: s.root.appendingPathComponent("homes/dev-new/.claude/projects"), withIntermediateDirectories: true)
        #expect(try NativeTranscriptPaths.configDirectories(scoped) == [scoped.configDirectory, s.root.appendingPathComponent("homes/dev-new/.claude").path])
    }
    // TS transcript.test.ts:271
    @Test func sameProjectEncodingInEveryStore() throws {
        let s = try BackendFoundationTestsSessionsScratch(), scoped = try scope(s, devices: ["dev-a": [project]]), dirs = try NativeTranscriptPaths.projectDirectories(project, scope: scoped)
        #expect(dirs.allSatisfy { $0.hasSuffix("-Users-apple-ClaudeAsad") }); #expect(dirs.count == 2)
    }
    // TS transcript.test.ts:295
    @Test func scopedHomeOnlyAnswersForOwnFolder() throws {
        let s = try BackendFoundationTestsSessionsScratch(), scoped = try scope(s, devices: ["copilot": [copilot, other], "dev-a": [other]], scoped: true)
        #expect(try NativeTranscriptPaths.projectDirectories(copilot, scope: scoped).contains(s.root.appendingPathComponent("homes/copilot/.claude/projects/-fake-user-data-copilot").path))
        #expect(try !NativeTranscriptPaths.projectDirectories(other, scope: scoped).contains(s.root.appendingPathComponent("homes/copilot/.claude/projects/-fake-someone-else").path))
    }
    // TS transcript.test.ts:313
    @Test func unscopedDeviceStillAnswersForEveryFolder() throws {
        let s = try BackendFoundationTestsSessionsScratch(), scoped = try scope(s, devices: ["copilot": [other], "dev-a": [other]], scoped: true), dirs = try NativeTranscriptPaths.projectDirectories(other, scope: scoped)
        #expect(dirs.contains(s.root.appendingPathComponent("homes/dev-a/.claude/projects/-fake-someone-else").path)); #expect(dirs.contains(scoped.configDirectory + "/projects/-fake-someone-else"))
    }
    // TS transcript.test.ts:327
    @Test func emptyScopeChangesNothing() throws {
        let s = try BackendFoundationTestsSessionsScratch(), scoped = try scope(s, devices: ["dev-a": [project]])
        #expect(try NativeTranscriptPaths.projectDirectories(project, scope: scoped) == NativeTranscriptPaths.projectDirectories(project, scope: .init(configDirectory: scoped.configDirectory, deviceHomesRoot: scoped.deviceHomesRoot, homeScopes: [])))
    }
    // TS transcript.test.ts:347
    @Test func trailingSeparatorDoesNotWidenHomeScope() throws {
        let s = try BackendFoundationTestsSessionsScratch(), original = try scope(s, devices: ["copilot": [copilot, other]])
        let scoped = NativeTranscriptScope(configDirectory: original.configDirectory, deviceHomesRoot: original.deviceHomesRoot, homeScopes: [.init(home: s.root.appendingPathComponent("homes/copilot").path + "/", folder: copilot + "/")])
        #expect(try NativeTranscriptPaths.projectDirectories(other, scope: scoped).count == 1); #expect(try NativeTranscriptPaths.projectDirectories(copilot, scope: scoped).count == 2)
    }
    // TS transcript.test.ts:398
    @Test func profileTranscriptApproved() throws { #expect(try NativeTranscriptPaths.assertTranscript("/tmp/cfg/projects/enc/sess.jsonl", scope: .init(configDirectory: "/tmp/cfg")) == NativeTranscriptPaths.canonical("/tmp/cfg/projects/enc/sess.jsonl")) }
    // TS transcript.test.ts:402
    @Test func confinedDeviceTranscriptApproved() throws {
        let s = try BackendFoundationTestsSessionsScratch(), scoped = try scope(s, devices: ["dev-a": [project]]), path = s.root.appendingPathComponent("homes/dev-a/.claude/projects/enc/sess.jsonl").path
        #expect(try NativeTranscriptPaths.assertTranscript(path, scope: scoped) == NativeTranscriptPaths.canonical(path))
    }
    // TS transcript.test.ts:411
    @Test func subagentTranscriptApproved() throws { #expect(try NativeTranscriptPaths.assertTranscript("/tmp/cfg/projects/enc/sub/sess.jsonl", scope: .init(configDirectory: "/tmp/cfg")) == NativeTranscriptPaths.canonical("/tmp/cfg/projects/enc/sub/sess.jsonl")) }
    // TS transcript.test.ts:430
    @Test func bothNamesForSharedStoreApprovedButSiblingRefused() throws {
        let s = try BackendFoundationTestsSessionsScratch(), root = s.root.resolvingSymlinksInPath(), shared = root.appendingPathComponent("own-install/projects"), config = root.appendingPathComponent("account")
        try FileManager.default.createDirectory(at: shared.appendingPathComponent("enc"), withIntermediateDirectories: true); try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: config.appendingPathComponent("projects"), withDestinationURL: shared)
        let real = shared.appendingPathComponent("enc/sess.jsonl"); try Data("{}\n".utf8).write(to: real)
        let built = config.appendingPathComponent("projects/enc/sess.jsonl"), scoped = NativeTranscriptScope(configDirectory: config.path)
        #expect(try NativeTranscriptPaths.assertTranscript(built.path, scope: scoped) == real.path); #expect(try NativeTranscriptPaths.assertTranscript(real.path, scope: scoped) == real.path)
        #expect(throws: NativeTranscriptPaths.Failure.self) { try NativeTranscriptPaths.assertTranscript(root.appendingPathComponent("own-install/projects-elsewhere/sess.jsonl").path, scope: scoped) }
    }
    // TS transcript.test.ts:459
    @Test func everyOutsideSpellingRefused() {
        for path in ["", "/tmp/cfg/projects", "/tmp/cfg-elsewhere/projects/enc/x.jsonl", "/tmp/cfg/projects/../../secrets.jsonl", "/tmp/cfg/projects/enc/sess.txt", "/tmp/cfg/settings.json"] {
            #expect(throws: NativeTranscriptPaths.Failure.self) { try NativeTranscriptPaths.assertTranscript(path, scope: .init(configDirectory: "/tmp/cfg")) }
        }
    }
    // TS transcript.test.ts:473
    @Test func similarlyNamedForeignDeviceHomeRefused() throws {
        let s = try BackendFoundationTestsSessionsScratch(), scoped = try scope(s, devices: ["dev-a": [project]])
        #expect(throws: NativeTranscriptPaths.Failure.self) { try NativeTranscriptPaths.assertTranscript(s.root.appendingPathComponent("not-ours/.claude/projects/enc/x.jsonl").path, scope: scoped) }
    }
    // TS transcript.test.ts:972 — deterministic file dates replace the TS real sleeps.
    @Test func creationTimeDiffersFromLatestWrite() throws {
        let s = try BackendFoundationTestsSessionsScratch(), config = s.root.appendingPathComponent("cfg"), dir = config.appendingPathComponent("projects/enc")
        let older = try s.write("cfg/projects/enc/older.jsonl", "{}\n"), newer = try s.write("cfg/projects/enc/newer.jsonl", "{}\n")
        let at = 1700000000.0
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: at - 120), .modificationDate: Date(timeIntervalSince1970: at)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: at - 60), .modificationDate: Date(timeIntervalSince1970: at - 30)], ofItemAtPath: newer.path)
        let files = try NativeTranscriptPaths.listTranscripts(dir.path, scope: .init(configDirectory: config.path))
        let a = try #require(files.first { $0.sessionID == "older" }), b = try #require(files.first { $0.sessionID == "newer" })
        #expect(files.first?.sessionID == "older"); #expect(a.modifiedAt > b.modifiedAt); #expect(a.createdAt < b.createdAt); #expect(a.createdAt <= a.modifiedAt)
    }
    // TS transcript.test.ts:994
    @Test func birthNeverAfterLatestWrite() throws {
        let s = try BackendFoundationTestsSessionsScratch(), config = s.root.appendingPathComponent("cfg")
        _ = try s.write("cfg/projects/enc/a.jsonl", "{}\n")
        let files = try NativeTranscriptPaths.listTranscripts(config.appendingPathComponent("projects/enc").path, scope: .init(configDirectory: config.path)), file = try #require(files.first)
        #expect(file.createdAt > 0); #expect(file.createdAt <= file.modifiedAt)
    }
}
