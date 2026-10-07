import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// empty-result.test.ts: the gate over every tool that round added. None of them
/// may answer nothing quietly, and none may be added without saying how it
/// answers nothing.
///
/// The Swift homes of the source's four factories, each driven through its own
/// door with deps that answer successfully and answer with nothing:
///  - asset-tools.ts -> BackendDeckToolsAssets over the REAL BackendS4AssetsDomain
///    (S4AssetsRig: real ledger/coverage/blocks files, only the network faked);
///  - worker-tools.ts -> BackendDeckToolsMachinesWorkers.definitions plus the
///    browser.lift_request definition (BackendDeckToolsSessionsArea.liftDefinitions
///    over the REAL BackendBrowserWorkersLiftRequests inbox);
///  - store-tools.ts -> BackendDeckToolsAppExtraction.definitions;
///  - browser-network-tool.ts -> BackendBrowserNetworkCapture, the browser.network
///    body behind BackendBrowserScrapingMCP, over a REAL BackendBrowserScrapingStore.
/// The action-log row's `result` is the summary each family hands its log hook
/// (runtime.completed / environment.execute / runtime.recordResult / access.record).

private let S1EmptyNow: Double = 1_700_000_000_000

/// One call's answer, in CallResult's terms.
struct BackendDeckCoreTestPortS1EmptyAnswer: Sendable {
    let ok: Bool
    let error: String
    let value: NativeRPCValue
    /// What the family's log hook recorded for this call. nil when the door
    /// records no result summary (browser.network: BackendBrowserScrapingMCP's
    /// gate authorizes before the call and has no completion hook).
    let row: NativeRPCValue?
}

/// The source harness's WorkerToolDeps: list, pace, take, release, renew.
private final class BackendDeckCoreTestPortS1EmptyWorkers: BackendDeckToolsMachinesWorkerPool, BackendDeckToolsMachinesWorkerMetadata, @unchecked Sendable {
    private let lock = NSLock()
    private let workers: [NativeRPCValue]
    private var held: [String: String] = [:]
    init(workers: [NativeRPCValue]) { self.workers = workers }
    func view(context: BackendDeckToolsMachinesContext) async throws -> NativeRPCValue {
        .object([.init("workers", .array(workers)), .init("pace", .object([
            .init("maxConcurrent", .number(2)), .init("minDelayMs", .number(0)), .init("jitterMs", .number(0))]))])
    }
    func take(profileID: String?, holdMS: NativeRPCValue, context: BackendDeckToolsMachinesContext) async throws -> NativeRPCValue {
        let wanted = profileID ?? workers.first?["profileId"].string
        guard let chosen = workers.first(where: { $0["profileId"].string == wanted }), let id = chosen["profileId"].string else {
            return .object([.init("ok", .bool(false)), .init("reason", .string("there is no worker free."))])
        }
        lock.withLock { held[id] = context.holder }
        return .object([.init("ok", .bool(true)), .init("profileId", .string(id)), .init("name", chosen["name"]),
                        .init("pacedMs", .number(0)), .init("expiresAt", .number(S1EmptyNow + 120_000))])
    }
    func release(profileID: String, renew: Bool, holdMS: NativeRPCValue, context: BackendDeckToolsMachinesContext) async throws -> Bool {
        lock.withLock {
            guard held[profileID] == context.holder else { return false }
            if !renew { held[profileID] = nil }
            return true
        }
    }
    func windowsByWorker(context: BackendDeckToolsMachinesContext) async throws -> [String: String] { [:] }
    func signedInHosts(profileID: String, context: BackendDeckToolsMachinesContext) async throws -> [String] { [] }
}

