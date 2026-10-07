import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Delegated effective policy gate (prepared effect) and the authenticated
/// tools/call exchange: exactly once, bound to its call, expiring with it.
final class BackendDeckCoreSecurityEffectTests: XCTestCase {
    private struct Rig {
        let control: BackendDeckCoreSecurityControl
        let log: BackendDeckCoreSecurityActionLog
        let asked: BackendDeckCoreSecurityTestBox<Int>
    }
    /// approve: true = the window approves, false = no approver, nil = never answered.
    private func rig(approve: Bool?, budgets: BackendDeckCoreSecurityBudgets = .init()) throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckCoreSecurityEffect-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let log = BackendDeckCoreSecurityActionLog(directory: dir)
        let asked = BackendDeckCoreSecurityTestBox<Int>(0)
        let holder = BackendDeckCoreSecurityTestBox<BackendDeckCoreSecurityConsentBroker?>(nil)
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { question in
            asked.edit { $0 += 1 }
            guard let approve else { return true }
            guard approve else { return false }
            let current = holder.get()
            Task { _ = await current?.respond(id: question.id, approved: true, by: "window") }
            return true
        })
        holder.set(broker)
        let control = try BackendDeckCoreSecurityControl(log: log, consent: broker, budgets: budgets, checkArguments: { _, _ in })
        return .init(control: control, log: log, asked: asked)
    }
    private func tool(_ id: String, tier: BackendMCPTier,
                      redact: (@Sendable (NativeRPCValue) throws -> NativeRPCValue)? = nil,
                      run: @escaping BackendDeckCoreSecurityToolPolicy.Handler) throws -> BackendDeckCoreSecurityToolPolicy {
        .init(tool: try .init(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: id,
              inputSchema: .object([.init("type", .string("object"))]), tier: tier),
              summary: { _, _ in "Base summary" }, redactArgs: redact, run: run)
    }
    private let args = NativeRPCValue.object([.init("name", .string("demo")), .init("secret", .string("s3cret"))])

    func testEffectEntersTheSameCallOnceWithOneConsentAndOneRow() async throws {
        let r = try rig(approve: true), control = r.control, args = self.args
        try await control.register([try tool("demo.remove", tier: .read) { given, context in
            let gate = control.compositionGate()
            try await gate.authorize(context, "demo.remove", given, .alter, "Remove demo", false)
            do { try await gate.authorize(context, "demo.remove", given, .alter, "Remove demo", false); XCTFail("entered twice") } catch {}
            try await gate.record(context, "demo.remove", given, .object([.init("removed", .number(1))]))
            do { try await gate.record(context, "demo.remove", given, .object([])); XCTFail("recorded twice") } catch {}
            return .init(value: .string("done"), summary: .object([.init("ignored", .bool(true))]))
        }])
        let result = await control.call(name: "demo.remove", arguments: args)
        XCTAssertTrue(result.ok); XCTAssertEqual(result.value, .string("done"))
        XCTAssertEqual(r.asked.get(), 1, "one consent question for the effect")
        let rows = await r.log.tail(10)
        XCTAssertEqual(rows.count, 1, "the effect lands in the call's one row")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["tier"], .string("alter")); XCTAssertEqual(row["baseTier"], .string("read"))
        XCTAssertEqual(row["outcome"], .string("ok")); XCTAssertEqual(row["confirmed"]["granted"], .bool(true))
        XCTAssertEqual(row["confirmed"]["by"], .string("window"))
        XCTAssertEqual(row["result"], .object([.init("removed", .number(1))]))
        XCTAssertTrue(row["detail"].string?.hasPrefix("Remove demo") == true)
    }

    func testBudgetIsTakenExactlyOnceAcrossBaseAndEffect() async throws {
        let budgets = BackendDeckCoreSecurityBudgets(changes: .init(limit: 1, windowMilliseconds: 600_000))
        let r = try rig(approve: true, budgets: budgets), control = r.control
        // Base act already spent the one change; escalating to alter must not spend another.
        try await control.register([try tool("demo.act", tier: .act) { given, context in
            _ = try await control.prepareEffect(context: context, tool: "demo.act", arguments: given, tier: .alter, sentence: "", ownerMustAnswer: false)
            return .init(value: .null)
        }, try tool("demo.read", tier: .read) { given, context in
            _ = try await control.prepareEffect(context: context, tool: "demo.read", arguments: given, tier: .act, sentence: "", ownerMustAnswer: false)
            return .init(value: .null)
        }])
        let first = await control.call(name: "demo.act", arguments: .object([]))
        XCTAssertTrue(first.ok, first.error ?? "")
        // A read call escalating to act needs the change budget the first call used.
        let second = await control.call(name: "demo.read", arguments: .object([]))
        XCTAssertFalse(second.ok); XCTAssertEqual(second.refusal, .rateLimited)
        let rows = await r.log.tail(10)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last?["tier"], .string("act")); XCTAssertEqual(rows.last?["outcome"], .string("refused"))
    }

    func testEffectBindsCallToolArgumentsAndCaller() async throws {
        let r = try rig(approve: true), control = r.control, args = self.args
        let redact: @Sendable (NativeRPCValue) throws -> NativeRPCValue = { $0.setting("secret", .string("[redacted]")) }
        try await control.register([try tool("demo.bind", tier: .read, redact: redact) { given, context in
            func refused(_ body: () async throws -> Void) async { do { try await body(); XCTFail("must not bind") } catch {} }
            await refused { _ = try await control.prepareEffect(context: context, tool: "other.tool", arguments: given, tier: .act, sentence: "", ownerMustAnswer: false) }
            await refused { _ = try await control.prepareEffect(context: context, tool: "demo.bind", arguments: given.setting("name", .string("else")), tier: .act, sentence: "", ownerMustAnswer: false) }
            await refused { _ = try await control.prepareEffect(context: context, tool: "demo.bind", arguments: given.setting("extra", .bool(true)), tier: .act, sentence: "", ownerMustAnswer: false) }
            let forged = BackendDeckCoreSecurityCallContext(native: context.native, caller: context.caller, callID: "forged-call", attended: context.attended,
                granted: context.granted, sessionLimits: context.sessionLimits, now: context.now, startedByCopilot: context.startedByCopilot, noteStarted: context.noteStarted)
            await refused { _ = try await control.prepareEffect(context: forged, tool: "demo.bind", arguments: given, tier: .act, sentence: "", ownerMustAnswer: false) }
            let impostor = BackendDeckCoreSecurityCallContext(native: context.native, caller: .init(kind: .key, tiers: [.read, .act, .alter], keyID: "k"),
                callID: context.callID, attended: context.attended, granted: context.granted, sessionLimits: context.sessionLimits, now: context.now,
                startedByCopilot: context.startedByCopilot, noteStarted: context.noteStarted)
            await refused { _ = try await control.prepareEffect(context: impostor, tool: "demo.bind", arguments: given, tier: .act, sentence: "", ownerMustAnswer: false) }
            // The redacted log form (marker in place of the secret) binds; the wire name is the same tool.
            let logged = try redact(given)
            let proof = try await control.prepareEffect(context: context, tool: "demo_bind", arguments: logged, tier: .act, sentence: "", ownerMustAnswer: false)
            XCTAssertEqual(proof.tier, .act); XCTAssertEqual(proof.arguments, logged)
            await refused { try await control.recordEffect(context: context, tool: "demo.bind", arguments: given, summary: .null) }
            try await control.recordEffect(proof: proof, context: context, tool: "demo.bind", arguments: logged, summary: .string("bound"))
            return .init(value: .null)
        }])
        let result = await control.call(name: "demo.bind", arguments: args)
        XCTAssertTrue(result.ok, result.error ?? "")
        let rows = await r.log.tail(10)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?["result"], .string("bound")); XCTAssertEqual(rows.first?["tier"], .string("act"))
        XCTAssertEqual(rows.first?["args"]["secret"], .string("[redacted]"))
        XCTAssertTrue(BackendDeckCoreSecurityControl.argumentsBound(.object([.init("audio", .string("[none]"))]), to: .object([])))
        XCTAssertFalse(BackendDeckCoreSecurityControl.argumentsBound(.object([]), to: .object([.init("a", .number(1))])))
        XCTAssertFalse(BackendDeckCoreSecurityControl.argumentsBound(.array([.number(1)]), to: .array([.number(1), .number(2)])))
    }

    func testProofExpiresWhenTheCallEnds() async throws {
        let r = try rig(approve: true), control = r.control
        let kept = BackendDeckCoreSecurityTestBox<(BackendDeckCoreSecurityEffectProof, BackendDeckCoreSecurityCallContext)?>(nil)
        try await control.register([try tool("demo.keep", tier: .read) { given, context in
            let proof = try await control.prepareEffect(context: context, tool: "demo.keep", arguments: given, tier: .read, sentence: "", ownerMustAnswer: false)
            XCTAssertFalse(proof.isExpired); kept.set((proof, context))
            return .init(value: .null)
        }])
        let result = await control.call(name: "demo.keep", arguments: .object([]))
        XCTAssertTrue(result.ok)
        let (proof, context) = try XCTUnwrap(kept.get())
        XCTAssertTrue(proof.isExpired)
        do { try await control.recordEffect(proof: proof, context: context, tool: "demo.keep", arguments: .object([]), summary: .null); XCTFail("expired proof recorded") } catch {}
        do { _ = try await control.prepareEffect(context: context, tool: "demo.keep", arguments: .object([]), tier: .act, sentence: "", ownerMustAnswer: false); XCTFail("ended call entered") }
        catch let failure as BackendSessionFailure { if case .missingCapability = failure {} else { XCTFail("\(failure)") } }
        let rows = await r.log.tail(10); XCTAssertEqual(rows.count, 1)
    }

    func testRequestCancellationDuringEffectConsentRefusesCallerGone() async throws {
        let r = try rig(approve: nil), control = r.control
        let request = BackendMCPCancellation()
        try await control.register([try tool("demo.wait", tier: .read) { given, context in
            _ = try await control.prepareEffect(context: context, tool: "demo.wait", arguments: given, tier: .alter, sentence: "Wait for me", ownerMustAnswer: false)
            XCTFail("an unanswered question cannot be approved after the caller left"); return .init(value: .null)
        }])
        let call = Task { await control.call(name: "demo.wait", arguments: .object([]), options: .init(cancellation: request)) }
        while r.asked.get() == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        request.cancel()
        let result = await call.value
        XCTAssertFalse(result.ok); XCTAssertEqual(result.refusal, .callerGone)
        let rows = await r.log.tail(10)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?["outcome"], .string("refused")); XCTAssertEqual(rows.first?["tier"], .string("alter"))
    }

    func testRefusedEffectRefusesTheRowEvenIfTheHandlerSwallowsIt() async throws {
        let r = try rig(approve: false), control = r.control
        try await control.register([try tool("demo.swallow", tier: .read) { given, context in
            do { _ = try await control.prepareEffect(context: context, tool: "demo.swallow", arguments: given, tier: .alter, sentence: "Do it", ownerMustAnswer: false) }
            catch { return .init(value: .string("pretend it worked")) }
            XCTFail("no approver must refuse"); return .init(value: .null)
        }])
        let result = await control.call(name: "demo.swallow", arguments: .object([]))
        XCTAssertFalse(result.ok); XCTAssertEqual(result.refusal, .noApprover)
        let rows = await r.log.tail(10)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?["outcome"], .string("refused"))
        XCTAssertEqual(rows.first?["confirmed"]["reason"], .string("no-approver"))
    }

    func testUnattendedAndUngrantedEffectsRefuseWithoutAsking() async throws {
        let r = try rig(approve: true), control = r.control
        try await control.register([try tool("demo.alter", tier: .read) { given, context in
            _ = try await control.prepareEffect(context: context, tool: "demo.alter", arguments: given, tier: .alter, sentence: "", ownerMustAnswer: false)
            return .init(value: .null)
        }, try tool("demo.act", tier: .read) { given, context in
            _ = try await control.prepareEffect(context: context, tool: "demo.act", arguments: given, tier: .act, sentence: "", ownerMustAnswer: false)
            return .init(value: .null)
        }])
        let routine = await control.call(name: "demo.alter", arguments: .object([]), options: .init(attended: false))
        XCTAssertEqual(routine.refusal, .unattended)
        let device = BackendDeckCoreSecurityCaller(kind: .remote, tiers: [.read], deviceID: "phone")
        let looking = await control.call(name: "demo.act", arguments: .object([]), options: .init(caller: device))
        XCTAssertEqual(looking.refusal, .notGranted)
        XCTAssertEqual(r.asked.get(), 0)
        let rows = await r.log.tail(10); XCTAssertEqual(rows.count, 2)
    }

    func testAuthenticatedExchangeRunsTheCallOnceAndCannotFabricate() async {
        let grant = BackendDeckCoreSecurityGrant(identity: "grant-1", attended: true, caller: { .local })
        let scope = BackendMCPCancellation(), runs = BackendDeckCoreSecurityTestBox<Int>(0)
        let call: @Sendable () async -> BackendDeckCoreSecurityCallResult = {
            runs.edit { $0 += 1 }
            return .init(ok: true, value: .string("real"), error: nil, refusal: nil, row: .null)
        }
        let twice = await BackendDeckCoreSecurityServer.authenticatedCall(grant: grant, scope: scope, wrapper: { seen, seenScope, operation in
            XCTAssertEqual(seen.identity, "grant-1"); XCTAssertTrue(seenScope === scope)
            await operation(); await operation()
        }, call: call)
        XCTAssertEqual(twice?.value, .string("real")); XCTAssertEqual(runs.get(), 1)
        let refused = await BackendDeckCoreSecurityServer.authenticatedCall(grant: grant, scope: scope, wrapper: { _, _, _ in
            throw NativeRPCError(code: "access-denied", message: "no grant")
        }, call: call)
        XCTAssertNil(refused); XCTAssertEqual(runs.get(), 1)
        let skipped = await BackendDeckCoreSecurityServer.authenticatedCall(grant: grant, scope: scope, wrapper: { _, _, _ in }, call: call)
        XCTAssertNil(skipped, "a wrapper that never runs the call yields no result"); XCTAssertEqual(runs.get(), 1)
        let plain = await BackendDeckCoreSecurityServer.authenticatedCall(grant: grant, scope: scope, wrapper: nil, call: call)
        XCTAssertEqual(plain?.value, .string("real")); XCTAssertEqual(runs.get(), 2)
    }

    func testServerWrapsToolsCallAndRefreshesBeforeListing() async throws {
        let r = try rig(approve: true), control = r.control
        try await control.register([try tool("demo.ping", tier: .read) { _, _ in .init(value: .object([.init("pong", .bool(true))])) }])
        let wrapped = BackendDeckCoreSecurityTestBox<[String]>([]), refreshes = BackendDeckCoreSecurityTestBox<Int>(0)
        let failing = BackendDeckCoreSecurityTestBox<Bool>(false)
        let server = BackendDeckCoreSecurityServer(control: control, ownPorts: .init(), authenticated: { grant, _, operation in
            wrapped.edit { $0.append(grant.identity) }; await operation()
        }, beforeListing: {
            refreshes.edit { $0 += 1 }
            if failing.get() { throw NativeRPCError(code: "unavailable", message: "plugin catalogue could not be refreshed") }
        })
        let grant = BackendDeckCoreSecurityGrant(identity: "session-a", attended: true, caller: { .local })
        let headers = ["content-type": "application/json", "accept": "application/json, text/event-stream"]
        func message(_ method: String, _ params: NativeRPCValue = .object([])) -> NativeRPCValue {
            .object([.init("jsonrpc", .string("2.0")), .init("id", .number(1)), .init("method", .string(method)), .init("params", params)])
        }
        let callResponse = await server.serve(parsed: message("tools/call", .object([.init("name", .string("demo_ping")), .init("arguments", .object([]))])),
            headers: headers, grant: grant, cancellation: .init())
        let called = try NativeRPCValue.parseJSON(callResponse.body)
        XCTAssertEqual(called["result"]["structuredContent"]["pong"], .bool(true)); XCTAssertEqual(wrapped.get(), ["session-a"])
        let listResponse = await server.serve(parsed: message("tools/list"), headers: headers, grant: grant, cancellation: .init())
        let listed = try NativeRPCValue.parseJSON(listResponse.body)
        XCTAssertNotNil(listed["result"]["tools"].elements); XCTAssertEqual(refreshes.get(), 1)
        failing.set(true)
        let staleResponse = await server.serve(parsed: message("tools/list"), headers: headers, grant: grant, cancellation: .init())
        let stale = try NativeRPCValue.parseJSON(staleResponse.body)
        XCTAssertEqual(stale["error"]["code"], .number(-32603), "a listing that could not be refreshed is not served")
        XCTAssertEqual(refreshes.get(), 2)
    }
}
