import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// key-reach.test.ts: what an AI app on an access key may reach, bounded by its
/// level, and the two rules decided for keys, through the real Swift gates.

private struct BackendDeckCoreTestPortS1ReachPool: BackendDeckToolsMachinesWorkerPool {
    let taken: BackendDeckCoreSecurityTestBox<[String]>
    func view(context: BackendDeckToolsMachinesContext) async throws -> NativeRPCValue { .object([.init("workers", .array([]))]) }
    func take(profileID: String?, holdMS: NativeRPCValue, context: BackendDeckToolsMachinesContext) async throws -> NativeRPCValue {
        taken.edit { $0.append(context.holder) }
        return .object([.init("ok", .bool(false)), .init("reason", .string("none free"))])
    }
    func release(profileID: String, renew: Bool, holdMS: NativeRPCValue, context: BackendDeckToolsMachinesContext) async throws -> Bool { false }
}
private struct BackendDeckCoreTestPortS1ReachWorkerMetadata: BackendDeckToolsMachinesWorkerMetadata {
    func windowsByWorker(context: BackendDeckToolsMachinesContext) async throws -> [String: String] { [:] }
    func signedInHosts(profileID: String, context: BackendDeckToolsMachinesContext) async throws -> [String] { [] }
}
/// No machine-area channel is answered: every policy ported here decides
/// before reaching one, and reaching one would fail the test loudly.
private struct BackendDeckCoreTestPortS1ReachChannels: BackendDeckToolsMachinesChannels {
    func call(_ channel: String, _ arguments: [NativeRPCValue], context: BackendDeckToolsMachinesContext) async throws -> NativeRPCValue {
        throw BackendDeckToolsSupport.unavailable(channel)
    }
}
private struct BackendDeckCoreTestPortS1ReachShells: BackendDeckToolsMachinesServerShells {
    func openShells() async throws -> [NativeRPCValue] { [] }
    func shellScreen(_ shellID: String) async throws -> String? { nil }
}
/// The caller's kind comes from the authenticated owner; nothing past the
/// identity gate is reachable in the ported case, so the rest answers nothing.
private struct BackendDeckCoreTestPortS1ReachTourRuntime: BackendDeckToolsTourRuntime {
    let kind: String
    func callerKind(_ context: BackendMCPCallContext) async throws -> String { kind }
    func interactiveSetting() async throws -> NativeRPCValue { .missing }
    func authorize(_ context: BackendMCPCallContext, tier: BackendMCPTier, summary: String) async throws {}
    func completed(_ context: BackendMCPCallContext, summary: NativeRPCValue) async throws {}
    func facts(sessionID: String) async throws -> NativeRPCValue? { nil }
    func supports(reason: String, importance: NativeRPCValue, median: Double?, sample: Int) async throws -> Bool { false }
}

/// rigWith(answer) from the source: a dispatcher over two stand-in tools — an
/// alter tool with no exemption (a server terminal) and a read tool whose fill
/// must be answered (saved passwords). A true/false answer is given from the
/// owner's phone; nil means the question is delivered and never answered.
private struct BackendDeckCoreTestPortS1ReachRules: Sendable {
    let control: BackendDeckCoreSecurityControl
    let asked: BackendDeckCoreSecurityTestBox<[BackendDeckCoreSecurityConsentRequest]>
    let ran: BackendDeckCoreSecurityTestBox<[String]>
    let clock: BackendDeckCoreTestPortSecurityClock
}