/// DeckControl's gate for the machine-area definitions: the caller is the
/// person here (the source's deck.call with no options), every question is
/// answered yes, and the result summary is the logged row.
private actor BackendDeckCoreTestPortS1EmptyMachines: BackendDeckToolsMachinesEnvironment {
    let log: BackendDeckCoreSecurityTestBox<[NativeRPCValue]>
    init(log: BackendDeckCoreSecurityTestBox<[NativeRPCValue]>) { self.log = log }
    func context(for call: BackendMCPCallContext) -> BackendDeckToolsMachinesContext {
        .init(kind: .local, attended: call.attended, rpc: .init(caller: .nativeApp, ownerID: "fixture"),
              startedByCopilot: { _ in false }, noteStarted: { _ in })
    }
    func validate(arguments: NativeRPCValue, schema: NativeRPCValue) throws { try BackendDeckCoreCatalogueSchema.check(schema: schema, arguments: arguments) }
    func execute(context: BackendDeckToolsMachinesContext, policy: BackendDeckToolsMachinesPolicy,
                 operation: @escaping @Sendable () async throws -> BackendDeckToolsMachinesOutput) async throws -> BackendMCPToolReply {
        let result = try await operation()
        log.edit { $0.append(result.summary) }
        return .value(result.value)
    }
    func failed(call: BackendMCPCallContext, tool: BackendMCPTool, policy: BackendDeckToolsMachinesPolicy?,
                loggedArguments: NativeRPCValue, error: any Error) -> BackendMCPToolReply {
        BackendDeckToolsMachinesFactory.failureReply(error)
    }
}

/// The source harness's drive for store-tools: portal.example, a page whose
/// recipe matches `rows` rows (none unless a case says otherwise).
private actor BackendDeckCoreTestPortS1EmptyExtraction: BackendDeckToolsAppExtractionService {
    let recipes: [NativeRPCValue], rows: Int
    init(recipes: [NativeRPCValue], rows: Int) { self.recipes = recipes; self.rows = rows }
    func installed() -> [NativeRPCValue] { recipes }
    func origin(_ caller: BackendMCPCallContext, arguments: NativeRPCValue) -> String? { "https://portal.example" }
    func extract(_ caller: BackendMCPCallContext, arguments: NativeRPCValue, recipe: NativeRPCValue, limit: Int?) -> NativeRPCValue {
        .object([.init("url", .string("https://portal.example/list")), .init("title", .string("Listings")),
                 .init("fields", .object([.init("headline", rows == 0 ? .null : .string("Listings"))])),
                 .init("rows", .array(Array(repeating: NativeRPCValue.object([.init("price", .string("1"))]), count: rows))),
                 .init("rowsOnPage", .number(Double(rows))), .init("rowsReturned", .number(Double(rows))),
                 .init("counts", .object([])), .init("stated", .null), .init("next", .null)])
    }
}

/// harness(options) from the source: one bench carrying all ten tools.
final class BackendDeckCoreTestPortS1EmptyBench: @unchecked Sendable {
    typealias V = NativeRPCValue
    static let recipeText = #"{"id":"demo","name":"Demo","summary":"A recipe for the tests.","version":"1.0.0","grants":["page-read"],"origins":["portal.example"],"fields":[{"name":"headline","selector":"h1","op":"text"}],"rows":{"selector":".row","fields":[{"name":"price","selector":".p","op":"text"}]}}"#
    static func aWorker() -> V {
        .object([.init("profileId", .string("w1")), .init("name", .string("Worker 1")), .init("partition", .string("persist:w1")),
                 .init("busy", .bool(false)), .init("holder", .string("")), .init("readyInMs", .number(0))])
    }
    let assets: S4AssetsRig
    let definitions: [BackendDeckToolsDefinition]
    let network: BackendBrowserNetworkCapture
    let networkSpec: BackendMCPTool
    private let scratch: URL
    private let machinesLog: BackendDeckCoreSecurityTestBox<[V]>, storeLog: BackendDeckCoreSecurityTestBox<[V]>
    private let sessions: BackendDeckCoreTestPortSessionsFixture
    private let workerIDs: Set<String>
    var specs: [BackendMCPTool] { definitions.map(\.spec) + [networkSpec] }
    var userData: String { assets.files }

