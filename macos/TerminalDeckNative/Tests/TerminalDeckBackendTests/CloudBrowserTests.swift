import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor CloudBrowserFixtureCookies: CloudBrowserCookiePort {
    var values: [CloudBrowserCookie]
    var active = false
    var writes = 0
    init(_ values: [CloudBrowserCookie] = []) { self.values = values }
    func cookies(profileId: String) -> [CloudBrowserCookie] { values.filter { $0.profileId == profileId } }
    func insertKeepingLocal(_ cookie: CloudBrowserCookie) throws -> CloudApplyStatus {
        if let existing = values.first(where: { $0.identity == cookie.identity }) { return existing.sameAttributes(as: cookie) ? .alreadyPresent : .keptBoth }
        if active { return .keptBoth }
        guard cookie.partitionKey == nil else { throw CloudFailure.unsupportedFormat }
        writes += 1; values.append(cookie); return .applied
    }
    func needsSignInSites(profileId: String) -> Set<String> { ["local-storage.invalid", "indexed-db.invalid"] }
    func navigate() { active = true }
}
@MainActor
final class CloudBrowserTests: XCTestCase {
    var assertions = 0
    override func tearDown() async throws { print("CloudBrowserTests assertions=\(assertions)") }
    func check(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) { assertions += 1; XCTAssertTrue(condition, "Browser assertion", file: file, line: line) }
    func cookie(_ value: String = "fixture-cookie", name: String = "session", expiry: Double? = nil, hostOnly: Bool = true) -> CloudBrowserCookie {
        .init(profileId: "default", domain: hostOnly ? "example.invalid" : ".example.invalid", path: "/", name: name,
              value: value, hostOnly: hostOnly, httpOnly: true, secure: true, sameSite: .lax, expires: expiry, session: expiry == nil)
    }
    func record(_ cookie: CloudBrowserCookie) throws -> CloudSecretRecord {
        .init(sourceId: "browser-default", recordId: cookie.identity, domain: "browser-cookies",
              payload: .init(try NativeRPCValue.parseJSON(JSONEncoder().encode(cookie))))
    }
    func testCookieConflictPreservesActiveProfileAndAllAttributes() async throws {
        let old = cookie("local-fixture-cookie"), remote = cookie("remote-fixture-cookie", hostOnly: false)
        let owner = CloudBrowserFixtureCookies([old]); await owner.navigate()
        let store = CloudBrowserCookieStore(sourceId: "browser-default", profileId: "default", store: owner, now: { 100 })
        check(old.identity == remote.identity)
        check(try await store.merge(record(remote)) == .keptBoth)
        check(await owner.values.first == old)
        check(await owner.writes == 0)
        let absent = cookie(name: "different-session")
        check(try await store.merge(record(absent)) == .keptBoth)
        check(await owner.writes == 0)
        let expired = cookie(name: "expired", expiry: 10)
        check(try await store.merge(record(expired)) == .alreadyPresent)
        let coverage = try await store.coverage()
        check(coverage.expired == 1)
        check(coverage.conflicts == 2)
        check(coverage.needsSignIn == 2)
        check(await owner.values.count == 1)
    }
    func testDifferingLocalCookieGetsEncryptedConflictExport() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()
        let localCookie = cookie("local-fixture-cookie"), remoteCookie = cookie("remote-fixture-cookie")
        let owner = CloudBrowserFixtureCookies([localCookie])
        let journal = CloudSecretsFixtureJournal()
        let local = CloudBrowserCookieStore(sourceId: "browser-default", profileId: "default", store: owner)
        let adapter = CloudSecretsLogicalAdapter(store: local, content: client.content, policy: client.policy,
            deviceId: client.device.deviceId, keepConflicts: { try await journal.enqueue($0) }, retainIncomingConflict: { await journal.retain($0) })
        let snapshot = try await adapter.snapshot(records: [record(remoteCookie)], cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1, watermarks: [:]))
        let preparation = try await adapter.validateIncoming(snapshot.operations, files: [])
        let result = try await adapter.applyPrepared(preparation, origin: .init(deviceId: client.device.deviceId, sequence: CloudSequence(1)))
        check(result.results.first?.status == .keptBoth)
        check(await owner.values == [localCookie])
        let conflict = await journal.operations
        check(conflict.count == 1)
        let bytes = try CloudSecretsCanonical.encode(conflict)
        check(bytes.range(of: Data(localCookie.value.utf8)) == nil)
        let envelope = try CloudWire.decode(CloudContentEnvelope.self, from: CloudSecretsCanonical.encode(conflict[0].payload))
        let decoded = try CloudWire.decode(CloudSecretRecord.self, from: await client.content.open(envelope))
        check(decoded.payload.raw["value"].string == localCookie.value)
    }
    func testFreshCookieImportReadbackAndUnsupportedPartition() async throws {
        let owner = CloudBrowserFixtureCookies()
        let store = CloudBrowserCookieStore(sourceId: "browser-default", profileId: "default", store: owner, now: { 100 })
        for incoming in [cookie(), cookie(name: "persistent", expiry: 500), cookie(name: "domain", hostOnly: false)] {
            let row = try record(incoming)
            try await store.validate(row)
            check(try await store.merge(row) == .applied)
            check(try await store.verify(row, outcome: .applied))
        }
        check(try await store.capture().count == 3)
        let original = cookie()
        let partitioned = CloudBrowserCookie(profileId: original.profileId, domain: original.domain, path: original.path,
            name: "partitioned", value: original.value, partitionKey: "https://top.invalid", hostOnly: true,
            httpOnly: true, secure: true, sameSite: .none, expires: nil, session: true)
        do { _ = try await store.merge(record(partitioned)); check(false) } catch { check(true) }
        check(await owner.writes == 3)
    }
    func testCookieSecurityAttributesCannotBeDowngraded() throws {
        let original = cookie(name: "__Host-fixture")
        let raw = try NativeRPCValue.parseJSON(JSONEncoder().encode(original))
        let changes: [(String, NativeRPCValue)] = [("secure", .bool(false)), ("hostOnly", .bool(false)),
            ("path", .string("/other")), ("session", .bool(false)), ("domain", .string("bad/host"))]
        for (field, value) in changes {
            let modified = try JSONDecoder().decode(CloudBrowserCookie.self, from: raw.setting(field, value).encodedJSON())
            do { try modified.validate(); check(false) } catch { check(true) }
        }
    }
    func passwordStore(_ root: URL) throws -> BackendBrowserPasswords {
        try .init(dataRoot: root,
            cipher: .init(available: { true }, decrypt: { data in
                guard data.starts(with: Data("fixture:".utf8)) else { throw CloudFailure.secretsLocked }
                return String(decoding: data.dropFirst(8), as: UTF8.self)
            }, encrypt: { plain, _ in Data("fixture:".utf8) + Data(plain.utf8) }),
            host: .init(tab: { _ in nil }, fill: { _, _, _ in false }, copy: { _ in throw CloudFailure.unavailable }, reveal: { _ in throw CloudFailure.unavailable }),
            requireWriter: {}, requireProfile: { id in guard id == "default" else { throw CloudFailure.invalidRequest } })
    }
    func testSavedPasswordOwnerAddOnlyAndUnreadableFilePreserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-browser-" + UUID().uuidString.lowercased()).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try passwordStore(root)
        let adapter = BackendCloudBrowserPasswordStore(sourceId: "passwords-default", profileId: "default", store: owner)
        let password = BackendCloudBrowserPassword(profileId: "default", origin: "https://example.invalid", username: "fixture-user", password: "fixture-password", updatedAt: 1)
        let row = try BackendCloudSecretsRecords.record("passwords-default", password.identity, .browserPassword, password)
        check(try await adapter.merge(row) == .applied)
        check(try await adapter.verify(row, outcome: .applied))
        let saved = try Data(contentsOf: owner.file)
        let other = BackendCloudBrowserPassword(profileId: password.profileId, origin: password.origin, username: password.username, password: "other-fixture-password", updatedAt: 2)
        let conflicting = try BackendCloudSecretsRecords.record("passwords-default", other.identity, .browserPassword, other)
        check(try await adapter.merge(conflicting) == .keptBoth)
        check(try Data(contentsOf: owner.file) == saved)
        await owner.close()
        check(try await adapter.capture().count == 1)
        await owner.close()
        let unreadable = Data("unreadable-fixture-ciphertext".utf8)
        try unreadable.write(to: owner.file)
        do { _ = try await adapter.merge(row); check(false) } catch { check(true) }
        check(try Data(contentsOf: owner.file) == unreadable)
    }
    func testBrowserProjectionExcludesPrivateTabsAndProtectsURLCredentials() throws {
        check(try CloudBrowserProjection.page(url: "https://example.invalid/private", profileId: "default", recordId: "one", privateTab: true) == nil)
        let page = try XCTUnwrap(CloudBrowserProjection.page(url: "https://fixture:fixture@example.invalid/path?token=fixture#fragment", profileId: "default", recordId: "one", privateTab: false))
        check(page.publicURL == "https://example.invalid/path")
        check(page.secret != nil)
    }
}
