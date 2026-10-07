import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// The 15 asset-tools.test.ts cases the S2 lane could only port at the tool
/// layer ("partial") now run against the REAL source-compatible domain
/// (BackendS4AssetsDomain): real ledger, real files on disk, the real fetch
/// writer, rendition choice, coverage reading and run-owner file. The only fake
/// is the network (a scripted transport standing in for the profile's fetch),
/// plus the profile list and settings store. No real network, no real sleeps.

final class S4AssetsTransport: BackendS4AssetsTransport, @unchecked Sendable {
    struct Reply: Sendable { var status = 200, type = "image/jpeg", length = 0, body: Data? = nil }
    private let lock = NSLock()
    private var table: [String: Reply] = [:]
    private var calls: [(method: String, url: String)] = []
    func serve(_ url: String, bytes: Data, type: String = "image/jpeg") { lock.withLock { table[url] = Reply(type: type, length: bytes.count, body: bytes) } }
    func probeOnly(_ url: String, length: Int, type: String = "image/jpeg") { lock.withLock { table[url] = Reply(type: type, length: length, body: nil) } }
    func requests(_ method: String) -> Int { lock.withLock { calls.filter { $0.method == method }.count } }
    func open(url: String, method: String, headers: [String: String], profile: String?, timeoutMilliseconds: Int) async throws -> BackendS4AssetsResponse {
        let reply = lock.withLock { () -> Reply in calls.append((method, url)); return table[url] ?? Reply(status: 404, type: "text/plain", length: 2, body: Data("no".utf8)) }
        let headers = ["content-type": reply.type, "content-length": String(reply.length)]
        guard method == "GET", let body = reply.body else { return BackendS4AssetsResponse(status: reply.status, headers: headers, body: nil) }
        return BackendS4AssetsResponse(status: reply.status, headers: headers, body: AsyncThrowingStream { continuation in continuation.yield(body); continuation.finish() })
    }
}

final class S4AssetsBox<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

struct S4AssetsRig {
    let directory: URL, userData: String, files: String
    let domain: BackendS4AssetsDomain, runtime: S2AssetsRuntime, transport: S4AssetsTransport
    let definitions: [BackendDeckToolsDefinition]
    let stored: S4AssetsBox<[String: NativeRPCValue]>, noted: S4AssetsBox<[String]>
    static let asset = Data("a floor plan, 1920px, and every byte of it".utf8)

    static func make() throws -> S4AssetsRig {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("BackendS4AssetsTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let resolved = realpath(base.path, nil) else { throw S2AssetsPlainError("no real path for \(base.path)") }
        defer { free(resolved) }
        let real = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let userData = real.appendingPathComponent("data", isDirectory: true), files = real.appendingPathComponent("files", isDirectory: true)
        for folder in [userData, files] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let transport = S4AssetsTransport(), stored = S4AssetsBox<[String: NativeRPCValue]>([:]), noted = S4AssetsBox<[String]>([])
        let domain = BackendS4AssetsDomain(userData: userData, transport: transport, profileExists: { $0 == "default" },
                                           settings: { profile in stored.value[profile] ?? .object([]) },
                                           noteBatch: { profile, _ in noted.mutate { $0.append(profile) } }, now: { S2Assets.clock })
        let runtime = S2AssetsRuntime(kind: "local")
        return S4AssetsRig(directory: real, userData: userData.path, files: files.path, domain: domain, runtime: runtime, transport: transport,
                           definitions: try BackendDeckToolsAssets.definitions(domain: domain, runtime: runtime), stored: stored, noted: noted)
    }
    func call(_ id: String, _ args: NativeRPCValue) async -> BackendMCPToolReply {
        guard let definition = definitions.first(where: { $0.spec.id == id }) else { return .failure("there is no tool called \(id)") }
        let context = BackendMCPCallContext(sessionID: "s4-assets", machineID: "", projectRoot: nil, attended: true,
            allowedTools: Set(definitions.map { $0.spec.id }), allowedTiers: [.read, .act, .alter], cancellation: .init())
        return await BackendDeckToolsSupport.reply {
            try BackendDeckCoreCatalogueSchema.check(tool: definition.spec, arguments: args)
            return try await definition.handler(context, args)
        }
    }
    func file(_ name: String, _ contents: String) throws -> (path: String, digest: String) {
        let url = URL(fileURLWithPath: files).appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return (url.path, BackendBrowserScrapingIO.digest(Data(contents.utf8)))
    }
    func runFolder(_ run: String) -> String { userData + "/scrape/runs/" + run }
    func dispose() { try? FileManager.default.removeItem(at: directory) }
}

final class BackendS4AssetsTests: XCTestCase {
    private typealias A = S2Assets
    private func value(_ reply: BackendMCPToolReply) -> NativeRPCValue { A.value(reply) }
    private func record(_ rig: S4AssetsRig, _ path: String) async -> BackendMCPToolReply {
        await rig.call("assets.ledger", A.o([("runId", .string("run-1")), ("op", .string("record")), ("url", .string("https://x.test/a.jpg")), ("path", .string(path))]))
    }
    private func decide(_ rig: S4AssetsRig, mode: String? = nil) async -> BackendMCPToolReply {
        var pairs: [(String, NativeRPCValue)] = [("runId", .string("run-1")), ("op", .string("decide")), ("url", .string("https://x.test/a.jpg"))]
        if let mode { pairs.append(("mode", .string(mode))) }
        return await rig.call("assets.ledger", A.o(pairs))
    }
    private let sizeRule = A.o([("id", .string("size")), ("match", .string("/498/")), ("replace", .string("/1920/"))])

