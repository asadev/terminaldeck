import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendDockerMCPServerAliasChannels: BackendDeckToolsMachinesChannels {
    var added: NativeRPCValue?
    var keyReads = 0
    var calls: [String] = []
    func call(_ channel: String, _ arguments: [NativeRPCValue], context: BackendDeckToolsMachinesContext) async throws -> NativeRPCValue {
        calls.append(channel)
        if channel == "servers:key-read" { keyReads += 1 }
        switch channel {
        case "servers:keys": return .array([.object([.init("name", .string("id_ed25519")), .init("path", .string("/synthetic/home/.ssh/id_ed25519"))])])
        case "servers:key-read":
            guard arguments == [.string("/synthetic/home/.ssh/id_ed25519")] else { throw CancellationError() }
            return .object([.init("ok", .bool(true)), .init("key", .string("synthetic-approved-key"))])
        case "servers:add": added = arguments.first; return .object([.init("ok", .bool(true)), .init("id", .string("one")), .init("savedSignIn", .bool(false))])
        case "servers:list": return .array([.object([.init("id", .string("one")), .init("name", .string("iMatch"))])])
        default: throw CancellationError()
        }
    }
}
private actor BackendDockerMCPServerAliasShells: BackendDeckToolsMachinesServerShells {
    var screens = 0
    func openShells() async throws -> [NativeRPCValue] {
        ["one", "hidden"].map { .object([.init("serverId", .string($0)), .init("shellId", .string($0 + "-shell"))]) }
    }
    func shellScreen(_ shellID: String) async throws -> String? { screens += 1; return "PRIVATE SERVER OUTPUT" }
}
@Suite("SSH alias enters the existing approved add and server scope paths")
struct BackendDockerMCPServerAliasAdapterTests {
    private func context(key: Bool = false) -> BackendDeckToolsMachinesContext {
        .init(kind: key ? .key : .local, attended: true, keyID: key ? "ClaudeiMatch" : nil,
              rpc: .init(caller: .internalEngine, ownerID: "synthetic"), startedByCopilot: { _ in false }, noteStarted: { _ in })
    }
    private func adapter(channels: BackendDockerMCPServerAliasChannels, shells: BackendDockerMCPServerAliasShells = .init()) -> BackendDeckToolsMachinesServers {
        .init(channels: channels, shells: shells, dataRoot: URL(fileURLWithPath: "/synthetic/data"), home: URL(fileURLWithPath: "/synthetic/home"),
              sshConfig: .init(evaluate: { _ in .init(code: 0, stdout: "hostname 100.86.183.128\nuser admin\nport 22\nidentityfile ~/.ssh/id_ed25519\n") }), serverAccessEnabled: true)
    }
    @Test func aliasAddsWithTheOwnSSHSettingsAndNeverReadsOrCopiesAKey() async throws {
        let channels = BackendDockerMCPServerAliasChannels(), adapter = adapter(channels: channels)
        let output = try await adapter.run("servers.manage", .object([.init("do", .string("add")), .init("sshAlias", .string("imza-server"))]), context())
        let draft = try #require(await channels.added)
        #expect(draft["method"].string == "ssh-config" && draft["sshAlias"].string == "imza-server")
        #expect(draft["lookOnly"].bool == true, "an alias add defaults to Look only")
        #expect(draft["key"] == .missing && draft["address"] == .missing && draft["password"] == .missing)
        let keyReads = await channels.keyReads, calls = await channels.calls
        #expect(keyReads == 0 && !calls.contains("servers:keys"))
        #expect(!output.value.compact.contains("synthetic-approved-key"))
    }
    @Test func aliasAddRefusesConnectionFieldsAndKeyPaths() async throws {
        let channels = BackendDockerMCPServerAliasChannels(), adapter = adapter(channels: channels)
        let tool = try BackendMCPTool(id: "servers.manage", wireName: "servers_manage", description: "Fixture", inputSchema: .object([]), tier: .alter)
        for extra in ["keyPath", "address", "password"] {
            await #expect(throws: (any Error).self) {
                _ = try await adapter.policy(tool, .object([.init("do", .string("add")), .init("sshAlias", .string("imza-server")), .init(extra, .string("x"))]), context())
            }
        }
        #expect(await channels.added == nil)
    }
    @Test func schemaAdvertisesSSHConfigAlias() throws {
        let row = try #require(try BackendDeckToolsMachinesCatalogue.rows(includeServerAliases: true).first { $0["id"].string == "servers.manage" })
        #expect(row["inputSchema"]["properties"]["sshAlias"]["type"].string == "string")
    }
    @Test func addingAServerRequiresOwnerAnswerEvenForAFullStandingKey() async throws {
        let channels = BackendDockerMCPServerAliasChannels(), adapter = adapter(channels: channels)
        let tool = try BackendMCPTool(id: "servers.manage", wireName: "servers_manage", description: "Fixture", inputSchema: .object([]), tier: .alter)
        let policy = try await adapter.policy(tool, .object([.init("do", .string("add")), .init("sshAlias", .string("imza-server"))]), context(key: true))
        #expect(policy.ownerMustAnswer)
        #expect(await channels.added == nil)
    }
    @Test func shellListsExcludeUnallowedServersAndHiddenScreensAreNeverRead() async throws {
        let channels = BackendDockerMCPServerAliasChannels(), shells = BackendDockerMCPServerAliasShells()
        let adapter = adapter(channels: channels, shells: shells)
        let output = try await adapter.run("servers.details", .object([.init("about", .string("shells"))]), context(key: true))
        #expect(output.value["shells"].elements?.count == 1)
        do {
            _ = try await adapter.run("servers.details", .object([.init("about", .string("shell")), .init("shellId", .string("hidden-shell"))]), context(key: true))
            Issue.record("An unallowed server screen was returned")
        } catch let error as BackendDeckCoreSecurityRefusal {
            #expect(error.reason == .notPermitted)
            #expect(error.message.localizedCaseInsensitiveContains("not allowed on this server"))
        }
        #expect(await shells.screens == 0)
    }
}
