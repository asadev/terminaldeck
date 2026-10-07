import Foundation
import CryptoKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Exact proof fixtures travel through fake fetch seams; signatures, archive
/// bytes, grammar, fingerprinting and scratch writes are the real Swift code.
final class BackendOSTestPortStoreProof: BackendOSTestPortFixture {
    let base = "http://127.0.0.1:8933", now = 1_788_048_000_000.0
    let skillBody = "---\nname: plain-english\ndescription: Rewrite what you were about to say in plain English.\n---\n\nSay it the way you would to somebody who does not write code.\n"
    struct Fixture { let archive: Data, row: NativeRPCValue }
    func fixture(id: String, kind: String, name: String, install: NativeRPCValue, extra: [BackendOSStoreArchiveFixture.Entry], tier: Int) throws -> Fixture {
        let seed = try BackendOSStoreInstallFixture.item(kind: kind, install: install, extra: extra, tier: tier)
        let seedFiles = BackendOSStoreArchive.stripSingleRoot(try XCTUnwrap(BackendOSStoreArchive.read(seed.archive).files))
        let entries = try seedFiles.map { file -> BackendOSStoreArchiveFixture.Entry in
            var bytes = file.bytes
            if file.path == "terminaldeck.json" {
                var manifest = try NativeRPCValue.parseJSON(bytes).setting("publisher", .string("commons")).setting("id", .string(id)).setting("name", .string(name)).setting("links", .object([.init("repo", .string("https://github.com/commons/items")), .init("home", .null), .init("docs", .null)]))
                if kind == "mcp" { manifest = manifest.setting("needs", .array([.string("node")])) }; bytes = try manifest.encodedJSON()
            }
            return .init("items-abc/" + file.path, String(decoding: bytes, as: UTF8.self), mode: file.mode)
        }
        let archive = try BackendOSStoreArchiveFixture.tarGzip(entries), digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        var row = seed.row.setting("id", .string("commons/" + id)).setting("publisher", .string("commons")).setting("listedBy", .string("commons")).setting("name", .string(name)).setting("source", .object([.init("repo", .string("https://github.com/commons/items")), .init("commit", .string(String(repeating: kind == "mcp" ? "c" : "b", count: 40))), .init("path", .string(".")), .init("host", .string("github.com"))]))
            .setting("install", seed.row["install"].removing("kind")).setting("artifact", .object([.init("url", .string(base + "/items/" + id + ".tar.gz")), .init("sha256", .string(digest)), .init("bytes", .number(Double(archive.count))), .init("files", .number(Double(entries.count))), .init("unpacked", .number(Double(entries.reduce(0) { $0 + $1.body.count })))]))
        if kind == "mcp" { row = row.setting("needs", .array([.string("node")])) }
        return Fixture(archive: archive, row: row)
    }
    var mcp: NativeRPCValue { .object([.init("runtime", .string("node")), .init("package", .string("@commons/notes-mcp")), .init("args", .array([.string("--notes"), .string("${input:NOTES}")])), .init("inputs", .array([.object([.init("key", .string("NOTES")), .init("label", .string("Notes folder")), .init("hint", .string("Where your notes live")), .init("kind", .string("path")), .init("into", .string("arg")), .init("required", .bool(true))])])), .init("token", .string("@commons/notes-mcp"))]) }
    struct Rig { let root: URL, home: URL, store: BackendOSStoreInstaller, cache: BackendAppStoreIndexCache, calls: BackendOSTestPortStoreCalls, envelope: String, skill: Fixture, mcp: Fixture }
    func rig(keys: [BackendSharedStoreKey]? = nil) throws -> Rig {
        let root = try scratch("proof"), home = root.appendingPathComponent("home"), skill = try fixture(id: "plain-english", kind: "skill", name: "Plain English", install: .object([.init("dir", .string("skill"))]), extra: [.init("skill/SKILL.md", skillBody)], tier: 1), mcp = try fixture(id: "notes-server", kind: "mcp", name: "Notes Server", install: self.mcp, extra: [.init("README.md", "# Notes Server\n")], tier: 3)
        let document: NativeRPCValue = .object([.init("v", .number(1)), .init("serial", .number(1)), .init("issuedAt", .string(BackendAppSettingsStore.iso(now))), .init("expiresAt", .null), .init("generator", .string("store-install.proof.test")), .init("truncated", .bool(false)), .init("revoked", .array([])), .init("items", .array([skill.row, mcp.row]))])
        let bytes = try document.encodedJSON(), key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(SHA256.hash(data: Data(BackendSharedStoreKeys.developmentPhrase.utf8)))), signature = try key.signature(for: bytes)
        let envelope = NativeRPCValue.object([.init("v", .number(1)), .init("keyId", .string("td-store-dev-1")), .init("alg", .string("ed25519")), .init("sig", .string(signature.base64EncodedString())), .init("signed", .string(bytes.base64EncodedString()))]).compact
        let acceptedKeys = keys ?? BackendSharedStoreKeys.keys(environment: ["TERMINALDECK_STORE_DEV_KEY": "1"], packaged: false), cache = BackendAppStoreIndexCache(userData: root, writable: true, keys: acceptedKeys, fetch: { url, _ in XCTAssertEqual(url, "http://127.0.0.1:8933/store/index.json"); return .init(ok: true, text: envelope) }), calls = BackendOSTestPortStoreCalls()
        let now = self.now
        let store = try BackendOSStoreInstaller(userData: root, environment: [:], home: home.path, writable: true, loadIndex: { await cache.load(base: "http://127.0.0.1:8933", now: now) }, fetchArtifact: { url, _ in
            if url == "http://127.0.0.1:8933/items/plain-english.tar.gz" { return .init(ok: true, bytes: skill.archive) }
            if url == "http://127.0.0.1:8933/items/notes-server.tar.gz" { return .init(ok: true, bytes: mcp.archive) }
            return .init(ok: false, message: "the download answered 404")
        }, runAgent: { await calls.run($0, $1) }, claudeOperations: .init(add: { await calls.add($0) }, remove: { await calls.remove($0) }))
        return Rig(root: root, home: home, store: store, cache: cache, calls: calls, envelope: envelope, skill: skill, mcp: mcp)
    }
    func installBoth(_ r: Rig) async throws {
        let skill = try await r.store.install(id: "commons/plain-english", choice: .object([.init("agents", .array([.string("claude"), .string("gemini")]))])); XCTAssertEqual(skill["ok"].bool, true)
        let mcp = try await r.store.install(id: "commons/notes-server", choice: .object([.init("agents", .array([.string("claude"), .string("codex")])), .init("values", .object([.init("NOTES", .string(r.home.appendingPathComponent("notes").path))]))])); XCTAssertEqual(mcp["ok"].bool, true)
    }
    func testStoreProof299SignedCatalogueListsBothItems() async throws { let r = try rig(), view = try await r.store.view(); XCTAssertEqual(view["ok"].bool, true); XCTAssertEqual(view["from"].string, "store"); XCTAssertEqual(view["items"].elements?.compactMap { $0["row"]["id"].string }.sorted(), ["commons/notes-server", "commons/plain-english"]); XCTAssertTrue(view["items"].elements?.allSatisfy { $0["state"].string == "available" } == true) }
    func testStoreProof307RealTarDigestSkillFilesAndPin() async throws {
        let r = try rig(), result = try await r.store.install(id: "commons/plain-english", choice: .object([.init("agents", .array([.string("claude"), .string("gemini")]))])); XCTAssertEqual(result["ok"].bool, true)
        for agent in [".claude", ".gemini"] { XCTAssertEqual(try text(r.home.appendingPathComponent(agent + "/skills/commons.plain-english/SKILL.md")), skillBody) }
        let record = try XCTUnwrap(BackendOSStoreInstaller.readLedger(r.root).first { $0["id"].string == "commons/plain-english" }); XCTAssertEqual(record["sha256"], r.skill.row["artifact"]["sha256"]); XCTAssertEqual(record["commit"].string, String(repeating: "b", count: 40))
    }
    func testStoreProof319McpCommandComposedLocally() async throws {
        let r = try rig(), notes = r.home.appendingPathComponent("notes").path, result = try await r.store.install(id: "commons/notes-server", choice: .object([.init("agents", .array([.string("claude"), .string("codex")])), .init("values", .object([.init("NOTES", .string(notes))]))])); XCTAssertEqual(result["ok"].bool, true)
        let claude = await r.calls.requests(), ran = await r.calls.commands(); XCTAssertEqual(claude[0].1["command"].string, "npx -y @commons/notes-mcp --notes \"\(notes)\""); XCTAssertEqual(ran[0].0, "codex"); XCTAssertEqual(ran[0].1, ["mcp", "add", "commons-notes-server", "--", "npx", "-y", "@commons/notes-mcp", "--notes", notes])
    }
    func testStoreProof333BothItemsDrawInstalled() async throws { let r = try rig(); try await installBoth(r); let view = try await r.store.view(); XCTAssertEqual(view["items"].elements?.compactMap { $0["state"].string }.sorted(), ["installed", "installed"]) }
    func testStoreProof338OfflineKeepsSignedListAndReason() async throws { let r = try rig(); _ = try await r.store.view(); let keys = BackendSharedStoreKeys.keys(environment: ["TERMINALDECK_STORE_DEV_KEY": "1"], packaged: false), offline = BackendAppStoreIndexCache(userData: r.root, keys: keys, fetch: { _, _ in .init(ok: false, message: "the store could not be reached") }), now = self.now, store = try BackendOSStoreInstaller(userData: r.root, environment: [:], home: r.home.path, loadIndex: { await offline.load(base: "http://127.0.0.1:1", now: now) }), view = try await store.view(); XCTAssertEqual(view["ok"].bool, true); XCTAssertEqual(view["from"].string, "kept"); XCTAssertNotEqual(view["because"], .null); XCTAssertEqual(view["items"].elements?.count, 2) }
    func testStoreProof359UnaskedOrPackagedKeyRejectsFetchedAndKept() async throws { let r = try rig(); _ = try await r.store.view(); let now = self.now; for keys in [BackendSharedStoreKeys.live, BackendSharedStoreKeys.keys(environment: ["TERMINALDECK_STORE_DEV_KEY": "1"], packaged: true)] { let cache = BackendAppStoreIndexCache(userData: r.root, keys: keys, fetch: { _, _ in .init(ok: true, text: r.envelope) }), store = try BackendOSStoreInstaller(userData: r.root, environment: [:], home: r.home.path, loadIndex: { await cache.load(base: "http://127.0.0.1:8933", now: now) }), view = try await store.view(); XCTAssertEqual(view["ok"].bool, false); XCTAssertEqual(view["items"], .array([])) } }
    func testStoreProof368RemoveBothRestoresEveryOwnedTarget() async throws { let r = try rig(); try await installBoth(r); let skill = try await r.store.remove(id: "commons/plain-english"), mcp = try await r.store.remove(id: "commons/notes-server"); XCTAssertEqual(skill["ok"].bool, true); XCTAssertEqual(mcp["ok"].bool, true); for url in [r.home.appendingPathComponent(".claude/skills/commons.plain-english"), r.home.appendingPathComponent(".gemini/skills/commons.plain-english"), r.root.appendingPathComponent("community/items/commons.plain-english")] { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }; XCTAssertEqual(BackendOSStoreInstaller.readLedger(r.root), []); let calls = await r.calls.requests(); XCTAssertEqual(calls.last?.0, "remove") }
}