    // asset-tools.test.ts:183
    func testL183BiggerCopyIsAnsweredWithTheRuleThatFoundIt() async throws {
        let rig = try S4AssetsRig.make(); defer { rig.dispose() }
        rig.transport.probeOnly("https://x.test/i/498/a.jpg", length: 20_000)
        rig.transport.probeOnly("https://x.test/i/1920/a.jpg", length: 400_000)
        let answer = await rig.call("assets.rendition", A.o([("url", .string("https://x.test/i/498/a.jpg")), ("rules", .array([sizeRule]))]))
        XCTAssertFalse(answer.isError, A.error(answer))
        XCTAssertEqual(value(answer)["url"], .string("https://x.test/i/1920/a.jpg"))
        XCTAssertEqual(value(answer)["upgraded"], .bool(true)); XCTAssertEqual(value(answer)["ruleId"], .string("size"))
        XCTAssertEqual(value(answer)["comparedBytes"], .bool(true))
    }
    // asset-tools.test.ts:198
    func testL198FallsBackToTheOriginalRatherThanAnsweringWithNothing() async throws {
        let rig = try S4AssetsRig.make(); defer { rig.dispose() }
        rig.transport.probeOnly("https://x.test/i/498/a.jpg", length: 20_000)
        let answer = await rig.call("assets.rendition", A.o([("url", .string("https://x.test/i/498/a.jpg")), ("rules", .array([sizeRule]))]))
        XCTAssertEqual(value(answer)["url"], .string("https://x.test/i/498/a.jpg"))
        XCTAssertEqual(value(answer)["fellBack"], .bool(true)); XCTAssertEqual(value(answer)["upgraded"], .bool(false))
        XCTAssertEqual(value(answer)["reachable"], .bool(true))
    }
    // asset-tools.test.ts:229
    func testL229RecordsAFileByReadingItAndSkipsItNextTime() async throws {
        let rig = try S4AssetsRig.make(); defer { rig.dispose() }
        let file = try rig.file("a.jpg", "real bytes")
        let recorded = await record(rig, file.path)
        XCTAssertFalse(recorded.isError, A.error(recorded))
        XCTAssertEqual(value(recorded)["entry"]["digest"], .string(file.digest)); XCTAssertEqual(value(recorded)["entry"]["bytes"], .number(10))
        let decided = await decide(rig)
        XCTAssertEqual(value(decided)["action"], .string("skip")); XCTAssertEqual(value(decided)["reason"], .string("verified"))
        // The ledger is on disk where the run can find it, one JSON line per asset.
        let text = try String(contentsOfFile: rig.runFolder("run-1") + "/ledger.jsonl", encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 1)
    }
    // asset-tools.test.ts:289
    func testL289FetchesAgainWhenTheFileStoppedMatchingAndSaysTheLedgerWasWrong() async throws {
        let rig = try S4AssetsRig.make(); defer { rig.dispose() }
        let file = try rig.file("a.jpg", "real bytes")
        _ = await record(rig, file.path)
        try Data("FAKE BYTES".utf8).write(to: URL(fileURLWithPath: file.path))
        let decided = await decide(rig)
        XCTAssertEqual(value(decided)["action"], .string("fetch")); XCTAssertEqual(value(decided)["reason"], .string("wrong-digest"))
        XCTAssertEqual(value(decided)["ledgerWasWrong"], .bool(true))
        let summaries = await rig.runtime.completedSummaries
        XCTAssertEqual(summaries.last?["ledgerWasWrong"], .bool(true))
    }
    // asset-tools.test.ts:308
    func testL308RefetchModeDoesNotReadTheLedgerEvenForAnAssetItHas() async throws {
        let rig = try S4AssetsRig.make(); defer { rig.dispose() }
        let file = try rig.file("a.jpg", "real bytes")
        _ = await record(rig, file.path)
        let decided = await decide(rig, mode: "refetch")
        XCTAssertEqual(value(decided)["action"], .string("fetch")); XCTAssertEqual(value(decided)["reason"], .string("refetch-requested"))
        XCTAssertEqual(value(decided)["mode"], .string("refetch"))
        XCTAssertEqual(value(decided)["ledgerWasWrong"], .bool(false))
    }
    // asset-tools.test.ts:334
    func testL334VerifyReportsMissingFilesRatherThanACleanRun() async throws {
        let rig = try S4AssetsRig.make(); defer { rig.dispose() }
        let file = try rig.file("a.jpg", "real bytes")
        _ = await record(rig, file.path)
        try FileManager.default.removeItem(atPath: file.path)
        let verdict = await rig.call("assets.ledger", A.o([("runId", .string("run-1")), ("op", .string("verify"))]))
        XCTAssertEqual(value(verdict)["total"], .number(1)); XCTAssertEqual(value(verdict)["ok"], .number(0))
        XCTAssertTrue(value(verdict)["line"].string?.contains("not complete") == true)
        XCTAssertEqual(value(verdict)["missing"].elements?.count, 1)
    }
    // asset-tools.test.ts:351
    func testL351ReadsThePagesOwnTotalAndCallsAShortRunShort() async throws {
        let rig = try S4AssetsRig.make(); defer { rig.dispose() }
        let answer = await rig.call("assets.coverage", A.o([("runId", .string("run-1")), ("captured", .number(24)), ("text", .string("Showing 24 of 340 units")),
                                                            ("pattern", .string(#"of\s+([\d,]+)\s+units"#)), ("what", .string("units"))]))
        XCTAssertFalse(answer.isError, A.error(answer))
        XCTAssertEqual(value(answer)["verdict"], .string("short")); XCTAssertEqual(value(answer)["stated"], .number(340))
        XCTAssertEqual(value(answer)["captured"], .number(24)); XCTAssertEqual(value(answer)["missing"], .number(316))
    }
    // asset-tools.test.ts:362
    func testL362SaysUnknownNotCompleteWhenNothingStatedATotal() async throws {
        let rig = try S4AssetsRig.make(); defer { rig.dispose() }
        let answer = await rig.call("assets.coverage", A.o([("runId", .string("run-1")), ("captured", .number(24)), ("text", .string("A page with no counts on it at all."))]))
        XCTAssertEqual(value(answer)["verdict"], .string("unknown")); XCTAssertEqual(value(answer)["loud"], .bool(true))
        XCTAssertEqual(value(answer)["stated"], .null); XCTAssertEqual(value(answer)["statedFrom"], .string("text"))
    }
    // asset-tools.test.ts:377
    func testL377WritesEveryCheckIntoTheRunAndSummarisesThemAtTheEnd() async throws {
        let rig = try S4AssetsRig.make(); defer { rig.dispose() }
        _ = await rig.call("assets.coverage", A.o([("runId", .string("run-1")), ("captured", .number(24)), ("stated", .number(340))]))
        _ = await rig.call("assets.coverage", A.o([("runId", .string("run-1")), ("captured", .number(10)), ("stated", .number(10))]))
        let summary = await rig.call("assets.coverage", A.o([("runId", .string("run-1")), ("op", .string("summary"))]))
        XCTAssertEqual(value(summary)["ok"], .bool(false)); XCTAssertEqual(value(summary)["short"], .number(1)); XCTAssertEqual(value(summary)["complete"], .number(1))
        XCTAssertEqual(value(summary)["log"], .string(rig.runFolder("run-1") + "/coverage.jsonl"))
        XCTAssertEqual(value(summary)["checks"].elements?.count, 2)
    }
    // asset-tools.test.ts:395
    func testL395WritesTheFileByteForByteRecordsItAndTheSecondCallIsASkip() async throws {
        let rig = try S4AssetsRig.make(); defer { rig.dispose() }
        let url = "https://assets.test/plan.jpg"
        rig.transport.serve(url, bytes: S4AssetsRig.asset)
        let args = A.o([("runId", .string("portal")), ("dir", .string(rig.files)), ("urls", .array([.string(url)]))])
        let answer = await rig.call("assets.fetch", args)
        XCTAssertFalse(answer.isError, A.error(answer))
        let first = value(answer)
        XCTAssertEqual(first["tally"]["fetched"], .number(1)); XCTAssertEqual(first["tally"]["failed"], .number(0)); XCTAssertEqual(first["empty"], .bool(false))
        let row = first["results"].elements?.first
        XCTAssertEqual(row?["outcome"], .string("fetched")); XCTAssertEqual(row?["fetchedUrl"], .string(url))
        let path = row?["path"].string ?? ""
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), S4AssetsRig.asset)
        XCTAssertEqual(row?["digest"], .string(BackendBrowserScrapingIO.digest(S4AssetsRig.asset)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rig.files), ["plan.jpg"])

        let again = await rig.call("assets.fetch", args)
        let second = value(again)
        XCTAssertEqual(second["tally"]["skipped"], .number(1)); XCTAssertEqual(second["empty"], .bool(true))
        XCTAssertTrue(second["emptyReason"].string?.contains("already on") == true); XCTAssertTrue(second["emptyReason"].string?.contains("refetch") == true)
        XCTAssertEqual(rig.transport.requests("GET"), 1)
    }
    // asset-tools.test.ts:433
    func testL433ABatchThatFetchedNothingIsNotAnOrdinaryEmptyAnswer() async throws {
        let rig = try S4AssetsRig.make(); defer { rig.dispose() }
        let answer = await rig.call("assets.fetch", A.o([("runId", .string("portal")), ("dir", .string(rig.files)), ("urls", .array([.string("https://assets.test/missing.jpg")]))]))
        XCTAssertEqual(value(answer)["tally"]["failed"], .number(1)); XCTAssertEqual(value(answer)["empty"], .bool(false))
        XCTAssertTrue(value(answer)["line"].string?.contains("not an empty result") == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rig.files), [])
        XCTAssertEqual(value(answer)["results"].elements?.first?["outcome"], .string("failed"))
    }
    // asset-tools.test.ts:529
    func testL529ListsWhatTheBrowserPhotographedByItself() async throws {
        let rig = try S4AssetsRig.make(); defer { rig.dispose() }
        let evidence = A.o([("requestedUrl", .string("https://portal.test/listings")), ("finalUrl", .string("https://portal.test/listings")), ("httpStatus", .number(429)),
                            ("statusText", .string("Too Many Requests")), ("title", .string("Slow down")), ("text", .string("rate limit exceeded")), ("failed", .null)])
        let verdict = try XCTUnwrap(BackendBrowserScrapingStore.blockVerdict(evidence))
        let row = A.o([("at", .number(5)), ("path", .string("")), ("sidecar", .string("")), ("evidence", evidence), ("verdict", verdict), ("note", .string(""))])
        let folder = rig.userData + "/scrape/blocks/default"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try (String(decoding: try row.encodedJSON(), as: UTF8.self) + "\n").write(toFile: folder + "/blocks.jsonl", atomically: true, encoding: .utf8)
        let answer = await rig.call("assets.blocks", A.o([]))
        XCTAssertEqual(value(answer)["total"], .number(1))
        let shot = value(answer)["shots"].elements?.first
        XCTAssertEqual(shot?["httpStatus"], .number(429)); XCTAssertTrue((shot?["signals"].elements?.count ?? 0) > 0)
        let empty = try S4AssetsRig.make(); defer { empty.dispose() }
        let none = await empty.call("assets.blocks", A.o([]))
        XCTAssertEqual(value(none)["total"], .number(0)); XCTAssertEqual(value(none)["folder"], .string(empty.userData + "/scrape/blocks"))
    }
    // asset-tools.test.ts:590
    func testL590RewritesAnAssetURLForACallThatNamedNoRules() async throws {
        let rig = try S4AssetsRig.make(); defer { rig.dispose() }
        rig.stored.mutate { $0["default"] = A.o([("assets", A.o([("upgrade", A.o([("on", .bool(true)), ("from", .string("/small/")), ("to", .string("/big/"))]))]))]) }
        rig.transport.probeOnly("https://x.test/i/small/a.jpg", length: 20_000)
        rig.transport.probeOnly("https://x.test/i/big/a.jpg", length: 400_000)
        let answer = await rig.call("assets.rendition", A.o([("url", .string("https://x.test/i/small/a.jpg")), ("profileId", .string("default"))]))
        XCTAssertFalse(answer.isError, A.error(answer))
        XCTAssertEqual(value(answer)["url"], .string("https://x.test/i/big/a.jpg")); XCTAssertEqual(value(answer)["upgraded"], .bool(true))
        let named = await rig.call("assets.rendition", A.o([("url", .string("https://x.test/i/small/a.jpg")), ("profileId", .string("default")), ("rules", .array([]))]))
        XCTAssertEqual(value(named)["url"], .string("https://x.test/i/small/a.jpg")); XCTAssertEqual(value(named)["upgraded"], .bool(false))
    }
    // asset-tools.test.ts:657
    func testL657FilesTheRunUnderTheProfileSoItSurvivesARestart() async throws {
        let rig = try S4AssetsRig.make(); defer { rig.dispose() }
        rig.transport.serve("https://assets.test/plan.jpg", bytes: S4AssetsRig.asset)
        let answer = await rig.call("assets.fetch", A.o([("runId", .string("filed")), ("dir", .string(rig.files)),
                                                         ("urls", .array([.string("https://assets.test/plan.jpg")])), ("profileId", .string("default"))]))
        XCTAssertFalse(answer.isError, A.error(answer))
        let onDisk = try String(contentsOfFile: rig.runFolder("filed") + "/profile", encoding: .utf8)
        XCTAssertEqual(onDisk.trimmingCharacters(in: .whitespacesAndNewlines), "default")
        // A brand-new domain over the same data folder (an app restart) still knows the owner.
        let restarted = BackendS4AssetsDomain(userData: URL(fileURLWithPath: rig.userData), transport: rig.transport, profileExists: { _ in true },
                                              settings: { _ in .object([]) }, noteBatch: { _, _ in })
        let owner = try await restarted.runOwner("filed")
        XCTAssertEqual(owner, "default")
        XCTAssertEqual(rig.noted.value, ["default"])
    }
    // asset-tools.test.ts:668
    func testL668ReadsACoverageTotalWithThePatternItsRunsProfileStored() async throws {
        let rig = try S4AssetsRig.make(); defer { rig.dispose() }
        rig.stored.mutate { $0["default"] = A.o([("checks", A.o([("coverage", A.o([("on", .bool(true)), ("pattern", .string(#"of ([\d,]+) plans"#))]))]))]) }
        rig.transport.serve("https://assets.test/plan.jpg", bytes: S4AssetsRig.asset)
        _ = await rig.call("assets.fetch", A.o([("runId", .string("checked")), ("dir", .string(rig.files)),
                                                ("urls", .array([.string("https://assets.test/plan.jpg")])), ("profileId", .string("default"))]))
        let answer = await rig.call("assets.coverage", A.o([("runId", .string("checked")), ("captured", .number(300)), ("text", .string("Showing 1–24 of 16,498 plans"))]))
        XCTAssertFalse(answer.isError, A.error(answer))
        XCTAssertEqual(value(answer)["stated"], .number(16_498)); XCTAssertEqual(value(answer)["verdict"], .string("short"))
        XCTAssertEqual(value(answer)["statedFrom"], .string("text"))
    }
    // Secret hygiene: a presigned URL's signature never appears in a sentence the
    // service writes (the data column keeps the caller's own URL, as the source does).
    func testPresignedSignatureIsKeptOutOfEverySentenceTheServiceWrites() async throws {
        let rig = try S4AssetsRig.make(); defer { rig.dispose() }
        let url = "https://assets.test/missing.jpg?X-Amz-Signature=SECRETSIG&w=1"
        let answer = await rig.call("assets.fetch", A.o([("runId", .string("sig")), ("dir", .string(rig.files)), ("urls", .array([.string(url)]))]))
        let row = value(answer)["results"].elements?.first
        for key in ["line", "reason"] { XCTAssertFalse(row?[key].string?.contains("SECRETSIG") == true, key) }
        XCTAssertFalse(value(answer)["line"].string?.contains("SECRETSIG") == true)
    }
}

/// resolvingSymlinksInPath() turns /private/var back into /var, which is itself a symlink and trips the
/// native no-symlink rules; realpath keeps the real path.
enum BackendServersS4RealTemp {
    static func directory() -> URL {
        let base = FileManager.default.temporaryDirectory.path
        guard let resolved = realpath(base, nil) else { return FileManager.default.temporaryDirectory }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}