    init(workers: [V] = [], installed: [V]? = nil, rows: Int = 0) throws {
        let assets = try S4AssetsRig.make()
        let machinesLog = BackendDeckCoreSecurityTestBox<[V]>([]), storeLog = BackendDeckCoreSecurityTestBox<[V]>([])
        let pool = BackendDeckCoreTestPortS1EmptyWorkers(workers: workers)
        let sessions = BackendDeckCoreTestPortSessionsFixture()
        let inbox = BackendBrowserWorkersLiftRequests(profiles: { _ in [.init(id: "p-default", name: "Default"), .init(id: "w1", name: "Worker 1")] },
                                                      authorize: { _, _, _, _, _ in }, changed: {})
        let lift = try BackendDeckToolsSessionsArea.liftDefinitions(runtime: sessions, requests: BackendDeckCoreTestPortSessionsLiftBridge(inbox: inbox))
        let workerDefinitions = try BackendDeckToolsMachinesWorkers(pool: pool, metadata: pool)
            .definitions(environment: BackendDeckCoreTestPortS1EmptyMachines(log: machinesLog), liftRequest: lift)
        let recipes = try installed ?? [V.parseJSON(Data(Self.recipeText.utf8))]
        let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: .local) },
            knownFolder: { _, _ in throw BackendDeckToolsSupport.unavailable("known folders") },
            session: { _, _ in throw BackendDeckToolsSupport.unavailable("sessions") },
            runnableProject: { _, _ in throw BackendDeckToolsSupport.unavailable("projects") },
            rpc: { _ in .init(caller: .nativeApp, ownerID: "fixture") },
            authorize: { _, _, _, _, _, _ in }, record: { _, _, _, summary in storeLog.edit { $0.append(summary) } }, now: { S1EmptyNow })
        let extract = try BackendDeckToolsAppExtraction.definitions(service: BackendDeckCoreTestPortS1EmptyExtraction(recipes: recipes, rows: rows), access: access)
        let scraping = FileManager.default.temporaryDirectory.appendingPathComponent("S1h-empty-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scraping, withIntermediateDirectories: true)
        self.scratch = scraping
        let page = try XCTUnwrap(URL(string: "https://portal.example/list"))
        let finish = BackendBrowserCaptureFinish(pageURL: page.absoluteString, title: "Listings", tabClosed: false)
        self.network = BackendBrowserNetworkCapture(store: BackendBrowserScrapingStore(dataRoot: scraping, changed: { _ in }), hooks: .init(
            target: { _, _ in BackendBrowserCaptureTarget(tabID: "tab-1", profileID: "default", pageURL: page, title: "Listings") },
            observe: { _, _, _ in BackendBrowserNetworkObservation(stop: { finish }, retire: { finish }, diagnostics: { .object([]) }) },
            authorize: { _, _, _, _, _ in }))
        self.networkSpec = try XCTUnwrap(BackendBrowserScrapingMCP.tools().first { $0.id == "browser.network" })
        self.assets = assets; self.machinesLog = machinesLog; self.storeLog = storeLog; self.sessions = sessions
        self.workerIDs = Set(workerDefinitions.map(\.spec.id)).subtracting(lift.map(\.spec.id))
        self.definitions = assets.definitions + workerDefinitions + extract
    }
    func dispose() { assets.dispose(); try? FileManager.default.removeItem(at: scratch) }

    private func logged(_ id: String) async -> [V] {
        if BackendDeckToolsAssets.toolNames.contains(id) { return await assets.runtime.completedSummaries }
        if workerIDs.contains(id) { return machinesLog.get() }
        if id == "browser.extract" { return storeLog.get() }
        return sessions.results.map(\.summary)
    }
    /// deck.call(name, args): the schema gate, then the tool's own door.
    func call(_ id: String, _ args: V) async -> BackendDeckCoreTestPortS1EmptyAnswer {
        if id == networkSpec.id {
            do {
                try BackendDeckCoreCatalogueSchema.check(tool: networkSpec, arguments: args)
                let value = try await network.invoke(args, caller: .init(ownerID: "local", attended: true, remote: false))
                return .init(ok: true, error: "", value: value, row: nil)
            } catch { return .init(ok: false, error: error.localizedDescription, value: .missing, row: nil) }
        }
        guard let definition = definitions.first(where: { $0.spec.id == id }) else {
            return .init(ok: false, error: "there is no tool called \(id)", value: .missing, row: nil)
        }
        let before = await logged(id).count
        let context = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true,
            allowedTools: Set(specs.map(\.id)), allowedTiers: [.read, .act, .alter], cancellation: .init())
        let reply: BackendMCPToolReply
        do {
            try BackendDeckCoreCatalogueSchema.check(tool: definition.spec, arguments: args)
            reply = try await definition.handler(context, args)
        } catch { return .init(ok: false, error: error.localizedDescription, value: .missing, row: nil) }
        let after = await logged(id)
        return .init(ok: !reply.isError, error: reply.structuredContent?["error"].string ?? reply.content.first?["text"].string ?? "",
                     value: reply.structuredContent ?? .missing, row: after.count > before ? after.last : nil)
    }
}

