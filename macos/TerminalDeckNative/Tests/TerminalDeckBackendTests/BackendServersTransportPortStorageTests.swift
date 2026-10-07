import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Complete TS store/credentials/keyfiles rules with fake crypto")
struct BackendServersTransportPortStorageTests {
    @Test func storeAddressShapesAndMistakeSentences() {
        for value in ["example.com", "203.0.113.10", "box.local", "2001:db8::1"] { #expect(BackendServersStore.addressProblem(value) == nil) }
        #expect(BackendServersStore.addressProblem("root@example.com")?.contains("part after the @") == true)
        #expect(BackendServersStore.addressProblem("https://example.com")?.contains("no web address") == true)
        #expect(BackendServersStore.addressProblem("example .com")?.contains("space") == true)
        #expect(BackendServersStore.addressProblem("")?.contains("An address is needed") == true)
        #expect(BackendServersStore.normaliseAddress("[2001:db8::1]") == "2001:db8::1")
        #expect(BackendServersStore.normaliseAddress(" example.com ") == "example.com")
    }
    @Test func storeDefaultsBlankNameMissingFieldsAndRestart() throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        let server = try app.store.add(.init(name: "  ", address: "example.com", username: "ada"))
        #expect(server.name == "example.com" && server.port == 22 && server.credential == .none && server.hostKey == nil)
        do { _ = try app.store.add(.init(name: "x", address: "example.com", username: " ")); Issue.record("Saved missing username") } catch { #expect(error.localizedDescription.contains("A username is needed")) }
        do { _ = try app.store.add(.init(name: "x", address: "a b", username: "ada")); Issue.record("Saved bad address") } catch { #expect(error.localizedDescription.contains("space")) }
        #expect(try BackendServersStore(dataRoot: app.root, policy: .init(mayRead: true, mayWrite: true)).get(server.id)?.name == "example.com")
    }
    @Test func storePinOnceForgetInvalidPinAndRows() throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        #expect(try app.store.rememberHostKey("one", algorithm: "ssh-ed25519", fingerprint: "SHA256:first"))
        #expect(try !app.store.rememberHostKey("one", algorithm: "ssh-ed25519", fingerprint: "SHA256:second"))
        #expect(try app.store.get("one")?.hostKey?.fingerprint == "SHA256:first")
        #expect(try app.store.forgetHostKey("one")); #expect(try app.store.get("one")?.hostKey == nil)
        #expect(BackendServersStore.readServers(rows(row().setting("hostKey", .object([.init("fingerprint", .string("MD5:aa"))]))))[0].hostKey == nil)
        #expect(BackendServersStore.readServers(rows(row().setting("id", .string("")))).isEmpty)
        #expect(BackendServersStore.readServers(rows(row().setting("address", .string("root@x")))).isEmpty)
    }
    @Test func storeNonsenseUnreadableAndUnknownCredential() throws {
        for raw in [NativeRPCValue.null, .number(42), .string("text"), .object([]), .object([.init("servers", .string("no"))]), .object([.init("servers", .array([.number(1), .null]))])] { #expect(BackendServersStore.readServers(raw).isEmpty) }
        #expect(BackendServersStore.readServers(rows(row().setting("credential", .string("magic"))))[0].credential == .none)
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        try Data("not json at all".utf8).write(to: app.store.file)
        #expect(try BackendServersStore(dataRoot: app.root, policy: .init(mayRead: true, mayWrite: true)).list().isEmpty)
    }
    @Test func storeWindowsDefaultUnknownLiteralFalseAndDurability() throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        #expect(try app.store.list()[0].drivesWindows && app.store.drivesWindows("one"))
        #expect(try !app.store.drivesWindows("nothing like this"))
        #expect(BackendServersStore.readServers(rows(row()))[0].drivesWindows)
        for raw in [NativeRPCValue.bool(true), .string("yes"), .number(1), .null] { #expect(BackendServersStore.readServers(rows(row().setting("drivesWindows", raw)))[0].drivesWindows) }
        #expect(!BackendServersStore.readServers(rows(row().setting("drivesWindows", .bool(false))))[0].drivesWindows)
        #expect(try !app.store.setDrivesWindows("one", allowed: false))
        #expect(try !BackendServersStore(dataRoot: app.root, policy: .init(mayRead: true, mayWrite: true)).drivesWindows("one"))
        #expect(try app.store.setDrivesWindows("one", allowed: true))
        #expect(try BackendServersStore(dataRoot: app.root, policy: .init(mayRead: true, mayWrite: true)).drivesWindows("one"))
        #expect(try !app.store.setDrivesWindows("no such server", allowed: true))
    }
    @Test func publicStoreDiskHasKindButNoCredentialMaterial() throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        _ = try app.store.setCredentialKind("one", credential: .password)
        let disk = try String(contentsOf: app.store.file, encoding: .utf8)
        #expect(disk.contains("\"credential\":\"password\""))
        #expect(!disk.contains("passphrase") && !disk.contains("privateKey") && !disk.contains("\"password\":\""))
        let keys = try app.store.get("one")!.wireValue.fields!.map(\.key).sorted()
        #expect(keys == ["addedAt", "address", "credential", "drivesWindows", "hostKey", "id", "lastConnectedAt", "name", "port", "startIn", "username"])
    }
    @Test func credentialsNoSecureStoreAndSessionOnlyNeverWrites() throws {
        let app = try BackendServersTransportPortFixture(credential: nil); defer { app.cleanup() }
        let noStore = BackendServersCredentials(dataRoot: app.root, cipher: BackendServersTransportPortFixture.cipher(available: false), policy: .init(mayRead: true, mayWrite: true), keyValidator: .init { _, _ in nil })
        #expect(try noStore.save("server-1", credential: .password("hunter2")) == .init(ok: false, message: BackendServersCredentials.noSecureStore))
        #expect(!FileManager.default.fileExists(atPath: noStore.file.path))
        noStore.holdForSession("server-1", credential: .password("hunter2"))
        #expect(try noStore.read("server-1") == .password("hunter2") && noStore.isHeldForSessionOnly("server-1"))
        #expect(!FileManager.default.fileExists(atPath: noStore.file.path))
        #expect(try credentials(app.root).read("server-1") == nil)
    }
    @Test func credentialsRestartEncryptedReplacementAndKinds() throws {
        let app = try BackendServersTransportPortFixture(credential: nil); defer { app.cleanup() }
        let store = app.credentials
        _ = try store.save("server-1", credential: .password("hunter2"))
        #expect(try credentials(app.root).read("server-1") == .password("hunter2"))
        _ = try store.save("server-1", credential: .key(privateKey: "KEYMATERIAL", passphrase: "letmein"))
        let written = try String(contentsOf: store.file, encoding: .utf8)
        #expect(!written.contains("KEYMATERIAL") && !written.contains("letmein"))
        #expect(try store.kindOf("server-1") == .key && store.kindOf("server-2") == .none)
        _ = try store.save("server-1", credential: .password("old")); _ = try store.save("server-1", credential: .password("new"))
        #expect(try store.read("server-1") == .password("new"))
        let blob = try #require(Data(base64Encoded: String(contentsOf: store.file, encoding: .utf8)))
        let decoded = try NativeRPCValue.parseJSON(Data(blob.reversed()))
        #expect(decoded["entries"].elements?.count == 1)
    }
    @Test func credentialsSavedReplacesHeldAndBothCopiesForget() throws {
        let app = try BackendServersTransportPortFixture(credential: nil); defer { app.cleanup() }
        let store = app.credentials
        store.holdForSession("server-1", credential: .password("old")); _ = try store.save("server-1", credential: .password("new"))
        let storedSecret = try store.read("server-1")
        #expect(!store.isHeldForSessionOnly("server-1") && storedSecret == .password("new"))
        store.holdForSession("server-2", credential: .password("other"))
        _ = try store.forget("server-1"); _ = try store.forget("server-2")
        #expect(try store.read("server-1") == nil && store.read("server-2") == nil && credentials(app.root).read("server-1") == nil)
        #expect(try credentials(app.root).forget("nothing").ok)
    }
    @Test func credentialKeyFailureSentencesUseFakeParser() async throws {
        let app = try BackendServersTransportPortFixture(); defer { app.cleanup() }
        #expect(try await app.credentials.keyProblem("ssh-rsa AAAA...", passphrase: nil)?.contains("whole file") == true)
        #expect(try await app.credentials.keyProblem("   ", passphrase: nil)?.contains("first and last lines") == true)
        #expect(try await app.credentials.keyProblem(String(repeating: "x", count: 70000), passphrase: nil)?.contains("too long") == true)
        let locked = Self.locked
        let problem = try await app.credentials.keyProblem(locked, passphrase: nil)
        #expect(problem == nil || problem?.contains("locked") == true || problem?.contains("could not be read") == true)
        #expect(BackendServersKeyfiles.describeKey(locked, name: "k")?.locked == true)
    }
    @Test func keyFilesFilterKindsLocksUnknownAndAbsent() {
        let files = ["agent": "", "authorized_keys": "ssh-ed25519 public", "config": "Host kiwi-vps", "hetzner_personal": Self.open, "hetzner_personal.pub": "ssh-ed25519 public", "id_ed25519": Self.locked, "id_ed25519.pub": "ssh-ed25519 public"]
        let reader = Self.reader(files), root = URL(fileURLWithPath: "/home/x/.ssh")
        #expect(BackendServersKeyfiles.listKeyFiles(root, reader: reader).map(\.name) == ["hetzner_personal", "id_ed25519"])
        #expect(BackendServersKeyfiles.describeKey("ssh-ed25519 public", name: "id_ed25519.pub") == nil)
        #expect(BackendServersKeyfiles.describeKey("ssh-ed25519 public", name: "id_ed25519") == nil)
        #expect(BackendServersKeyfiles.describeKey(Self.open, name: "something-else-entirely") != nil)
        #expect(BackendServersKeyfiles.describeKey(Self.open, name: "k")?.locked == false)
        #expect(BackendServersKeyfiles.describeKey(Self.locked, name: "k")?.locked == true)
        #expect(BackendServersKeyfiles.describeKey(Self.pem, name: "k")?.locked == false)
        #expect(BackendServersKeyfiles.describeKey(Self.pemLocked, name: "k")?.locked == true)
        #expect(BackendServersKeyfiles.describeKey("-----BEGIN OPENSSH PRIVATE KEY-----\nnot base64 at all!!\n-----END OPENSSH PRIVATE KEY-----\n", name: "k")?.locked == nil)
        let absent = BackendServersKeyFolderReader(entries: { _ in throw CancellationError() }, read: { _ in "" }, size: { _ in 0 })
        #expect(BackendServersKeyfiles.listKeyFiles(root, reader: absent).isEmpty)
    }
    @Test func offeredAndNativePanelPathsOnlyAndBytesUnchanged() {
        let reader = Self.reader(["hetzner_personal": Self.open, "config": "Host x", "server.pem": Self.pem, "notes.txt": "hello"])
        let offers = BackendServersKeyFileOffers(keyRoot: URL(fileURLWithPath: "/home/x/.ssh"), reader: reader)
        _ = offers.list()
        #expect(offers.read("/home/x/.ssh/config")["sentence"].string?.contains("not one this app offered") == true)
        #expect(offers.read("/home/x/.ssh/hetzner_personal")["key"].string == Self.open)
        #expect(offers.chose("/Users/x/Downloads/notes.txt") == nil)
        #expect(offers.chose("/Users/x/Downloads/server.pem")?.what == "An RSA key")
        #expect(offers.read("/Users/x/Downloads/server.pem")["ok"].bool == true)
        #expect(offers.read("/Users/x/Downloads/notes.txt")["ok"].bool == false)
    }
    private func credentials(_ root: URL) -> BackendServersCredentials { .init(dataRoot: root, cipher: BackendServersTransportPortFixture.cipher(), policy: .init(mayRead: true, mayWrite: true), keyValidator: .init { _, _ in nil }) }
    private func row() -> NativeRPCValue { .object([.init("id", .string("server-1")), .init("name", .string("x")), .init("address", .string("example.com")), .init("username", .string("ada")), .init("port", .number(22)), .init("credential", .string("none")), .init("hostKey", .null), .init("addedAt", .number(1)), .init("lastConnectedAt", .null)]) }
    private func rows(_ row: NativeRPCValue) -> NativeRPCValue { .object([.init("servers", .array([row]))]) }
    static let open = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZWQyNTUxOQAAACAPYzDZdh+7iDEAImrLBicB1gZqLTxtLZUMNktMKME7Pw==\n-----END OPENSSH PRIVATE KEY-----\n"
    static let locked = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABDCFqvVYs5CTaB1EJ0gYs0WAAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIPrazOD6pinZ\n-----END OPENSSH PRIVATE KEY-----\n"
    static let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n-----END RSA PRIVATE KEY-----\n"
    static let pemLocked = "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,3F1A0B0C2D3E4F5061728394A5B6C7D8\nkey-body\n-----END RSA PRIVATE KEY-----\n"
    static func reader(_ files: [String: String]) -> BackendServersKeyFolderReader { .init(entries: { _ in Array(files.keys) }, read: { path in guard let text = files[URL(fileURLWithPath: path).lastPathComponent] else { throw CancellationError() }; return text }, size: { path in files[URL(fileURLWithPath: path).lastPathComponent]?.utf8.count ?? 0 }) }
}