final class BackendDeckCoreTestPortS1ReachTests: BackendDeckCoreTestPortSecurityCase {
    private func tiers(_ level: String) -> Set<BackendMCPTier> { BackendDeckCoreSecurityAccessKeys.tiersFor(level) }
    private func key(_ level: String, askFirst: Bool? = nil) -> BackendDeckCoreSecurityCaller {
        .init(kind: .key, tiers: tiers(level), keyID: "k1", keyName: "ChatGPT", askFirst: askFirst)
    }
    private var local: BackendDeckCoreSecurityCaller { .init(kind: .local, tiers: tiers("full")) }
    private var remote: BackendDeckCoreSecurityCaller { .init(kind: .remote, tiers: tiers("full"), deviceID: "phone-1") }
    private var session: BackendDeckCoreSecurityCaller { .init(kind: .session, tiers: tiers("work"), sessionID: "s1", machineID: "") }
    private func machines(_ kind: BackendDeckToolsMachinesContext.Kind, key: String? = nil, device: String? = nil) -> BackendDeckToolsMachinesContext {
        .init(kind: kind, attended: true, keyID: key, deviceID: device, rpc: .init(caller: .nativeApp, ownerID: "fixture"),
              startedByCopilot: { _ in false }, noteStarted: { _ in })
    }
    private func machinesSpec(_ id: String) throws -> BackendMCPTool {
        let row = try XCTUnwrap(BackendDeckToolsMachinesCatalogue.rows().first { $0["id"].string == id })
        return try .init(id: id, wireName: XCTUnwrap(row["wire"].string), description: XCTUnwrap(row["description"].string),
                         inputSchema: row["inputSchema"], tier: XCTUnwrap(BackendMCPTier(rawValue: row["tier"].string ?? "")))
    }
    private func rules(answer: Bool?) throws -> BackendDeckCoreTestPortS1ReachRules {
        let clock = BackendDeckCoreTestPortSecurityClock()
        let asked = BackendDeckCoreSecurityTestBox<[BackendDeckCoreSecurityConsentRequest]>([]), ran = BackendDeckCoreSecurityTestBox<[String]>([])
        let broker = BackendDeckCoreSecurityTestBox<BackendDeckCoreSecurityConsentBroker?>(nil)
        let consent = BackendDeckCoreSecurityConsentBroker(timeoutMilliseconds: 50, clock: clock, ask: { question in
            asked.edit { $0.append(question) }
            if let answer { _ = await broker.get()?.respond(id: question.id, approved: answer, by: "device:his-phone") }
            return true
        })
        broker.set(consent)
        let schema = o([("type", .string("object")), ("properties", o([("action", o([("type", .string("string"))]))])), ("additionalProperties", .bool(false))])
        func tool(_ id: String, tier: BackendMCPTier, ownerMustAnswer: (@Sendable (NativeRPCValue) throws -> Bool)? = nil) throws -> BackendDeckCoreSecurityToolPolicy {
            BackendDeckCoreSecurityToolPolicy(tool: try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: id, inputSchema: schema, tier: tier),
                summary: { _, _ in "Run \(id)" }, ownerMustAnswer: ownerMustAnswer,
                run: { _, _ in ran.edit { $0.append(id) }; return .init(value: .object([.init("ok", .bool(true))]), summary: .object([])) })
        }
        // The same predicate as the source's fillMustBeAnswered: args.action === 'fill'.
        let policies = [try tool("servers.shellish", tier: .alter), try tool("browser.passwordsish", tier: .read, ownerMustAnswer: { $0["action"].string == "fill" })]
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: try scratch(), now: { clock.now() }), consent: consent, policies: policies, now: { clock.now() })
        return .init(control: control, asked: asked, ran: ran, clock: clock)
    }
    private var fill: V { o([("action", .string("fill"))]) }

    // who acts as the owner
    func testKeyReachL50() {
        XCTAssertTrue(local.actsAsOwner)
        XCTAssertTrue(key("look").actsAsOwner)
        XCTAssertFalse(remote.actsAsOwner)
        XCTAssertFalse(session.actsAsOwner)
    }

    // the gates that used to say "local only"
    func testKeyReachL59() {
        let keyed = key("look"), paired = remote, inSession = session
        XCTAssertNoThrow(try BackendDeckCoreArguments.hereOnly(keyed, what: "Looking at the other computers"))
        assertError({ try BackendDeckCoreArguments.hereOnly(paired, what: "Looking at the other computers") }, contains: "A paired device cannot")
        XCTAssertThrowsError(try BackendDeckCoreArguments.hereOnly(inSession, what: "Looking at the other computers"))
    }
    /// contextFor(caller, attended) from the source: browser-tools.ts's
    /// callingSession is the caller's own session, and nobody else has one.
    func testKeyReachL65() {
        func mayDrive(_ caller: BackendDeckCoreSecurityCaller, attended: Bool = true) throws {
            try BackendBrowserService.mayDrive(tool: "browser.open", callingSession: caller.kind == .session ? caller.sessionID : nil,
                                               actsAsOwner: caller.actsAsOwner, attended: attended)
        }
        let keyed = key("work"), paired = remote
        XCTAssertNoThrow(try mayDrive(keyed))
        assertError({ try mayDrive(paired) }, contains: "only works for the person")
        assertError({ try mayDrive(keyed, attended: false) }, contains: "nobody at the machine")
    }
    func testKeyReachL71() throws {
        let taken = BackendDeckCoreSecurityTestBox<[String]>([])
        let workers = BackendDeckToolsMachinesWorkers(pool: BackendDeckCoreTestPortS1ReachPool(taken: taken), metadata: BackendDeckCoreTestPortS1ReachWorkerMetadata())
        let spec = try machinesSpec("browser.worker"), args = o([("action", .string("take"))])
        let keyed = machines(.key, key: "k1"), paired = machines(.remote, device: "phone-1")
        XCTAssertNoThrow(try workers.policy(spec, args, keyed))
        assertError({ _ = try workers.policy(spec, args, paired) }, contains: "only works for the person")
    }
    func testKeyReachL86() {
        let keyed = BackendDeckToolsSessionsCaller(kind: .key, keyName: "ChatGPT", callID: "c")
        let paired = BackendDeckToolsSessionsCaller(kind: .remote, deviceID: "phone-1", callID: "c")
        XCTAssertNoThrow(try BackendDeckToolsSessionsArea.mayAskLift(caller: keyed, attended: true))
        assertError({ try BackendDeckToolsSessionsArea.mayAskLift(caller: paired, attended: true) }, contains: "paired device")
        XCTAssertEqual(BackendDeckToolsSessionsArea.askerName(caller: keyed, slots: []), "“ChatGPT”, an AI app you gave a key to")
    }
    func testKeyReachL105() async throws {
        let r = BackendDeckToolsRootPortTourSupport.rig(); defer { r.dispose() }
        let runtime = BackendDeckCoreTestPortS1ReachTourRuntime(kind: BackendDeckCoreSecurityCaller.Kind.key.rawValue)
        let definition = try XCTUnwrap(BackendDeckToolsTourTool.definitions(stage: r.stage, runtime: runtime).first)
        let context = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true,
            allowedTools: ["tour.play"], allowedTiers: tiers("full"), cancellation: .init())
        let reply = try await definition.handler(context, o([("question", .string("what happened")), ("stops", .array([]))]))
        XCTAssertTrue(reply.isError)
        XCTAssertTrue(reply.content.first?["text"].string?.contains("only runs for the person sitting at this machine") == true, reply.content.first?["text"].string ?? "")
        let driving = await r.stage.driving(); XCTAssertFalse(driving)
    }

    // what a key reaches is still bounded by its level
    func testKeyReachL120() async throws {
        let f = try rig(), keys = BackendDeckCoreSecurityAccessKeys(directory: try scratch())
        let created = try await made(keys, name: "x", level: "look"), id = try XCTUnwrap(created["view"]["id"].string)
        let caller = await keys.caller(id: id, nameAtArrival: "x")
        XCTAssertEqual(caller.askFirst, true)
        let result = await f.call("settings.write", o([("scope", .string("settings")), ("patch", o([("appearance.density", .string("compact"))]))]), .init(caller: caller))
        XCTAssertEqual(result.refusal, .notGranted)
        XCTAssertTrue(f.surface.settingsTrace.isEmpty, "\(f.surface.settingsTrace)")
    }

    // a saved-password fill is always put to the owner
    func testKeyReachL179() async throws {
        let r = try rules(answer: true)
        let result = await r.control.call(name: "browser.passwordsish", arguments: fill, options: .init(caller: key("full", askFirst: false)))
        XCTAssertEqual(r.asked.get().map(\.tool), ["browser.passwordsish"])
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertEqual(result.row["confirmed"]["by"], .string("device:his-phone"))
    }
    func testKeyReachL189() async throws {
        let r = try rules(answer: nil), args = fill, full = key("full", askFirst: false)
        let pending = Task { await r.control.call(name: "browser.passwordsish", arguments: args, options: .init(caller: full)) }
        await r.clock.scheduled.wait(1); r.clock.advance(50)
        let silent = await pending.value
        XCTAssertEqual(silent.refusal, .timeout)
        let work = await r.control.call(name: "browser.passwordsish", arguments: args, options: .init(caller: key("work", askFirst: false)))
        XCTAssertEqual(work.refusal, .notGranted)
        XCTAssertEqual(r.ran.get(), [])
    }
    func testKeyReachL199() async throws {
        let r = try rules(answer: nil)
        let listed = await r.control.call(name: "browser.passwordsish", arguments: o([("action", .string("list"))]), options: .init(caller: key("look")))
        XCTAssertTrue(listed.ok, listed.error ?? "")
        XCTAssertTrue(r.asked.get().isEmpty)
    }

    // a server terminal needs Full control and honours ask-first
    func testKeyReachL209() async throws {
        let r = try rules(answer: true)
        let result = await r.control.call(name: "servers.shellish", arguments: .object([]), options: .init(caller: key("work")))
        XCTAssertEqual(result.refusal, .notGranted)
    }
    func testKeyReachL216() async throws {
        let r = try rules(answer: true)
        let result = await r.control.call(name: "servers.shellish", arguments: .object([]), options: .init(caller: key("full", askFirst: true)))
        XCTAssertEqual(r.asked.get().count, 1)
        XCTAssertTrue(result.ok, result.error ?? "")
    }
    func testKeyReachL224() async throws {
        let r = try rules(answer: nil)
        let result = await r.control.call(name: "servers.shellish", arguments: .object([]), options: .init(caller: key("full", askFirst: false)))
        XCTAssertTrue(r.asked.get().isEmpty)
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertEqual(result.row["confirmed"]["by"], .string("standing:key:k1"))
    }

    // the real tools carry the flags the stand-ins above assume
    /// The Swift saved-login fill is built with ownerMustAnswer by
    /// BackendBrowserProfilesChannels.fillOperation; every other action by
    /// passwordOperation, the operation browser.passwords checks. `{}` is read
    /// the way the tool reads it (readAction: no action means list).
    func testKeyReachL242() throws {
        let request = BackendBrowserPasswordFill(tabID: "t1", profileID: "p1", origin: "https://portal.example", documentID: "d1", username: "me")
        let operation = BackendBrowserProfilesChannels.fillOperation(request)
        XCTAssertTrue(operation.ownerMustAnswer)
        XCTAssertEqual(operation.action, "fill")
        XCTAssertEqual(operation.tier, .alter)
        let list = o([("action", .string("list"))]), none = o([])
        XCTAssertFalse(try BackendBrowserProfilesChannels.passwordOperation(action: try BackendBrowserProfilesToolFactories.readAction(list, domain: "passwords"),
                                                                            arguments: list, profileID: "p1").ownerMustAnswer)
        let unnamed = try BackendBrowserProfilesToolFactories.readAction(none, domain: "passwords")
        XCTAssertFalse(try BackendBrowserProfilesChannels.passwordOperation(action: unnamed, arguments: none, profileID: "p1").ownerMustAnswer)
    }
    func testKeyReachL249() async throws {
        let spec = try machinesSpec("servers.shell")
        XCTAssertEqual(spec.tier, .alter)
        let servers = BackendDeckToolsMachinesServers(channels: BackendDeckCoreTestPortS1ReachChannels(), shells: BackendDeckCoreTestPortS1ReachShells(),
            dataRoot: URL(fileURLWithPath: "/fixture/data"), home: URL(fileURLWithPath: "/fixture/home"))
        for context in [machines(.local), machines(.key, key: "k1")] {
            let policy = try await servers.policy(spec, o([("do", .string("open")), ("serverId", .string("s1"))]), context)
            XCTAssertEqual(policy.tier, .alter)
            XCTAssertFalse(policy.ownerMustAnswer)
        }
    }
    func testKeyReachL255() async throws {
        let keyed = machines(.key, key: "k1"), showCode = o([("do", .string("show-code"))])
        let remoteArea = BackendDeckToolsMachinesRemote(channels: BackendDeckCoreTestPortS1ReachChannels())
        let remotePolicy = try await remoteArea.policy(try machinesSpec("remote.manage"), showCode, keyed)
        XCTAssertTrue(remotePolicy.ownerMustAnswer, "remote.manage")
        let area = BackendDeckToolsMachinesArea(channels: BackendDeckCoreTestPortS1ReachChannels(), stateWaiter: .init(registry: .init()), watch: .init(),
            dataRoot: URL(fileURLWithPath: "/fixture/data"), home: URL(fileURLWithPath: "/fixture/home"))
        let machinesPolicy = try await area.policy(try machinesSpec("machines.manage"), showCode, keyed)
        XCTAssertTrue(machinesPolicy.ownerMustAnswer, "machines.manage")
    }
}
