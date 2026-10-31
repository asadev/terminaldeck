import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Server public store and downgrade refusals")
struct BackendServersStoreTests {
    @Test(arguments: ["server.example", "127.0.0.1", "::1", "office.local", "[::1]"])
    func realAddressShapes(_ address: String) { #expect(BackendServersStore.addressProblem(address) == nil) }
    @Test func wrongAddressShapesAndNormalization() {
        #expect(BackendServersStore.addressProblem("")?.contains("address is needed") == true)
        #expect(BackendServersStore.addressProblem("host name") == "An address cannot contain a space.")
        #expect(BackendServersStore.addressProblem("root@box")?.contains("part after the @") == true)
        #expect(BackendServersStore.addressProblem("https://box")?.contains("web address") == true)
        #expect(BackendServersStore.addressProblem(String(repeating: "a", count: 256)) == "That address is too long to be a real one.")
        #expect(BackendServersStore.normaliseAddress(" [::1] ") == "::1")
    }
    @Test func inertConstructorAndExplicitOwnership() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = BackendServersStore(dataRoot: root, policy: .init(mayRead: false, mayWrite: false))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(throws: NativeRPCError.self) { try store.list() }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func addDefaultsPersistenceAndNoSecrets() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true), now: { 123 }, makeID: { "one" })
        let added = try store.add(.init(name: "", address: "[::1]", username: "root"))
        #expect(added.name == "::1" && added.port == 22 && added.drivesWindows && added.credential == .none)
        #expect(added.addedAt == 123 && added.lastConnectedAt == nil && added.startIn == nil)
        let reopened = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true))
        #expect(try reopened.list() == [added])
        let raw = try NativeRPCValue.parseJSON(Data(contentsOf: store.file))
        #expect(raw["version"].number == 1 && raw["servers"].elements?.count == 1)
        #expect(raw["servers"].elements?[0].fields?.contains(where: { ["password", "privateKey", "passphrase"].contains($0.key) }) == false)
        let mode = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }
    @Test func missingFieldsBoundsAndCorruptFiles() throws {
        let entries: NativeRPCValue = .object([.init("servers", .array([
            .null, .object([.init("id", .string("missing"))]),
            .object([.init("id", .string("good")), .init("address", .string("box")), .init("credential", .string("unexpected")), .init("port", .number(1.5)), .init("hostKey", .object([.init("fingerprint", .string("not-a-pin"))]))])]))])
        let parsed = BackendServersStore.readServers(entries)
        #expect(parsed.count == 1 && parsed[0].id == "good" && parsed[0].port == 22 && parsed[0].hostKey == nil && parsed[0].drivesWindows)
        #expect(BackendServersStore.readServers(.null).isEmpty)
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: root.appendingPathComponent("servers.json"))
        #expect(try BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true)).list().isEmpty)
    }
    @Test func identityRecordedOnceAndExplicitlyForgotten() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true))
        let server = try store.add(.init(name: "server", address: "box", username: "root"))
        #expect(try store.rememberHostKey(server.id, algorithm: "ssh-ed25519", fingerprint: "SHA256:first"))
        #expect(try !store.rememberHostKey(server.id, algorithm: "ssh-rsa", fingerprint: "SHA256:second"))
        #expect(try store.get(server.id)?.hostKey?.fingerprint == "SHA256:first")
        #expect(try store.forgetHostKey(server.id)); #expect(try store.get(server.id)?.hostKey == nil)
        #expect(try store.markConnected(server.id)); #expect(try store.get(server.id)?.lastConnectedAt != nil)
    }
    @Test func startFolderAndRefusalsSurviveOldWriter() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true), makeID: { "one" })
        _ = try store.add(.init(name: "server", address: "box", username: "root"))
        #expect(try store.setStartIn("one", path: " /opt/my project "))
        #expect(try store.get("one")?.startIn == "/opt/my project")
        #expect(try !store.setDrivesWindows("one", allowed: false))
        var old = try NativeRPCValue.parseJSON(Data(contentsOf: store.file))
        let stripped = old["servers"].elements!.map { .object($0.fields!.filter { $0.key != "drivesWindows" }) as NativeRPCValue }
        old = old.setting("servers", .array(stripped)); try old.encodedJSON().write(to: store.file)
        let reopened = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true))
        #expect(try !reopened.drivesWindows("one")); #expect(try !reopened.drivesWindows("missing"))
        #expect(try reopened.setDrivesWindows("one", allowed: true)); #expect(try reopened.drivesWindows("one"))
        #expect(try !reopened.setDrivesWindows("missing", allowed: true))
        #expect(try reopened.setStartIn("one", path: nil)); #expect(try reopened.get("one")?.startIn == nil)
    }
    @Test func namesFoldersAndCountAreBounded() throws {
        let rows = (0..<70).map { NativeRPCValue.object([.init("id", .string(String($0))), .init("address", .string("box")), .init("name", .string("\n" + String(repeating: "x", count: 90))), .init("startIn", .string(String(repeating: "y", count: 4200)))]) }
        let result = BackendServersStore.readServers(.object([.init("servers", .array(rows))]))
        #expect(result.count == 64 && result.allSatisfy { $0.name.utf16.count == 64 && $0.startIn?.utf16.count == 4096 })
    }
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("servers-store-" + UUID().uuidString) }
}
