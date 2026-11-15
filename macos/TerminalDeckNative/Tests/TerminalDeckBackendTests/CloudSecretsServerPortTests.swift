import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Blocker 3, the source Asad named first: server passwords and saved SSH keys, read and added through the
/// Servers owner's own live objects (`BackendServersFeature.cloudSecrets(sourceId:)`). Fixture bytes only;
/// folders only under ~/Deck Dev/notes/cloud-test-20261112/v/.
private actor CloudServerPortCounter {
    var count = 0
    func add() { count += 1 }
}
@MainActor
final class CloudSecretsServerPortTests: XCTestCase {
    var assertions = 0
    override func tearDown() async throws { print("CloudSecretsServerPortTests assertions=\(assertions)") }
    func check(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        assertions += 1; XCTAssertTrue(value, "Server port assertion", file: file, line: line)
    }
    private struct Mac {
        let data: URL
        let list: BackendServersStore
        let credentials: BackendServersCredentials
        let port: BackendCloudSecretsServerPort
    }
    private func folder() throws -> URL {
        let approved = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/cloud-test-20261112/v")
        let made = approved.appendingPathComponent("server-port-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        return made
    }
    private func mac(_ name: String, in folder: URL, key: UInt8) throws -> Mac {
        let data = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let password = Data(repeating: key, count: 32)
        let cipher = BackendBrowserPasswordsCipher(available: { true }, decrypt: { try ChromiumSafeStorageCipher.decrypt($0, password: password) },
            encrypt: { text, _ in try ChromiumSafeStorageCipher.encrypt(text, password: password) })
        let policy = BackendServersStoragePolicy(mayRead: true, mayWrite: true)
        let list = BackendServersStore(dataRoot: data, policy: policy, serverAccessEnabled: true)
        let credentials = BackendServersCredentials(dataRoot: data, cipher: cipher, policy: policy, keyValidator: .init(validate: { _, _ in nil }))
        return Mac(data: data, list: list, credentials: credentials,
                   port: BackendCloudSecretsServerPort(sourceId: "servers", credentials: credentials, servers: list))
    }
    private func value(_ record: CloudSecretRecord) throws -> BackendCloudSecretsServerValue {
        try BackendCloudSecretsRecords.decode(BackendCloudSecretsServerValue.self, record, source: "servers", domain: .server)
    }
    private func record(_ id: String, _ credential: BackendServersCredential, name: String = "Fixture box", address: String = "box.fixture.invalid",
                        port: Int = 22, username: String = "deploy", lookOnly: Bool? = nil) throws -> CloudSecretRecord {
        var fields: [NativeRPCValue.Field] = [.init("name", .string(name)), .init("address", .string(address)),
                                               .init("port", .number(Double(port))), .init("username", .string(username))]
        if let lookOnly { fields.append(.init("lookOnly", .bool(lookOnly))) }
        var payload: [NativeRPCValue.Field] = [.init("server", .object(fields))]
        switch credential {
        case .password(let text): payload += [.init("kind", .string("password")), .init("password", .string(text))]
        case .key(let key, _): payload += [.init("kind", .string("key")), .init("privateKey", .string(key))]
        case .sshConfig: throw CloudFailure.unsupportedFormat
        }
        return CloudSecretRecord(sourceId: "servers", recordId: id, domain: CloudSecretsDomain.server.rawValue, payload: .init(.object(payload)))
    }

    /// A saved sign-in travels with the server it belongs to. On a Mac that does not have that server it is added
    /// under the same id, with this Mac's own permissions closed, and then the sign-in is kept under it.
    func testASavedSignInArrivesWithItsServerOnAMacThatDoesNotHaveIt() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try mac("a", in: folder, key: 11), b = try mac("b", in: folder, key: 12)
        let password = try a.list.add(.init(name: "Fixture box", address: "box.fixture.invalid", port: 2222, username: "deploy"))
        let keyed = try a.list.add(.init(name: "Fixture key box", address: "keys.fixture.invalid", username: "root"), lookOnly: true)
        check(try a.list.rememberHostKey(password.id, algorithm: "ssh-ed25519", fingerprint: "SHA256:fixturefingerprint"))
        check(try a.credentials.save(password.id, credential: .password("fixture-server-value")).ok)
        check(try a.credentials.save(keyed.id, credential: .key(privateKey: "fixture-private-key-text", passphrase: nil)).ok)
        let records = try await a.port.store.capture()
        check(records.count == 2)
        let first = try XCTUnwrap(records.first { $0.recordId == password.id }), second = try XCTUnwrap(records.first { $0.recordId == keyed.id })
        let carried = try XCTUnwrap(try value(first).server)
        check(carried.name == "Fixture box" && carried.address == "box.fixture.invalid" && carried.port == 2222 && carried.username == "deploy")
        check(carried.hostKeyFingerprint == "SHA256:fixturefingerprint" && carried.hostKeyAlgorithm == "ssh-ed25519")
        check(carried.lookOnly == nil)
        check(try value(second).server?.lookOnly == true)
        // Mac B has neither server.
        check(try b.list.list().isEmpty)
        for record in records {
            try await b.port.store.validate(record)
            let outcome = try await b.port.store.merge(record)
            check(outcome == .applied)
            check(try await b.port.store.verify(record, outcome: outcome))
        }
        let arrived = try XCTUnwrap(try b.list.get(password.id)), arrivedKey = try XCTUnwrap(try b.list.get(keyed.id))
        check(arrived.name == "Fixture box" && arrived.address == "box.fixture.invalid" && arrived.port == 2222 && arrived.username == "deploy")
        check(arrived.hostKey?.fingerprint == "SHA256:fixturefingerprint")
        check(arrived.credential == .password && arrivedKey.credential == .key)
        check(try b.credentials.read(password.id) == .password("fixture-server-value"))
        check(try b.credentials.read(keyed.id) == .key(privateKey: "fixture-private-key-text", passphrase: nil))
        // This Mac's own permissions start closed and never travel; Look only is kept, never lowered.
        for server in [arrived, arrivedKey] {
            check(server.drivesWindows == false)
            check(server.aiKeyIDs == [])
            check(server.startIn == nil && server.sshAlias == nil && server.shownApps == nil)
        }
        check(arrivedKey.isLookOnly && !arrived.isLookOnly)
        let denies = try NativeRPCValue.parseJSON(Data(contentsOf: b.data.appendingPathComponent("window-denies.json")))
        check(Set(denies["denied"].elements?.compactMap(\.string) ?? []) == [password.id, keyed.id])
        // Again: nothing is added twice and nothing changes.
        for record in records { check(try await b.port.store.merge(record) == .alreadyPresent) }
        check(try b.list.list().count == 2)
        // Add-only: what the person changed on this Mac stays, also when the other Mac's copy differs.
        check(try b.list.rename(password.id, name: "Renamed here"))
        check(try b.list.setDrivesWindows(password.id, allowed: true))
        let changed = try record(password.id, .password("fixture-server-value"), name: "Renamed there", address: "other.fixture.invalid")
        check(try await b.port.store.merge(changed) == .alreadyPresent)
        let kept = try XCTUnwrap(try b.list.get(password.id))
        check(kept.name == "Renamed here" && kept.address == "box.fixture.invalid" && kept.drivesWindows)
        // A different sign-in for a server that is here is kept beside the local one, never over it.
        let different = try record(password.id, .password("fixture-other-value"))
        check(try await b.port.store.merge(different) == .keptBoth)
        check(try b.credentials.read(password.id) == .password("fixture-server-value"))
    }