/// One nothing-found case: what state the call is made in, whether it found
/// nothing, and (when it cannot be empty) why.
struct BackendDeckCoreTestPortS1EmptyCase {
    let id: String
    /// The `action`/`op` this case is about, or "" for a tool with no modes.
    let mode: String
    let label: String
    let empty: Bool
    let why: String?
    /// False only where the Swift door records no result summary to read.
    var logged: Bool = true
    let run: () async throws -> BackendDeckCoreTestPortS1EmptyAnswer
    var key: String { mode.isEmpty ? id : "\(id):\(mode)" }
}

final class BackendDeckCoreTestPortS1EmptyResultTests: XCTestCase {
    private typealias V = NativeRPCValue
    private typealias Bench = BackendDeckCoreTestPortS1EmptyBench
    private func o(_ fields: [(String, V)]) -> V { .object(fields.map { .init($0.0, $0.1) }) }
    private func harness(workers: [V] = [], installed: [V]? = nil, rows: Int = 0) throws -> Bench {
        let bench = try Bench(workers: workers, installed: installed, rows: rows)
        addTeardownBlock { bench.dispose() }
        return bench
    }

    /// The modes a tool takes, read off its own schema: the `action` or `op` enum.
    private func modesOf(_ schema: V) -> [String] {
        let properties = schema["properties"]
        guard properties.fields != nil else { return [] }
        for key in ["action", "op"] {
            if let values = properties[key]["enum"].elements { return values.map { $0.string ?? $0.compact } }
        }
        return []
    }
    /// Every (tool, mode) pair the code itself offers a caller.
    private func required() throws -> [String] {
        let bench = try harness()
        var keys: [String] = []
        for spec in bench.specs {
            let modes = modesOf(spec.inputSchema)
            if modes.isEmpty { keys.append(spec.id) } else { keys += modes.map { "\(spec.id):\($0)" } }
        }
        return keys.sorted()
    }

