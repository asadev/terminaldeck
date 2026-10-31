import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Saved server access is independent of a full key tier")
struct BackendDockerMCPServerKeyScopeTests {
    @Test func savedScopeSurvivesStoreParsingAndLegacyServersDefaultToNoKeys() {
        let rows = BackendServersStore.readServers(.object([.init("servers", .array([
            .object([.init("id", .string("imatch")), .init("address", .string("100.86.183.128")),
                .init("username", .string("admin")), .init("aiKeyIDs", .array([.string("ClaudeiMatch")]))]),
            .object([.init("id", .string("legacy")), .init("address", .string("legacy.example"))])
        ]))]))
        // The public row shape stays the legacy eleven fields; the grant lives on the record.
        #expect(rows.first?.aiKeyIDs == ["ClaudeiMatch"])
        #expect((rows.last?.aiKeyIDs ?? []) == [])
        #expect(rows.first?.wireValue["aiKeyIDs"] == .missing)
    }

    @Test func creatorOnlyAndOwnerChangesPersistWithImmediateRevocation() throws {
        let root = BackendServersS4RealTemp.directory().appendingPathComponent("server-key-scope-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true))
        let added = try store.add(.init(name: "iMatch", address: "100.86.183.128", username: "admin"), creatorKeyID: "ClaudeiMatch")
        let commander = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act, .alter], keyID: "ClaudeiMatch")
        let dot = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act, .alter], keyID: "Dot")
        #expect(BackendDockerMCPServerKeyScope.allows(commander, server: added))
        #expect(!BackendDockerMCPServerKeyScope.allows(dot, server: added))
        #expect(throws: NativeRPCError.self) { try BackendDockerMCPServerKeyScope.check(dot, server: added) }
        #expect(try store.setAIKeyAccess(added.id, keyIDs: ["Dot"]))
        let reloaded = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true))
        let changed = try #require(try reloaded.get(added.id))
        #expect(!BackendDockerMCPServerKeyScope.allows(commander, server: changed))
        #expect(BackendDockerMCPServerKeyScope.allows(dot, server: changed))
    }

    @Test func localOwnersAndLocalSessionsRemainAllowedButRemoteAndMissingIdentityDoNot() {
        let server = BackendServersStoredServer(id: "one", name: "one", address: "server.example", username: "admin")
        #expect(BackendDockerMCPServerKeyScope.allows(.local, server: server))
        #expect(BackendDockerMCPServerKeyScope.allows(.init(kind: .session, tiers: [.read]), server: server))
        #expect(!BackendDockerMCPServerKeyScope.allows(.init(kind: .remote, tiers: [.read]), server: server))
        #expect(!BackendDockerMCPServerKeyScope.allows(.init(kind: .key, tiers: [.read, .act, .alter]), server: server))
        #expect(!BackendDockerMCPServerKeyScope.allows(.init(kind: .session, tiers: [.read], machineID: "remote"), server: server))
    }

    @Test func serverReadsAndWritesRefuseOtherKeysBeforeSSHAndListsAreFiltered() async throws {
        let app = try BackendServersIPCPortFixture(enforceKeyScope: true)
        defer { app.cleanup() }
        _ = try app.store.setAIKeyAccess("s1", keyIDs: ["ClaudeiMatch"])
        _ = try app.store.add(.init(name: "other", address: "other.example", username: "admin"), creatorKeyID: "Dot")
        let commander = BackendServersCaller(kind: .key, attended: true, context: .init(caller: .internalEngine, ownerID: "key-one"), keyID: "ClaudeiMatch")
        let dot = BackendServersCaller(kind: .key, attended: true, context: .init(caller: .internalEngine, ownerID: "key-two"), keyID: "Dot")
        let rows = try await app.room.list(commander)
        #expect(rows.elements?.map { $0["id"].string } == ["s1"])
        for tier in [BackendMCPTier.read, .alter] {
            do {
                try await app.room.check(dot, .init(operation: "servers:look", serverId: "s1", tier: tier))
                Issue.record("An unallowed key reached the saved server")
            } catch let error as NativeRPCError { #expect(error.message.localizedCaseInsensitiveContains("not allowed on this server")) }
        }
        #expect(app.client.commands.isEmpty && app.dialer.count == 0)
        await app.stop()
    }

    @Test func aiKeyCannotGrantItselfViaTheNativeOwnerControl() async throws {
        let app = try BackendServersIPCPortFixture(enforceKeyScope: true)
        defer { app.cleanup() }
        let context = NativeRPCContext(caller: .internalEngine, ownerID: app.caller.context.ownerID)
        let answer = try await app.ipc.invoke("servers:ai-access:set", arguments: [.string("s1"), .array([.string("Dot")])], context: context)
        #expect(answer["ok"].bool == false)
        #expect(try app.store.get("s1")?.aiKeyIDs ?? [] == [])
        await app.stop()
    }
}