    /// A sign-in without its server waits; a definition that a person could not have typed is refused before any
    /// writer; a sign-in from the person's own SSH settings never travels.
    func testWithoutItsServerASignInWaitsAndABadDefinitionIsRefused() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try mac("a", in: folder, key: 11), b = try mac("b", in: folder, key: 12)
        let bare = try BackendCloudSecretsRecords.record("servers", "fixture-unknown-server", .server, BackendCloudSecretsServerValue(credential: .password("fixture-value")))
        do { _ = try await b.port.store.merge(bare); check(false) } catch CloudFailure.unavailable { check(true) }
        check(try b.list.list().isEmpty)
        check(try b.credentials.read("fixture-unknown-server") == nil)
        let bad: [CloudSecretRecord] = [
            try record("fixture-bad-1", .password("fixture-value"), address: "two words.invalid"),
            try record("fixture-bad-2", .password("fixture-value"), address: "user@box.fixture.invalid"),
            try record("fixture-bad-3", .password("fixture-value"), port: 0),
            try record("fixture-bad-4", .password("fixture-value"), username: ""),
            try record("fixture-bad-5", .password("fixture-value"), name: "line\nbreak"),
            try record("fixture-bad-6", .password("fixture-value"), lookOnly: false)]
        for record in bad {
            do { try await b.port.store.validate(record); check(false) } catch CloudFailure.invalidRequest { check(true) }
            do { _ = try await b.port.store.merge(record); check(false) } catch CloudFailure.invalidRequest { check(true) }
        }
        check(try b.list.list().isEmpty)
        check(!FileManager.default.fileExists(atPath: b.credentials.file.path))
        // The person's own SSH settings name holds no secret and is not a record.
        let alias = try a.list.add(.init(name: "Alias box", address: "alias.fixture.invalid", username: "me"), sshAlias: "fixture-alias")
        check(try a.credentials.save(alias.id, credential: .sshConfig(alias: "fixture-alias")).ok)
        check(try await a.port.store.capture().isEmpty)
        // A sign-in whose server is not in the list still travels, without a definition.
        check(try a.credentials.save("fixture-orphan", credential: .password("fixture-value")).ok)
        let orphan = try await a.port.store.capture()
        check(orphan.count == 1)
        check(try value(try XCTUnwrap(orphan.first)).server == nil)
    }

    /// The owner tells Cloud after each save, off its own lock; with no observer nothing runs.
    func testASaveTellsCloudOffTheOwnersLockAndStopsWhenAskedTo() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try mac("a", in: folder, key: 11)
        let counter = CloudServerPortCounter()
        let credentials = a.credentials
        a.port.observe {
            // Reading the owner from inside the callback would deadlock if it ran under the owner's lock.
            _ = try? credentials.kindOf("fixture-server")
            Task { await counter.add() }
        }
        check(try a.credentials.save("fixture-server", credential: .password("fixture-value")).ok)
        for _ in 0..<200 { if await counter.count >= 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let afterSave = await counter.count
        check(afterSave == 1)
        check(try a.credentials.forget("fixture-server").ok)
        for _ in 0..<200 { if await counter.count >= 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let afterForget = await counter.count
        check(afterForget == 2)
        a.port.observe(nil)
        check(try a.credentials.save("fixture-server", credential: .password("fixture-value-2")).ok)
        try await Task.sleep(for: .milliseconds(200))
        let afterStop = await counter.count
        check(afterStop == 2)
    }
}
