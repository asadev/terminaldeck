import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct TAG0202FixtureCipher: BackendAccountVaultCipher {
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Data(("fixture:" + text).utf8) }
    func decrypt(_ blob: Data) throws -> String { String(decoding: blob.dropFirst(8), as: UTF8.self) }
}

@Suite("TAG 0.20.2 Commander regressions")
struct TAG0202Tests {
    func value(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendTaskValues.object(fields) }
    @Test func unrestrictedKeyAllowsProjectAndNestedAgentFolderButExplicitGrantsStayBounded() {
        let root = "/fixture/project"
        let all = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act, .alter], keyID: "k", folders: nil)
        #expect(BackendTAGProjectGrant.permits(root, caller: all, openProjects: [root], allowedFolders: [root]))
        #expect(BackendTAGProjectGrant.permits(root + "/.claude/agents", caller: all, openProjects: [root], allowedFolders: [root]))
        #expect(BackendTAGProjectGrant.permits("/another/project", caller: all, openProjects: [root], allowedFolders: [root]))
        let limited = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read], keyID: "k", folders: [root])
        #expect(BackendTAGProjectGrant.permits(root + "/.claude/agents", caller: limited, openProjects: [root], allowedFolders: [root]))
        #expect(!BackendTAGProjectGrant.permits(root + "-other/.claude/agents", caller: limited, openProjects: [root], allowedFolders: [root]))
        #expect(!BackendTAGProjectGrant.permits(root + "/../other", caller: limited, openProjects: [root], allowedFolders: [root]))
        let empty = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read], keyID: "k", folders: [])
        #expect(!BackendTAGProjectGrant.permits(root, caller: empty, openProjects: [root], allowedFolders: []))
    }
    @Test func keyFirstValuesAreOwnedPersistedAndOnlyThenNarrowed() async throws {
        let config = try BackendTaskConfiguration(persistence: .init(directory: URL(fileURLWithPath: "/TAG0202-memory"), ownership: .memory))
        try await config.start()
        let seed = value([("id", .string("created")), ("name", .string("Created")), ("provider", .string("claude"))])
        _ = try await config.saveAgentNarrowed(seed, callerKeyID: "creator")
        await #expect(throws: NativeRPCError.self) { try await config.saveAgentNarrowed(value([("id", .string("created")), ("keepAliveUntilClose", .bool(true))]), callerKeyID: "creator") }
        let first = try await config.saveAgentNarrowed(value([("id", .string("created")), ("keepAliveUntilClose", .bool(false)), ("keepAliveMinutes", .number(120)), ("permissionMode", .string("bypassPermissions"))]), callerKeyID: "creator")
        #expect(first["keepAliveUntilClose"].bool == false && first["keepAliveMinutes"].number == 120)
        let timed = try await config.saveAgentNarrowed(value([("id", .string("created")), ("keepAliveUntilClose", .bool(false)), ("keepAliveMinutes", .number(10)), ("permissionMode", .string("plan"))]), callerKeyID: "creator")
        #expect(timed["keepAliveMinutes"].number == 10)
        await #expect(throws: NativeRPCError.self) { try await config.saveAgentNarrowed(value([("id", .string("created")), ("keepAliveMinutes", .number(20))]), callerKeyID: "creator") }
        _ = try await config.saveAgentNarrowed(value([("id", .string("other-key")), ("name", .string("Other key")), ("provider", .string("claude"))]), callerKeyID: "creator")
        await #expect(throws: NativeRPCError.self) { try await config.saveAgentNarrowed(value([("id", .string("other-key")), ("keepAliveUntilClose", .bool(true))]), callerKeyID: "stranger") }
        _ = try await config.saveAgentNarrowed(value([("id", .string("other-key")), ("blockedTools", .array([.string("Edit")]))]), callerKeyID: "stranger")
        await #expect(throws: NativeRPCError.self) { try await config.saveAgentNarrowed(value([("id", .string("other-key")), ("blockedTools", .array([]))]), callerKeyID: "creator") }
        _ = try await config.saveAgent(seed.setting("id", .string("owner")).setting("name", .string("Owner")))
        await #expect(throws: NativeRPCError.self) { try await config.saveAgentNarrowed(value([("id", .string("owner")), ("keepAliveUntilClose", .bool(true))]), callerKeyID: "creator") }
    }
    @Test func ownerEditCannotLeaveAKeyFirstValueEscape() async throws {
        let config = try BackendTaskConfiguration(persistence: .init(directory: URL(fileURLWithPath: "/TAG0202-memory"), ownership: .memory))
        try await config.start()
        let seed = value([("id", .string("agent")), ("name", .string("Agent")), ("provider", .string("claude"))])
        _ = try await config.saveAgentNarrowed(seed, callerKeyID: "creator")
        let current = try #require(try await config.agent("agent"))
        _ = try await config.saveAgent(current.setting("blockedTools", .array([.string("Edit")])).setting("skillsOff", .bool(true)))
        await #expect(throws: NativeRPCError.self) { try await config.saveAgentNarrowed(value([("id", .string("agent")), ("blockedTools", .array([]))]), callerKeyID: "creator") }
        await #expect(throws: NativeRPCError.self) { try await config.saveAgentNarrowed(value([("id", .string("agent")), ("skillsOff", .bool(false))]), callerKeyID: "creator") }
    }
    @Test func keyFirstValuesWorkWithCanonicalAGSAndCannotForgeCreation() async throws {
        let persistence = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/TAG0202-ags-memory"), ownership: .memory)
        let config = try BackendTaskConfiguration(persistence: persistence)
        let ags = BackendAGSStore(persistence: persistence, cipher: TAG0202FixtureCipher())
        try await config.start(); try await ags.start(); try await config.bindAGS(ags)
        // AGOPT (10 Oct): keep-open is always a widening; a key asks the owner through the
        // grouped approval card instead of setting it directly (AGOPTProfileChangesTests).
        let wide = value([("id", .string("canonical")), ("name", .string("Canonical")), ("provider", .string("claude")), ("keepAliveUntilClose", .bool(true)), ("permissionMode", .string("bypassPermissions"))])
        await #expect(throws: NativeRPCError.self) { try await config.saveAgentNarrowed(wide, callerKeyID: "creator") }
        let seed = wide.removing("keepAliveUntilClose")
        let saved = try await config.saveAgentNarrowed(seed, callerKeyID: "creator")
        #expect(saved["keepAliveUntilClose"].bool != true)
        #expect(try await ags.profile("canonical")?.keepOpen != true)
        _ = try await config.saveAgentNarrowed(value([("id", .string("canonical")), ("permissionMode", .string("plan"))]), callerKeyID: "creator")
        await #expect(throws: NativeRPCError.self) { try await config.saveAgentNarrowed(value([("id", .string("canonical")), ("permissionMode", .string("bypassPermissions"))]), callerKeyID: "creator") }
        await #expect(throws: NativeRPCError.self) { try await config.saveAgentNarrowed(seed.setting("id", .string("forged")).setting("creatorKeyId", .string("creator")), callerKeyID: "creator") }
        try await config.stop()
    }
    @Test func importCarriesFrontmatterAndOptionsThenResyncPreservesLimits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TAG0202-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("project/.claude/agents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("inspector.md")
        let body = "---\nname: inspector\ndescription: Checks work\nmodel: opus\ntools: Read, Grep\ndefaultProject: /fixture/project\nmaxConcurrent: 3\nmaxRunMinutes: 90\nblockedTools:\n  - Edit\n---\nCheck the evidence.\n"
        try Data(body.utf8).write(to: file)
        let config = try BackendTaskConfiguration(persistence: .init(directory: root.appendingPathComponent("data"), ownership: .exclusive))
        try await config.start()
        let options = value([("maxConcurrent", .number(2)), ("agents", value([("inspector", value([("blockedTools", .array([.string("Edit"), .string("Write")]))]))]))])
        let result = try await config.importAgents(folder: root.appendingPathComponent("project").path, narrowOnly: true, callerKeyID: "creator", options: options)
        #expect(result["imported"].number == 1 && result["errors"].elements?.isEmpty == true)
        let row = try #require(try await config.agent("inspector"))
        #expect(row["maxConcurrent"].number == 2 && row["maxRunMinutes"].number == 90)
        #expect(row["defaultProject"].string == "/fixture/project")
        #expect(row["blockedTools"].elements == [.string("Edit"), .string("Write")])
        #expect(row["syncStatus"].string == "synced" && row["sourceFile"].string?.hasSuffix("inspector.md") == true)
        try await config.stop()
        try Data(body.replacingOccurrences(of: "Checks work", with: "Updated role").replacingOccurrences(of: "maxConcurrent: 3", with: "maxConcurrent: 5").utf8).write(to: file)
        let reloaded = try BackendTaskConfiguration(persistence: .init(directory: root.appendingPathComponent("data"), ownership: .exclusive))
        try await reloaded.start(); try await reloaded.startImportWatchers()
        let synced = try #require(try await reloaded.agent("inspector"))
        #expect(synced["role"].string == "Updated role" && synced["maxConcurrent"].number == 2)
        #expect(synced["blockedTools"].elements == [.string("Edit"), .string("Write")])
        try await reloaded.stop()
    }
}