    private var cases: [BackendDeckCoreTestPortS1EmptyCase] {
        [
            .init(id: "assets.fetch", mode: "", label: "a batch where every fetch failed is a failure, not an emptiness", empty: false,
                  why: "Zero files written has two opposite causes and this is the one that must never read as nothing-to-do: \"all of them failed\" and \"all of them were already here\" both produce no files, and filing the first as the second is how a run that saved nothing gets recorded as a resume. So a batch that tried and failed carries empty: false and says so; only a batch the ledger skipped in full is empty, and its sentence names `mode: refetch` as the way to mean it.",
                  run: { [unowned self] in
                      // The source points dir at /tmp and nothing is ever written; here a scratch folder.
                      let bench = try harness()
                      return await bench.call("assets.fetch", o([("runId", .string("r-fetch")), ("dir", .string(bench.userData + "/empty-result-fetch")),
                                                                 ("urls", .array([.string("https://x.test/a.jpg")]))]))
                  }),
            .init(id: "assets.rendition", mode: "", label: "no candidate answered, not even the original", empty: true, why: nil,
                  run: { [unowned self] in try await harness().call("assets.rendition", o([("url", .string("https://x.test/a/small.jpg"))])) }),
            .init(id: "assets.ledger", mode: "decide", label: "a decision is always a finding, skip most of all", empty: false,
                  why: "decide answers fetch or skip and both are answers. `skip` is the one that cost him 48,473 assets, so it is the last thing that should read as nothing having happened.",
                  run: { [unowned self] in try await harness().call("assets.ledger", o([("runId", .string("r-decide")), ("op", .string("decide")), ("url", .string("https://x.test/a.jpg"))])) }),
            .init(id: "assets.ledger", mode: "record", label: "a recorded entry is a written row", empty: false,
                  why: "record stats and hashes the file before it writes anything, and refuses when it cannot. Reaching the result means a row exists.",
                  run: { [unowned self] in
                      let bench = try harness()
                      // aFile(): a file to point the ledger at, since it fingerprints what it is given.
                      let path = bench.userData + "/photo.jpg"
                      try Data(repeating: 7, count: 64).write(to: URL(fileURLWithPath: path))
                      return await bench.call("assets.ledger", o([("runId", .string("r-record")), ("op", .string("record")), ("url", .string("https://x.test/a.jpg")), ("path", .string(path))]))
                  }),
            .init(id: "assets.ledger", mode: "verify", label: "a ledger with no entries verifies nothing", empty: true, why: nil,
                  run: { [unowned self] in try await harness().call("assets.ledger", o([("runId", .string("r-verify")), ("op", .string("verify"))])) }),
            .init(id: "assets.ledger", mode: "summary", label: "a ledger nobody ever wrote to", empty: true, why: nil,
                  run: { [unowned self] in try await harness().call("assets.ledger", o([("runId", .string("r-tally")), ("op", .string("summary"))])) }),
            .init(id: "assets.coverage", mode: "check", label: "the page stated no total, so there was nothing to compare against", empty: true, why: nil,
                  run: { [unowned self] in try await harness().call("assets.coverage", o([("runId", .string("r-cover")), ("op", .string("check")), ("captured", .number(24)),
                                                                                         ("text", .string("Properties for sale in the marina"))])) }),
            .init(id: "assets.coverage", mode: "summary", label: "a run in which no page was ever checked", empty: true, why: nil,
                  run: { [unowned self] in try await harness().call("assets.coverage", o([("runId", .string("r-cover-2")), ("op", .string("summary"))])) }),
            .init(id: "assets.blocks", mode: "", label: "nothing has been photographed refusing us", empty: true, why: nil,
                  run: { [unowned self] in try await harness().call("assets.blocks", o([])) }),
            .init(id: "browser.workers", mode: "", label: "there is no worker profile at all", empty: true, why: nil,
                  run: { [unowned self] in try await harness().call("browser.workers", o([])) }),
            .init(id: "browser.worker", mode: "take", label: "a hold is a thing, with or without a window on it", empty: false,
                  why: "take either hands back a hold that stops every other agent taking the same jar, or is refused. A hold with no window of yours attached is a partial state, not an empty one, and `note` says which.",
                  run: { [unowned self] in try await harness(workers: [Bench.aWorker()]).call("browser.worker", o([("action", .string("take"))])) }),
            .init(id: "browser.worker", mode: "release", label: "it was handed back, or the call was refused", empty: false,
                  why: "release answers true or the tool refuses. There is no third outcome to be empty about.",
                  run: { [unowned self] in
                      let bench = try harness(workers: [Bench.aWorker()])
                      _ = await bench.call("browser.worker", o([("action", .string("take"))]))
                      return await bench.call("browser.worker", o([("action", .string("release")), ("worker", .string("Worker 1"))]))
                  }),
            .init(id: "browser.worker", mode: "renew", label: "the hold was extended, or the call was refused", empty: false,
                  why: "renew answers true or the tool refuses, the same as release.",
                  run: { [unowned self] in
                      let bench = try harness(workers: [Bench.aWorker()])
                      _ = await bench.call("browser.worker", o([("action", .string("take"))]))
                      return await bench.call("browser.worker", o([("action", .string("renew")), ("worker", .string("Worker 1"))]))
                  }),
            .init(id: "browser.lift_request", mode: "", label: "an ask was filed, or the call was refused with the reason", empty: false,
                  why: "filing either lands one row in the person\u{2019}s inbox (or re-finds the identical row already waiting, and says repeated) or the tool refuses with a sentence \u{2014} an unknown profile, a full inbox, no workers. There is no third outcome to be empty about.",
                  run: { [unowned self] in try await harness(workers: [Bench.aWorker()]).call("browser.lift_request", o([("from", .string("Default"))])) }),
            .init(id: "browser.extract", mode: "", label: "nothing is installed, so there is nothing to run", empty: true, why: nil,
                  run: { [unowned self] in try await harness(installed: []).call("browser.extract", o([])) }),
            .init(id: "browser.extract", mode: "", label: "the recipe ran and matched nothing on the page", empty: true, why: nil,
                  run: { [unowned self] in try await harness(rows: 0).call("browser.extract", o([("tool", .string("demo"))])) }),
            // The source starts with rules {image: 'fulfill'}. WebKit cannot pause or fulfill a
            // request, so the Swift start deliberately refuses every block/fulfill rule
            // (BackendBrowserScrapingMCP: "Unsupported block/fulfill rules are refused, never
            // silently armed"); the one start it performs arms capture, so that is the start here.
            .init(id: "browser.network", mode: "start", label: "a start that would arm nothing is refused, never performed", empty: false,
                  why: "the precheck refuses a start with capture off (and any block or fulfill rule, which WebKit cannot honour), so every start that returns armed something. See BackendBrowserNetworkCapture.start.",
                  logged: false, run: { [unowned self] in try await harness().call("browser.network", o([("action", .string("start")), ("capture", .bool(true))])) }),
            .init(id: "browser.network", mode: "status", label: "nothing is armed on this page", empty: true, why: nil,
                  logged: false, run: { [unowned self] in try await harness().call("browser.network", o([("action", .string("status"))])) }),
            // The source's drive hands back an armed status on disarm; the real capture has to be armed first.
            .init(id: "browser.network", mode: "stop", label: "it was armed and the page was silent", empty: true, why: nil,
                  logged: false, run: { [unowned self] in
                      let bench = try harness()
                      let armed = await bench.call("browser.network", o([("action", .string("start")), ("capture", .bool(true))]))
                      guard armed.ok else { return armed }
                      return await bench.call("browser.network", o([("action", .string("stop"))]))
                  }),
        ]
    }

