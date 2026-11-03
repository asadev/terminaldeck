import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// DKA2: servers added from the person's own SSH settings, and Look only.
/// Fixtures only: a fake ssh -G evaluator and the IPC port's fake dialer. The
/// one real process is ssh-keygen -F over a temporary known_hosts file.
@Suite("Servers from SSH settings and Look only")
struct BackendDKA2ServerAccessTests {
    private static func evaluator(_ hosts: [String: String] = [:]) -> BackendDockerMCPServerSSHConfig {
        .init(evaluate: { request in
            let alias = request.arguments.last ?? ""
            let host = hosts[alias] ?? "100.86.183.128"
            return .init(code: 0, stdout: "hostname \(host)\nuser admin\nport 22\nidentityfile ~/.ssh/id_ed25519\nproxycommand none\n")
        })
    }
    private static func temporary(_ name: String) throws -> URL {
        let url = BackendServersS4RealTemp.directory().appendingPathComponent("dka2-\(name)-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func storeKeepsTheAliasAndLookOnlyButThePublicRowShapeIsUnchanged() throws {
        let root = try Self.temporary("store"); defer { try? FileManager.default.removeItem(at: root) }
        let store = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true))
        let row = try store.add(.init(name: "iMatch", address: "100.86.183.128", username: "admin"), sshAlias: "imza-server", lookOnly: true)
        let reloaded = try #require(try BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true)).get(row.id))
        #expect(reloaded.sshAlias == "imza-server" && reloaded.isLookOnly)
        #expect(reloaded.wireValue.fields?.map(\.key).sorted() == ["addedAt", "address", "credential", "drivesWindows", "hostKey", "id", "lastConnectedAt", "name", "port", "projectId", "startIn", "username"])
        let summary = BackendServersSummary(reloaded).wireValue
        #expect(summary["sshAlias"].string == "imza-server" && summary["lookOnly"].bool == true)
        #expect(throws: NativeRPCError.self) { _ = try store.add(.init(name: "again", address: "x.example", username: "a"), sshAlias: "imza-server") }
        #expect(throws: NativeRPCError.self) { _ = try store.add(.init(name: "bad", address: "x.example", username: "a"), sshAlias: "-oProxyCommand=x") }
        #expect(try store.setLookOnly(row.id, false))
        #expect(BackendServersSummary(try #require(try store.get(row.id))).wireValue["lookOnly"] == .missing)
        let disk = try String(contentsOf: store.file, encoding: .utf8)
        #expect(!disk.contains("PRIVATE KEY") && !disk.contains("privateKey") && !disk.contains("passphrase"))
        // A legacy row without the new fields reads back exactly as before.
        let legacy = BackendServersStore.readServers(.object([.init("servers", .array([.object([.init("id", .string("old")), .init("address", .string("old.example"))])]))]))
        #expect(legacy.first?.sshAlias == nil && legacy.first?.isLookOnly == false)
    }

    @Test func lookOnlyRefusesServerChangesForEveryoneAndTerminalsForAI() async throws {
        let app = try BackendServersIPCPortFixture(); defer { app.cleanup() }
        #expect(try app.store.setLookOnly("s1", true))
        let window = app.caller
        let key = BackendServersCaller(kind: .key, attended: true, context: .init(caller: .internalEngine, ownerID: "key-one"), keyID: "ClaudeiMatch")
        let local = BackendServersCaller(kind: .local, attended: true, context: .init(caller: .internalEngine, ownerID: "local-one"))
        for caller in [window, key, local] {
            for operation in ["servers.control", "servers:upload", "servers:setup:install", "servers:host:install"] {
                do { try await app.room.check(caller, .init(operation: operation, serverId: "s1", tier: .alter)); Issue.record("\(operation) passed on a Look only server") }
                catch let error as NativeRPCError { #expect(error.message.contains("Look only")) }
            }
            try await app.room.check(caller, .init(operation: "servers:look", serverId: "s1", tier: .read))
        }
        for caller in [key, local] {
            do { try await app.room.check(caller, .init(operation: "servers:shell:open", serverId: "s1", tier: .alter)); Issue.record("AI opened a terminal") }
            catch let error as NativeRPCError { #expect(error.message.contains("cannot open or type into a terminal")) }
        }
        try await app.room.check(window, .init(operation: "servers:shell:open", serverId: "s1", tier: .alter))
        #expect(try app.store.setLookOnly("s1", false))
        try await app.room.check(key, .init(operation: "servers.control", serverId: "s1", tier: .alter))
        #expect(app.dialer.count == 0, "refusals happen before any connection")
        await app.stop()
    }

    @Test func addingFromSSHSettingsStoresOnlyTheNameAndDefaultsToLookOnly() async throws {
        let app = try BackendServersIPCPortFixture(sshConfig: Self.evaluator()); defer { app.cleanup() }
        let draft = NativeRPCValue.object([.init("method", .string("ssh-config")), .init("sshAlias", .string("imza-server")), .init("name", .string("iMatch"))])
        let answer = try await app.call("servers:add", draft)
        #expect(answer["ok"].bool == true, "\(answer.compact)")
        let id = try #require(answer["id"].string)
        let row = try #require(try app.store.get(id))
        #expect(row.sshAlias == "imza-server" && row.isLookOnly && row.credential == .sshConfig)
        #expect(row.address == "100.86.183.128" && row.username == "admin" && row.port == 22 && row.name == "iMatch")
        #expect(app.dialer.count == 1, "the add checks the sign-in once")
        #expect(!FileManager.default.fileExists(atPath: app.credentials.file.path), "no sign-in is saved for an SSH settings server")
        let read = try await app.call("servers:access:read", .string(id))
        #expect(read["lookOnly"].bool == true && read["sshAlias"].string == "imza-server" && read["keyIDs"].elements != nil)
        let changed = try await app.call("servers:access:set", .string(id), .object([.init("lookOnly", .bool(false))]))
        #expect(changed["lookOnly"].bool == false)
        let again = try await app.call("servers:add", draft)
        #expect(again["ok"].bool == false, "one server per SSH settings name")
        await app.stop()
    }

    @Test func aliasListingFollowsIncludesSkipsPatternsAndCodeHostsAndNeverReadsKeys() async throws {
        let home = try Self.temporary("home"); defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh"), extra = ssh.appendingPathComponent("config.d")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try Data("""
        Include config.d/*
        Host imza-server prod
            HostName 100.86.183.128
        Host *.internal !nope
            User x
        Host "github-asad"
            HostName github.com
        Match host foo
            User y

        """.utf8).write(to: ssh.appendingPathComponent("config"))
        try Data("Host terminaldeck-server\n  HostName 178.105.239.176\n".utf8).write(to: extra.appendingPathComponent("demo"))
        try Data("PRETEND KEY".utf8).write(to: ssh.appendingPathComponent("id_ed25519"))
        let reads = BackendDeckCoreSecurityTestBox<[String]>([])
        let reader = BackendServersKeyFolderReader(entries: { try FileManager.default.contentsOfDirectory(atPath: $0) },
            read: { path in reads.edit { $0.append(URL(fileURLWithPath: path).lastPathComponent) }; return try String(contentsOfFile: path, encoding: .utf8) },
            size: { (try FileManager.default.attributesOfItem(atPath: $0)[.size] as? NSNumber)?.intValue ?? Int.max })
        let aliases = BackendServersSSHAliases(home: home, reader: reader, resolver: Self.evaluator(["github-asad": "github.com"]))
        #expect(aliases.hostNames() == ["terminaldeck-server", "imza-server", "prod", "github-asad"])
        let rows = await aliases.list()
        #expect(rows.map(\.alias) == ["terminaldeck-server", "imza-server", "prod"], "code hosting is not a server")
        #expect(rows.allSatisfy { $0.ready && $0.keyNames == ["id_ed25519"] })
        #expect(!reads.get().contains("id_ed25519"), "key files are checked for existence only")
        let wire = BackendServersSSHAliases.wire(rows, added: ["imza-server": "s9"])
        #expect(wire["aliases"].elements?.first { $0["alias"].string == "imza-server" }?["serverId"].string == "s9")
    }

    /// U68 (#496): no IdentityFile line and only ~/.ssh/id_rsa on the Mac, which plain ssh accepts.
    @Test func rsaOrECDSADefaultKeyIsUsedLikeSSHDoes() async throws {
        let home = try Self.temporary("rsa"); defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try Data("Host prod\n  HostName 10.0.0.7\n  User deploy\n".utf8).write(to: ssh.appendingPathComponent("config"))
        try Data("PRETEND KEY".utf8).write(to: ssh.appendingPathComponent("id_rsa"))
        let resolver = BackendDockerMCPServerSSHConfig(evaluate: { request in
            // The alias names no key; the /dev/null run is ssh's own list of defaults.
            let defaults = request.arguments.contains("/dev/null") ? "identityfile ~/.ssh/id_rsa\nidentityfile ~/.ssh/id_ecdsa\nidentityfile ~/.ssh/id_ed25519\n" : ""
            return .init(code: 0, stdout: "hostname 10.0.0.7\nuser deploy\nport 22\n" + defaults)
        })
        let resolved = try await resolver.resolve(alias: "prod", home: home)
        #expect(resolved.identityFiles.map { URL(fileURLWithPath: $0).lastPathComponent } == ["id_rsa", "id_ecdsa", "id_ed25519"])
        let rows = await BackendServersSSHAliases(home: home, resolver: resolver).list()
        #expect(rows.count == 1 && rows[0].ready && rows[0].keyNames == ["id_rsa"] && rows[0].problem == nil)
    }

    @Test func missingKeyFileIsAPlainProblemNotAnAdd() async throws {
        let home = try Self.temporary("nokey"); defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try Data("Host lonely\n  HostName 10.0.0.9\n".utf8).write(to: home.appendingPathComponent(".ssh/config"))
        let rows = await BackendServersSSHAliases(home: home, resolver: Self.evaluator()).list()
        #expect(rows.count == 1 && !rows[0].ready && rows[0].problem?.contains("No key file") == true)
    }

    @Test func knownHostsLookupReturnsOnlyThatAddressesPublicKeys() async throws {
        let home = try Self.temporary("known"); defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        var blob = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32])
        blob.append(Data(repeating: 7, count: 32))
        let line = "[server.example]:2222 ssh-ed25519 \(blob.base64EncodedString())\nother.example ssh-ed25519 \(blob.base64EncodedString())\n"
        try Data(line.utf8).write(to: home.appendingPathComponent(".ssh/known_hosts"))
        let found = await BackendServersSSH.trustedHostKeys(home: home, host: "server.example", port: 2222)
        #expect(found.count == 1 && found.first?.algorithm == "ssh-ed25519" && found.first?.key == blob)
        #expect(await BackendServersSSH.trustedHostKeys(home: home, host: "unknown.example", port: 22).isEmpty)
        #expect(await BackendServersSSH.trustedHostKeys(home: home, host: "-oProxyCommand=x", port: 22).isEmpty)
    }

    @Test func agentSocketMustBeARealSocket() {
        #expect(BackendServersSSH.personAgentSocket(["SSH_AUTH_SOCK": "/etc/hosts"]) == nil)
        #expect(BackendServersSSH.personAgentSocket(["SSH_AUTH_SOCK": "relative"]) == nil)
        #expect(BackendServersSSH.personAgentSocket([:]) == nil)
    }

    @Test func toolCatalogueAdvertisesAliasesAccessAndLookOnly() throws {
        let rows = try BackendDeckToolsMachinesCatalogue.rows()
        let details = try #require(rows.first { $0["id"].string == "servers.details" })
        let manage = try #require(rows.first { $0["id"].string == "servers.manage" })
        let about = details["inputSchema"]["properties"]["about"]["enum"].elements?.compactMap(\.string) ?? []
        let verbs = manage["inputSchema"]["properties"]["do"]["enum"].elements?.compactMap(\.string) ?? []
        #expect(about.contains("ssh-aliases") && about.contains("access"))
        #expect(verbs.contains("set-access") && manage["inputSchema"]["properties"]["lookOnly"]["type"].string == "boolean")
        #expect(Set(BackendDeckToolsMachinesServers.about) == Set(about) && Set(BackendDeckToolsMachinesServers.manageVerbs) == Set(verbs))
    }
}
