import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// "Switch to this Mac" (step 2), both Macs against a fake service built to the as-built contract (plan section 6):
/// ask / wait / release / take / cancel / look, `owner.self`, release only with the exact lengths held, take at once
/// when the owner is off and after 2 minutes without a sign, `move_busy` for a second asker. Nothing leaves the Mac;
/// no session, host or repository of his is touched (every port is a fake).
final class CloudSessionMoveTests: XCTestCase {
    static let ref = "0123456789abcdef0123456789abcdef"
    static let sessionId = "tab-7"
    static let conversation = "conv-1"
    static let start: Int64 = 1_794_700_000_000
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: The fake service

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64
        init(_ start: Int64) { value = start }
        var now: Int64 { lock.withLock { value } }
        func advance(_ ms: Int) { lock.withLock { value += Int64(ms) } }
    }

    actor Cloud {
        let clock: Clock
        var owner = "A"
        var pending: (id: String, to: String, at: Int64, heardAt: Int64?)?
        var last: [String: Any]?
        var on: [String: Bool] = ["A": true, "B": true, "C": true]
        /// The old Mac's history as the Cloud holds it (`heldRaw` of it).
        let raw = Data(("{\"type\":\"user\",\"sessionId\":\"conv-1\",\"cwd\":\"/Users/old/site\",\"message\":\"hello\"}\n"
                        + "{\"type\":\"assistant\",\"sessionId\":\"conv-1\",\"cwd\":\"/Users/old/site\",\"message\":\"hi\"}\n").utf8)
        var heldRaw: Int64 = 40
        var codeAt: Int64? = 1_794_699_400_000
        var actions: [(String, String)] = []
        static let names = ["A": "MacBook Air", "B": "Mac mini", "C": "iMac"]
        init(clock: Clock) { self.clock = clock }

        func setHeld(_ length: Int64) { heldRaw = length }
        func setOn(_ machine: String, _ value: Bool) { on[machine] = value }
        func asked(_ machine: String) -> [String] { actions.filter { $0.0 == machine }.map(\.1) }

        func who(_ machine: String, caller: String) -> [String: Any] { ["ref": "ref-" + machine, "name": Self.names[machine]!, "self": machine == caller] }
        func view(_ caller: String) -> [String: Any] {
            var view: [String: Any] = ["ref": CloudSessionMoveTests.ref, "sessionId": CloudSessionMoveTests.sessionId, "owner": who(owner, caller: caller),
                                       "move": NSNull(), "last": last ?? NSNull(), "codeAt": codeAt ?? NSNull()]
            if let p = pending {
                view["move"] = ["id": p.id, "to": who(p.to, caller: caller), "from": who(owner, caller: caller), "at": p.at, "heardAt": p.heardAt ?? NSNull()] as [String: Any]
            }
            return view
        }
        func held() -> [String: Any] { ["streams": ["raw": ["gen": 1, "length": heldRaw]], "chatAt": CloudSessionMoveTests.start - 60_000, "codeAt": codeAt ?? NSNull()] }
        func answer(_ status: Int, _ caller: String, code: String? = nil, extra: [String: Any] = [:]) -> (Int, Data) {
            var body = view(caller); body["ok"] = code == nil
            if let code { body["code"] = code }
            for (key, value) in extra { body[key] = value }
            return (status, try! JSONSerialization.data(withJSONObject: body))
        }

        func handle(_ caller: String, _ method: String, _ path: String, _ body: Data) -> (status: Int, data: Data) {
            if method == "POST", path == "/sessions/move" { return move(caller, body) }
            if method == "GET", path.hasPrefix("/sessions?") { return (200, sessions(caller)) }
            if method == "GET", path.hasPrefix("/chats/raw?") { return rawUnit(path) }
            return (404, Data(#"{"error":{"code":"not_found"}}"#.utf8))
        }

        func move(_ me: String, _ body: Data) -> (status: Int, data: Data) {
            let b = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            let action = b["action"] as! String, id = b["id"] as? String
            actions.append((me, action))
            let now = clock.now
            if action == "ask" || action == "look" { precondition(b.keys.sorted() == ["action", "ref"], "ask/look carry only the ref") }
            switch action {
            case "ask":
                if owner == me || pending?.to == me { return answer(200, me) }
                if let p = pending, now - p.at < 15 * 60_000 { _ = p; return answer(409, me, code: "move_busy") }
                pending = (UUID().uuidString.lowercased(), me, now, nil)
                return answer(200, me)
            case "wait":
                guard let p = pending, p.id == id, owner == me else { return answer(409, me, code: "move_changed") }
                pending?.heardAt = now
                return answer(200, me)
            case "release":
                if let last, last["id"] as? String == id, last["why"] as? String == "released", owner != me { return answer(200, me) }
                guard let p = pending, p.id == id, owner == me else { return answer(409, me, code: "move_changed") }
                let lengths = b["lengths"] as? [String: Int] ?? [:]
                if lengths.contains(where: { $0.key == "raw" && Int64($0.value) != heldRaw }) { return answer(409, me, code: "release_lengths", extra: ["held": held()]) }
                var release: [String: Any] = ["lengths": lengths]
                for key in ["codeAt", "branch", "headSha", "workSha"] { release[key] = b[key] ?? NSNull() }
                last = ["id": p.id, "from": who(me, caller: me), "to": who(p.to, caller: me), "at": p.at, "doneAt": now, "forced": false,
                        "why": "released", "release": release, "held": held()]
                codeAt = (b["codeAt"] as? NSNumber)?.int64Value ?? codeAt
                owner = p.to; pending = nil
                return answer(200, me)
            case "take":
                if let last, last["id"] as? String == id, owner == me { return answer(200, me) }
                guard let p = pending, p.id == id, p.to == me else { return answer(409, me, code: "move_changed") }
                let since = max(p.at, p.heardAt ?? 0)
                let why: String? = on[owner] == false ? "off" : now - since >= 120_000 ? "no_answer" : nil
                guard let why else { return answer(409, me, code: "move_wait", extra: ["retryAfterMs": since + 120_000 - now]) }
                last = ["id": p.id, "from": who(owner, caller: me), "to": who(me, caller: me), "at": p.at, "doneAt": now, "forced": true,
                        "why": why, "release": NSNull(), "held": held()]
                owner = me; pending = nil
                return answer(200, me)
            case "cancel":
                if let p = pending, p.id == id {
                    guard p.to == me || owner == me else { return answer(409, me, code: "move_changed") }
                    pending = nil
                } else if last?["id"] as? String == id { return answer(409, me, code: "move_done") }
                return answer(200, me)
            default:
                return answer(200, me)
            }
        }

        func sessions(_ caller: String) -> Data {
            var row: [String: Any] = ["ref": CloudSessionMoveTests.ref, "sessionId": CloudSessionMoveTests.sessionId, "name": "Site redesign",
                                      "lastUsedAt": CloudSessionMoveTests.start - 60_000, "ai": "claude", "kind": "chat", "status": "idle",
                                      "cwd": "/Users/old/site", "login": "Work", "conversationId": CloudSessionMoveTests.conversation,
                                      "startedAt": CloudSessionMoveTests.start - 3_600_000, "project": ["cloudRef": "p1", "name": "Site"],
                                      "machine": "ref-" + owner, "machineName": Self.names[owner]!, "machineOn": on[owner] ?? false,
                                      "self": owner == caller, "readable": true]
            if let p = pending { row["move"] = ["id": p.id, "to": "ref-" + p.to, "toName": Self.names[p.to]!, "from": "ref-" + owner, "fromName": Self.names[owner]!, "at": p.at] }
            return try! JSONSerialization.data(withJSONObject: ["machines": [], "sessions": [row]])
        }

        func rawUnit(_ path: String) -> (status: Int, data: Data) {
            let from = Int64(path.components(separatedBy: "from=").last!.components(separatedBy: "&").first!)!
            if from >= heldRaw { return (200, try! JSONSerialization.data(withJSONObject: ["gen": 1, "length": heldRaw, "done": true])) }
            let bytes = raw.prefix(Int(heldRaw))
            let body: [String: Any] = ["gen": 1, "length": heldRaw, "done": false, "kind": "piece", "from": 0, "rawLen": bytes.count,
                                       "sha256": BackendCloudChats.hex(Data(bytes)), "next": heldRaw,
                                       "gz": BackendCloudChats.gzip(Data(bytes))!.base64EncodedString()]
            return (200, try! JSONSerialization.data(withJSONObject: body))
        }
    }

    // MARK: One Mac (every port a fake that records what it was asked)

    actor Mac {
        var alive = true
        var statuses: [String] = []
        var closed = 0, left = 0, backups = 0, launched: [BackendCloudSessionMove.LaunchRequest] = []
        var placed: [(BackendCloudSessionMove.PlaceRequest, Data)] = []
        var took: [BackendCodeBackupTakeCode.Named] = []
        var account: BackendCloudSessionMove.Account = .same(profileID: "work", home: "/tmp/claude-home")
        func setAccount(_ value: BackendCloudSessionMove.Account) { account = value }
        func setStatuses(_ value: [String]) { statuses = value }
        func setAlive(_ value: Bool) { alive = value }
        func local() -> BackendCloudSessionMove.Local? {
            guard alive else { return nil }
            let status = statuses.isEmpty ? "idle" : statuses.removeFirst()
            return .init(id: "local-old", sessionId: CloudSessionMoveTests.sessionId, status: status, kind: "chat", cwd: "/Users/old/site",
                         provider: "claude", conversationId: CloudSessionMoveTests.conversation, projectID: "p1", name: "Site redesign")
        }
        func close() { closed += 1; alive = false }
        func keepLeft() { left += 1 }
        func backup() { backups += 1 }
        func take(_ named: BackendCodeBackupTakeCode.Named) { took.append(named) }
        func place(_ request: BackendCloudSessionMove.PlaceRequest) { placed.append((request, (try? Data(contentsOf: request.downloaded)) ?? Data())) }
        func launch(_ request: BackendCloudSessionMove.LaunchRequest) -> String { launched.append(request); return "local-new" }
    }

    func mover(_ name: String, _ cloud: Cloud, _ mac: Mac, _ clock: Clock,
               attemptSeconds: Double = 960, modify: (inout BackendCloudSessionMove.Ports) -> Void = { _ in }) -> BackendCloudSessionMove {
        let send: BackendCloudChatsUploader.Send = { method, path, body in await cloud.handle(name, method, path, body) }
        var ports = BackendCloudSessionMove.Ports(
            send: send,
            row: { ref in await BackendCloudSessionsRead.list(send, earlier: false)?.rows.first { $0.ref == ref } },
            local: { _ in await mac.local() },
            close: { _ in await mac.close() },
            flush: { _ in ["raw": await cloud.heldRaw] },
            keepLeft: { _ in await mac.keepLeft() },
            handOver: { _, _ in .init(ok: true, codeAt: CloudSessionMoveTests.start - 30_000, branch: "main",
                                      headSha: String(repeating: "a", count: 40), workSha: String(repeating: "b", count: 40)) },
            ownBackup: { _, _ in await mac.backup(); return true },
            folder: { _ in .init(path: "/Users/new/site", projectID: "p1", made: false) },
            takeCode: { request, _ in await mac.take(request.named); return .init(kind: .fastForward, branch: "main", codeAt: request.named.codeAt) },
            account: { _, _ in await mac.account },
            place: { request in await mac.place(request) },
            launch: { request in await mac.launch(request) },
            sleep: { ms in clock.advance(ms); await Task.yield() },
            now: { clock.now })
        modify(&ports)
        return BackendCloudSessionMove(ports: ports, file: root.appendingPathComponent(name).appendingPathComponent("cloud-moves.json"), autoStart: false, attemptSeconds: attemptSeconds)
    }

    struct World {
        let clock: Clock, cloud: Cloud, air: Mac, mini: Mac, airMove: BackendCloudSessionMove, miniMove: BackendCloudSessionMove
    }
    func world() -> World {
        let clock = Clock(Self.start), cloud = Cloud(clock: clock), air = Mac(), mini = Mac()
        return World(clock: clock, cloud: cloud, air: air, mini: mini, airMove: mover("A", cloud, air, clock), miniMove: mover("B", cloud, mini, clock))
    }

    func testLostLookAnswersFinishAsFailureInsteadOfBypassingTheDeadline() async throws {
        let clock = Clock(Self.start), cloud = Cloud(clock: clock), mac = Mac()
        await mac.setAlive(false)
        let engine = mover("B", cloud, mac, clock) { ports in
            let original = ports.send
            ports.send = { method, path, body in
                let action = (try? JSONSerialization.jsonObject(with: body) as? [String: String])?["action"]
                if action == "look" { throw NativeRPCError(code: "offline", message: "fixture offline") }
                return try await original(method, path, body)
            }
        }
        _ = await engine.switchHere(ref: Self.ref)
        await engine.driveForTesting(Self.ref)
        let entry = await engine.entry(ref: Self.ref)
        XCTAssertEqual(entry?.step, .failed)
        XCTAssertEqual(entry?.resumeStep, .asked)
        XCTAssertEqual(entry?.source?.name, "Site redesign")
        XCTAssertEqual(entry?.line, BackendCloudSessionMoveWords.unconfirmed)
        XCTAssertGreaterThanOrEqual(clock.now - Self.start, BackendCloudSessionMove.noAnswerMs)
        XCTAssertLessThan(clock.now - Self.start, BackendCloudSessionMove.noAnswerMs + 6_000)
        let launches = await mac.launched
        XCTAssertTrue(launches.isEmpty)
    }

    func testAnUnresponsiveStageFailsWithinItsBoundAndALateAnswerCannotLaunch() async throws {
        let clock = Clock(Self.start), cloud = Cloud(clock: clock), mac = Mac()
        let gate = BackendRemoteServeMachinesTestsGate()
        await mac.setAlive(false); await cloud.setOn("A", false)
        let engine = mover("B", cloud, mac, clock, attemptSeconds: 0.5) { ports in
            ports.folder = { _ in await gate.suspend(); return nil }
        }
        _ = await engine.switchHere(ref: Self.ref)
        await engine.driveForTesting(Self.ref)
        let failed = await engine.entry(ref: Self.ref)
        XCTAssertEqual(failed?.step, .failed)
        XCTAssertEqual(failed?.resumeStep, .code)
        XCTAssertTrue(failed?.line?.contains("timed out") == true)
        await gate.release()
        try await Task.sleep(for: .milliseconds(20))
        let launches = await mac.launched
        XCTAssertTrue(launches.isEmpty)
        // Retry is explicit and uses the journal's stage. It neither asks again nor creates two local sessions.
        let retry = mover("B", cloud, mac, clock)
        _ = await retry.switchHere(ref: Self.ref)
        await retry.driveForTesting(Self.ref)
        let done = await retry.entry(ref: Self.ref), started = await mac.launched, actions = await cloud.asked("B")
        XCTAssertEqual(done?.step, .done)
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started.first?.name, "Site redesign")
        XCTAssertEqual(actions.filter { $0 == "ask" }.count, 1)
    }

    func testRetryDuringLateLaunchJoinsTheSameCreation() async throws {
        let clock = Clock(Self.start), cloud = Cloud(clock: clock), mac = Mac(), gate = BackendRemoteServeMachinesTestsGate()
        await mac.setAlive(false); await cloud.setOn("A", false)
        let engine = mover("B", cloud, mac, clock, attemptSeconds: 0.5) { ports in
            ports.launch = { request in await gate.suspend(); return await mac.launch(request) }
        }
        _ = await engine.switchHere(ref: Self.ref)
        await engine.driveForTesting(Self.ref)
        let failed = await engine.entry(ref: Self.ref)
        XCTAssertEqual(failed?.step, .failed); XCTAssertEqual(failed?.resumeStep, .launching)
        _ = await engine.switchHere(ref: Self.ref)
        let retry = Task { await engine.driveForTesting(Self.ref) }
        try await Task.sleep(for: .milliseconds(10)); await gate.release(); await retry.value
        let done = await engine.entry(ref: Self.ref), launches = await mac.launched
        XCTAssertEqual(done?.step, .done)
        XCTAssertEqual(launches.count, 1)
    }

    func testFailedStopDoesNotHandOverOwnership() async throws {
        let clock = Clock(Self.start), cloud = Cloud(clock: clock), air = Mac(), mini = Mac()
        let taker = mover("B", cloud, mini, clock)
        _ = await taker.switchHere(ref: Self.ref)
        let giver = mover("A", cloud, air, clock) { ports in
            ports.close = { _ in throw NativeRPCError(code: "failed", message: "fixture close failed") }
        }
        await giver.hint(ref: Self.ref); await giver.driveForTesting(Self.ref)
        let failure = await giver.entry(ref: Self.ref), owner = await cloud.owner, actions = await cloud.asked("A")
        XCTAssertEqual(failure?.step, .failed)
        XCTAssertEqual(failure?.resumeStep, .releasing)
        XCTAssertEqual(failure?.line, BackendCloudSessionMoveWords.couldNotStop)
        XCTAssertEqual(owner, "A")
        XCTAssertFalse(actions.contains("release"))
    }

    func testCancelThatLosesToHandoverContinuesToLaunchInsteadOfStrandingOwner() async throws {
        let clock = Clock(Self.start), cloud = Cloud(clock: clock), mac = Mac(), gate = BackendRemoteServeMachinesTestsGate()
        await mac.setAlive(false)
        let engine = mover("B", cloud, mac, clock) { ports in
            ports.sleep = { ms in clock.advance(ms); await gate.suspend() }
        }
        _ = await engine.switchHere(ref: Self.ref)
        let driving = Task { await engine.driveForTesting(Self.ref) }
        try await BackendAppDeviceDeadline.run(within: 2, "Waiting for the fixture move") { await gate.waitUntilEntered() }
        _ = await engine.cancel(ref: Self.ref)
        await cloud.setOn("A", false)
        let current = await engine.entry(ref: Self.ref)
        let move = try XCTUnwrap(current)
        let body = try JSONSerialization.data(withJSONObject: ["action": "take", "ref": Self.ref, "id": move.moveId])
        _ = await cloud.handle("B", "POST", "/sessions/move", body)
        await gate.release(); await driving.value
        let done = await engine.entry(ref: Self.ref), launches = await mac.launched
        XCTAssertEqual(done?.step, .done)
        XCTAssertEqual(launches.count, 1)
    }

    // MARK: The cases

    /// Old Mac on, a reply still being written: it says `wait`, then stops the session the app's way, hands over the
    /// exact lengths with its code backup; only then does this Mac read the chat, lay the code in and start it ONCE.
    func testHappyPathOldMacOnWaitsForTheReplyThenHandsOver() async throws {
        let w = world()
        await w.air.setStatuses(["running", "running", "idle"])
        let first = await w.miniMove.switchHere(ref: Self.ref)
        XCTAssertEqual(first, "Moving from MacBook Air…")
        await w.mini.setAlive(false)   // the session is not on this Mac
        await w.airMove.hint(ref: Self.ref)
        await w.airMove.driveForTesting(Self.ref)
        let airActions = await w.cloud.asked("A")
        XCTAssertTrue(airActions.contains("wait"), "the old Mac tells the service it is busy while the reply is written")
        XCTAssertEqual(airActions.last, "release")
        let closedOnAir = await w.air.closed
        XCTAssertEqual(closedOnAir, 1)
        let owner = await w.cloud.owner
        XCTAssertEqual(owner, "B")

        await w.miniMove.driveForTesting(Self.ref)
        let entry = await w.miniMove.entry(ref: Self.ref)
        XCTAssertEqual(entry?.step, .done)
        XCTAssertEqual(entry?.line, "Moved from MacBook Air. Its code was backed up first.")
        let launched = await w.mini.launched
        XCTAssertEqual(launched.count, 1)
        XCTAssertEqual(launched.first?.sessionId, Self.sessionId, "the Cloud id stays the same")
        XCTAssertEqual(launched.first?.conversationId, Self.conversation)
        XCTAssertEqual(launched.first?.profileID, "work")
        let placed = await w.mini.placed
        let held = await w.cloud.heldRaw
        XCTAssertEqual(placed.first?.1.count, Int(held), "the chat came down to exactly what the hand-over named")
        XCTAssertEqual(placed.first?.0.oldCwd, "/Users/old/site")
        XCTAssertEqual(placed.first?.0.newCwd, "/Users/new/site")
        let took = await w.mini.took
        XCTAssertEqual(took.first?.headSha, String(repeating: "a", count: 40))
        XCTAssertEqual(took.first?.workSha, String(repeating: "b", count: 40))
        let backups = await w.mini.backups
        XCTAssertEqual(backups, 1, "this Mac's own folder is backed up before anything is laid in")

        // Run again (a crash after the launch): never a second start.
        await w.miniMove.driveForTesting(Self.ref)
        let again = await w.mini.launched
        XCTAssertEqual(again.count, 1)
    }

    /// Old Mac off: taken at once, the old Mac is never asked to do anything, and the line names the chat's and the
    /// code's times.
    func testOldMacOffTakesTheCloudCopyAndSaysHowOld() async throws {
        let w = world()
        await w.cloud.setOn("A", false)
        await w.mini.setAlive(false)
        _ = await w.miniMove.switchHere(ref: Self.ref)
        await w.miniMove.driveForTesting(Self.ref)
        let entry = await w.miniMove.entry(ref: Self.ref)
        XCTAssertEqual(entry?.step, .done)
        XCTAssertEqual(entry?.last?.why, "off")
        let line = try XCTUnwrap(entry?.line)
        XCTAssertTrue(line.hasPrefix("MacBook Air is off. The chat is from "), line)
        XCTAssertTrue(line.contains("and the code here is from "), line)
        XCTAssertTrue(line.hasSuffix("(its last backup)."), line)
        let closed = await w.air.closed
        XCTAssertEqual(closed, 0)
        let took = await w.mini.took
        XCTAssertNil(took.first?.headSha, "taken without a hand-over: the old Mac's newest backup, not a named one")
        let launched = await w.mini.launched
        XCTAssertEqual(launched.count, 1)
    }

    /// Old Mac silent: after 2 minutes this Mac takes it. The old Mac comes back with the session still running: its
    /// upload is refused `not_yours`; its copy stops by itself and what it did is kept (`~left` chat + own backup).
    func testOldMacSilentThenBackStopsItsCopyAndKeepsItsWork() async throws {
        let w = world()
        await w.mini.setAlive(false)
        _ = await w.miniMove.switchHere(ref: Self.ref)
        await w.miniMove.driveForTesting(Self.ref)
        let entry = await w.miniMove.entry(ref: Self.ref)
        XCTAssertEqual(entry?.step, .done)
        XCTAssertEqual(entry?.last?.why, "no_answer")
        XCTAssertGreaterThanOrEqual(w.clock.now - Self.start, 120_000, "not taken before the 2 minutes")

        await w.airMove.movedAway(sessionId: Self.sessionId, to: "Mac mini")
        await w.airMove.driveForTesting("stopped:" + Self.sessionId)
        let closed = await w.air.closed, left = await w.air.left, backups = await w.air.backups
        XCTAssertEqual(closed, 1); XCTAssertEqual(left, 1); XCTAssertEqual(backups, 1)
        let stopped = await w.airMove.entry(ref: "stopped:" + Self.sessionId)
        XCTAssertTrue(stopped?.line?.hasPrefix("This session moved to Mac mini at ") == true)
        XCTAssertTrue(stopped?.line?.hasSuffix("the code in Code backup, the chat in Earlier chats.") == true)
    }

    /// Two Macs ask at once: the second is told and nothing starts there.
    func testTwoTakersTheSecondIsRefused() async throws {
        let w = world()
        let imac = Mac()
        let imacMove = mover("C", w.cloud, imac, w.clock)
        _ = await w.miniMove.switchHere(ref: Self.ref)
        let line = await imacMove.switchHere(ref: Self.ref)
        XCTAssertEqual(line, "This session is already moving to Mac mini.")
        let entry = await imacMove.entry(ref: Self.ref)
        XCTAssertNil(entry)
        let launched = await imac.launched
        XCTAssertTrue(launched.isEmpty)
    }

    /// No sign-in for that AI here: nothing is asked of the service, nothing stops on the old Mac.
    func testNoAccountHereNothingStops() async throws {
        let w = world()
        await w.mini.setAccount(.none)
        let line = await w.miniMove.switchHere(ref: Self.ref)
        XCTAssertEqual(line, "Sign in to Claude on this Mac to move this chat.")
        let asked = await w.cloud.asked("B")
        XCTAssertFalse(asked.contains("ask"))
        let owner = await w.cloud.owner
        XCTAssertEqual(owner, "A")
        let closed = await w.air.closed
        XCTAssertEqual(closed, 0)
    }

    /// Cancel before the hand-over: called off on the service; the old Mac finds no ask and keeps running it.
    func testCancelLeavesEverythingAsItWas() async throws {
        let w = world()
        _ = await w.miniMove.switchHere(ref: Self.ref)
        let line = await w.miniMove.cancel(ref: Self.ref)
        XCTAssertEqual(line, "Not moved. It runs where it was.")
        let entry = await w.miniMove.entry(ref: Self.ref)
        XCTAssertEqual(entry?.step, .cancelled)
        await w.airMove.hint(ref: Self.ref)
        let giver = await w.airMove.entry(ref: Self.ref)
        XCTAssertNil(giver, "no ask is open: the old Mac does nothing")
        let closed = await w.air.closed
        XCTAssertEqual(closed, 0)
        let owner = await w.cloud.owner
        XCTAssertEqual(owner, "A")
    }

    /// The chat is laid where Claude resumes it, with only the folder changed; a file already there is kept beside it.
    func testPlacingTheChatRewritesTheFolderAndKeepsWhatWasThere() throws {
        let source = root.appendingPathComponent("raw")
        try Data(("{\"type\":\"user\",\"sessionId\":\"conv-1\",\"cwd\":\"/Users/old/site\",\"message\":\"cwd /Users/old/site stays in text\"}\n").utf8).write(to: source)
        let home = root.appendingPathComponent("claude-home").path
        let request = BackendCloudSessionMove.PlaceRequest(downloaded: source, tools: [:], provider: "claude", conversationId: "conv-1",
                                                           oldCwd: "/Users/old/site", newCwd: "/Users/new/site", home: home, startedAt: Self.start)
        let target = try XCTUnwrap(BackendCloudSessionMovePlace.target(request))
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("earlier copy\n".utf8).write(to: target)
        let placed = try BackendCloudSessionMovePlace.place(request, now: 42)
        let line = try XCTUnwrap(try Data(contentsOf: placed).split(separator: 10).first)
        let record = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        XCTAssertEqual(record["cwd"] as? String, "/Users/new/site")
        XCTAssertEqual(record["message"] as? String, "cwd /Users/old/site stays in text", "message text is never changed")
        let kept = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".before-move-42")
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), "earlier copy\n")
    }
}