    // every new tool answers nothing out loud
    func testEmptyResultL484() throws {
        let covered = Set(cases.map(\.key))
        let missing = try required().filter { !covered.contains($0) }
        XCTAssertEqual(missing, [], "these calls do not say what they answer when they find nothing — add a case to cases in BackendDeckCoreTestPortS1EmptyResultTests.swift")
    }
    func testEmptyResultL499() throws {
        // A case naming a renamed tool is a test that runs, passes, and guards a door that was moved.
        let required = Set(try required())
        XCTAssertEqual(cases.map(\.key).filter { !required.contains($0) }, [])
    }
    func testEmptyResultL506() {
        for entry in cases where !entry.empty {
            XCTAssertNotEqual(entry.why ?? "", "", "\(entry.key) claims it cannot be empty and does not say why")
        }
    }
    func testEmptyResultL516() async throws {
        for entry in cases {
            let name = entry.empty ? "\(entry.key) says it found nothing — \(entry.label)" : "\(entry.key) carries empty: false — \(entry.label)"
            let result = try await entry.run()
            XCTAssertTrue(result.ok, "\(name): \(entry.key) was refused: \(result.error)")
            let value = result.value
            // Present, on every result, whichever way it went.
            XCTAssertNotEqual(value["empty"], .missing, name)
            XCTAssertEqual(value["empty"], .bool(entry.empty), name)
            if entry.empty {
                // And a sentence naming what produced nothing and what would change it.
                let reason = value["emptyReason"].string
                XCTAssertNotNil(reason, name)
                XCTAssertGreaterThan(reason?.utf16.count ?? 0, 40, name)
            } else {
                XCTAssertEqual(value["emptyReason"], .string(""), name)
            }
            // The action log carries it too. browser.network's Swift door has no result summary to log.
            if entry.logged { XCTAssertEqual(result.row?["empty"], .bool(entry.empty), "\(name): logged row \(result.row?.compact ?? "none")") }
        }
    }
}
