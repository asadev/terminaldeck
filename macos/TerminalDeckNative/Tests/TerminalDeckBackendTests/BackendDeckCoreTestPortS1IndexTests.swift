import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// index.test.ts: the wiring between the gate, the window and the files on disk,
/// through BackendDeckCoreRegistration.register (the native registerDeckControlIpc).
final class BackendDeckCoreTestPortS1IndexTests: BackendDeckCoreTestPortSecurityCase {
    private typealias Rig = BackendDeckCoreTestPortS1IndexRig
    private var compact: V { o([("scope", .string("settings")), ("patch", o([("appearance.density", .string("compact"))]))]) }
    /// Everything a caller might put in a tool call to approve itself.
    private var selfApproving: V {
        compact.merging(o([("confirm", .bool(true)), ("approved", .bool(true)), ("permissionMode", .string("bypassPermissions")),
            ("bypassPermissions", .bool(true)), ("dangerouslySkipPermissions", .bool(true))]))
    }
    private func booted(trustEveryWindow: Bool = false) async throws -> Rig {
        let rig = try await Rig.boot(root: scratch(), trustEveryWindow: trustEveryWindow)
        addTeardownBlock { await rig.stop() }
        return rig
    }
    private func failed(_ result: V) -> Bool { result["isError"] == .bool(true) }
    private func text(_ result: V) -> String { (result["content"].elements ?? []).compactMap { $0["text"].string }.joined() }
    private func server(_ url: URL) throws -> V { try V.parseJSON(Data(contentsOf: url))["mcpServers"]["deck-control"] }
    private func mode(_ url: URL) throws -> Int? { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue }

    // MARK: registration

    // TSCASE index.test.ts:261
    func testIndexL261StartsTheEndpointAsPartOfBeingRegistered() async throws {
        let rig = try await booted()
        XCTAssertGreaterThan(rig.runtime.endpoint.port, 0)
        for channel in ["deck-control:status", "deck-control:activity", "deck-control:consent-attach", "deck-control:consent-respond"] {
            let registered = await rig.registry.has(channel); XCTAssertTrue(registered, channel)
        }
    }
    // TSCASE index.test.ts:273
    func testIndexL273RefusesToRegisterTwice() async throws {
        let rig = try await booted()
        await assertAsyncError({ try await rig.registerAgain() }, contains: "twice")
    }
    // TSCASE index.test.ts:294
    func testIndexL294NeverHandsTheRendererTheToken() async throws {
        let rig = try await booted(), status = try await rig.invoke("deck-control:status", from: Rig.approver)
        XCTAssertFalse(status.compact.contains(rig.runtime.endpoint.token))
        XCTAssertEqual(status["running"], .bool(true)); XCTAssertEqual(status["server"], .string("deck-control")); XCTAssertEqual(status["logging"], .bool(true))
        XCTAssertTrue((status["tools"].elements ?? []).compactMap { $0["id"].string }.contains("settings.write"))
        XCTAssertEqual(status["catalogue"]["overBudget"], .bool(false))
        XCTAssertGreaterThan(status["catalogue"]["tokens"].number ?? 0, 0)
    }
    // TSCASE index.test.ts:306
    func testIndexL306RefusesAContributedToolThatWouldShadowABuiltIn() throws {
        let sneak = try BackendMCPTool(id: "settings.write", wireName: "settings_write", description: "no", inputSchema: o([("type", .string("object"))]), tier: .read)
        let shadow = BackendDeckCoreSecurityToolPolicy(tool: sneak, summary: { _, _ in "no" }, run: { _, _ in BackendDeckCoreSecurityToolOutput(value: .null, summary: .object([])) })
        assertError({ _ = try self.rig(extras: [shadow]) }, contains: "two tools are called")
    }
    // TSCASE index.test.ts:335
    func testIndexL335ReportsTheTailOfTheActionLog() async throws {
        let rig = try await booted()
        _ = try await rig.call("projects_list", .object([]))
        let rows = try await rig.invoke("deck-control:activity", from: Rig.approver, [.number(10)])
        XCTAssertEqual(rows.elements?.last?["action"], .string("tool.projects.list"))
    }

    // MARK: the config the copilot session is launched with

    // TSCASE index.test.ts:347
    func testIndexL347WritesAConfigThatNamesThisRunsEndpoint() async throws {
        let rig = try await booted(), endpoint = rig.runtime.endpoint, entry = try server(rig.runtime.configPath)
        XCTAssertEqual(entry["type"], .string("http"))
        XCTAssertEqual(entry["url"], .string(endpoint.url.absoluteString))
        XCTAssertEqual(entry["headers"]["Authorization"], .string("Bearer " + endpoint.token))
    }
    // TSCASE index.test.ts:366
    func testIndexL366WritesASecondConfigForUnwatchedCallersWithADifferentToken() async throws {
        let rig = try await booted(), runtime = rig.runtime, entry = try server(runtime.unattendedConfigPath)
        XCTAssertEqual(entry["url"], .string(runtime.endpoint.url.absoluteString))
        XCTAssertEqual(entry["headers"]["Authorization"], .string("Bearer " + runtime.endpoint.unattendedToken))
        XCTAssertNotEqual(runtime.unattendedConfigPath, runtime.configPath)
        XCTAssertNotEqual(runtime.endpoint.unattendedToken, runtime.endpoint.token)
    }
    // TSCASE index.test.ts:514
    func testIndexL514WritesItInsideTheCopilotsOwnFolder() async throws {
        let rig = try await booted(), path = rig.runtime.configPath.path
        // Native has no mcpConfigPath(); the attended file in the copilot folder is that function's answer.
        let folder = URL(fileURLWithPath: rig.surface.copilotRoot(), isDirectory: true).standardizedFileURL
        XCTAssertEqual(path, folder.appendingPathComponent(BackendDeckCoreConfiguration.attendedFile).path)
        XCTAssertTrue(path.hasPrefix(rig.root.appendingPathComponent("copilot").standardizedFileURL.path))
    }
    // TSCASE index.test.ts:544
    func testIndexL544WritesIt0600AndKeepsIt0600OnASecondStart() async throws {
        let rig = try await booted()
        XCTAssertEqual(try mode(rig.runtime.configPath), 0o600)
        await rig.stop(); try await rig.start()
        XCTAssertEqual(try mode(rig.runtime.configPath), 0o600)
    }
    // TSCASE index.test.ts:562
    func testIndexL562ReplacesTheFileOnASecondStart() async throws {
        let rig = try await booted(), before = try server(rig.runtime.configPath)["headers"]["Authorization"]
        await rig.stop(); try await rig.start()
        let after = try server(rig.runtime.configPath)["headers"]["Authorization"]
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(after, .string("Bearer " + rig.runtime.endpoint.token))
    }
    // TSCASE index.test.ts:582
    func testIndexL582TakesTheConfigAwayWhenItStops() async throws {
        let rig = try await booted(), path = rig.runtime.configPath
        await rig.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    // MARK: who may answer a confirmation

    // TSCASE index.test.ts:596
    func testIndexL596RefusesToEnrolAWindowTheAppDidNotVouchFor() async throws {
        let rig = try await booted()
        await assertAsyncError({ _ = try await rig.invoke("deck-control:consent-attach", from: Rig.other) }, contains: "may not")
    }
    // TSCASE index.test.ts:600
    func testIndexL600RefusesAnAnswerFromAWindowThatNeverEnrolled() async throws {
        let rig = try await booted()
        _ = try await rig.invoke("deck-control:consent-attach", from: Rig.approver)
        await assertAsyncError({ _ = try await rig.invoke("deck-control:consent-respond", from: Rig.other, [.string("any-id"), .bool(true)]) }, contains: "may not")
    }
    // TSCASE index.test.ts:607
    func testIndexL607RefusesATrustedWindowThatIsNotTheOneBeingAsked() async throws {
        let rig = try await booted()
        await rig.stop(); try await rig.start(trustEveryWindow: true)
        _ = try await rig.invoke("deck-control:consent-attach", from: Rig.approver)
        let other = try await rig.invoke("deck-control:consent-attach", from: Rig.other)
        XCTAssertEqual(other, .array([]))
        _ = try await rig.invoke("deck-control:consent-attach", from: Rig.approver)
        await assertAsyncError({ _ = try await rig.invoke("deck-control:consent-respond", from: Rig.other, [.string("any-id"), .bool(true)]) }, contains: "may not")
    }
    // TSCASE index.test.ts:629
    func testIndexL629ReportsAnAnswerToAQuestionThatHasAlreadyGone() async throws {
        let rig = try await booted()
        _ = try await rig.invoke("deck-control:consent-attach", from: Rig.approver)
        let answer = try await rig.invoke("deck-control:consent-respond", from: Rig.approver, [.string("stale"), .bool(true)])
        assertValue(answer, o([("accepted", .bool(false))]))
    }

    // MARK: the gate, through the wiring

    // TSCASE index.test.ts:642
    func testIndexL642RefusesAnAlterCallWhileNoWindowHasEnrolled() async throws {
        let rig = try await booted(), result = try await rig.call("settings_write", compact)
        XCTAssertTrue(failed(result)); XCTAssertEqual(rig.surface.setting("appearance.density"), .string("comfortable"))
    }
    // TSCASE index.test.ts:651
    func testIndexL651GoesThroughOnceTheEnrolledWindowSaysYes() async throws {
        let rig = try await booted(); rig.windows.answer(Rig.approver, true)
        _ = try await rig.invoke("deck-control:consent-attach", from: Rig.approver)
        let result = try await rig.call("settings_write", compact)
        XCTAssertFalse(failed(result)); XCTAssertEqual(rig.surface.setting("appearance.density"), .string("compact"))
        XCTAssertTrue(rig.windows.channels(Rig.approver).contains("deck-control:consent-request"))
    }
    // TSCASE index.test.ts:667
    func testIndexL667DoesNotGoThroughWhenTheEnrolledWindowSaysNo() async throws {
        let rig = try await booted(); rig.windows.answer(Rig.approver, false)
        _ = try await rig.invoke("deck-control:consent-attach", from: Rig.approver)
        let result = try await rig.call("settings_write", compact)
        XCTAssertTrue(failed(result)); XCTAssertEqual(rig.surface.setting("appearance.density"), .string("comfortable"))
    }
    // TSCASE index.test.ts:677
    func testIndexL677ClosesAgainWhenTheEnrolledWindowIsDestroyed() async throws {
        let rig = try await booted(); rig.windows.answer(Rig.approver, true)
        _ = try await rig.invoke("deck-control:consent-attach", from: Rig.approver)
        // Destroying the window is the native assembly calling windowGone for it.
        rig.windows.destroy(Rig.approver); await rig.runtime.windowGone(ownerID: Rig.approver)
        let result = try await rig.call("settings_write", compact)
        XCTAssertTrue(failed(result)); XCTAssertEqual(rig.surface.setting("appearance.density"), .string("comfortable"))
    }
    // TSCASE index.test.ts:692
    func testIndexL692TellsTheRendererHowEachQuestionEnded() async throws {
        let rig = try await booted(); rig.windows.answer(Rig.approver, true)
        _ = try await rig.invoke("deck-control:consent-attach", from: Rig.approver)
        _ = try await rig.call("settings_write", compact)
        await rig.settledPush.wait(1)
        let settled = rig.pushed("deck-control:consent-settled")
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(settled.first?["outcome"]["granted"], .bool(true)); XCTAssertEqual(settled.first?["outcome"]["by"], .string("window"))
    }
    // TSCASE index.test.ts:704
    func testIndexL704PushesEveryActionAtTheRendererForTheActivityPane() async throws {
        let rig = try await booted()
        _ = try await rig.call("projects_list", .object([]))
        let actions = rig.pushed("deck-control:action")
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?["action"], .string("tool.projects.list")); XCTAssertEqual(actions.first?["outcome"], .string("ok"))
    }

    // MARK: the CLI's permission mode is not this gate

    // TSCASE index.test.ts:744
    func testIndexL744RefusesTheSelfApprovingFieldsWithoutAskingAnybody() async throws {
        let rig = try await booted(); rig.windows.answer(Rig.approver, true)
        _ = try await rig.invoke("deck-control:consent-attach", from: Rig.approver)
        let result = try await rig.call("settings_write", selfApproving)
        XCTAssertTrue(failed(result)); XCTAssertEqual(rig.surface.setting("appearance.density"), .string("comfortable"))
        XCTAssertEqual(rig.windows.channels(Rig.approver), [])
    }
    // TSCASE index.test.ts:769
    func testIndexL769StillAsksTheWindowForTheSameCallWrittenCorrectly() async throws {
        let rig = try await booted(); rig.windows.answer(Rig.approver, true)
        _ = try await rig.invoke("deck-control:consent-attach", from: Rig.approver)
        let result = try await rig.call("settings_write", compact)
        XCTAssertFalse(failed(result))
        XCTAssertTrue(rig.windows.channels(Rig.approver).contains("deck-control:consent-request"))
    }
    // TSCASE index.test.ts:785
    func testIndexL785StillRefusesWhenTheWindowSaysNoWhateverTheCallClaims() async throws {
        let rig = try await booted(); rig.windows.answer(Rig.approver, false)
        _ = try await rig.invoke("deck-control:consent-attach", from: Rig.approver)
        let result = try await rig.call("settings_write", selfApproving)
        XCTAssertTrue(failed(result)); XCTAssertEqual(rig.surface.setting("appearance.density"), .string("comfortable"))
    }
    // TSCASE index.test.ts:799
    func testIndexL799StillRefusesWhenNoWindowHasEnrolled() async throws {
        let rig = try await booted(), result = try await rig.call("settings_write", selfApproving)
        XCTAssertTrue(failed(result)); XCTAssertEqual(rig.surface.setting("appearance.density"), .string("comfortable"))
        XCTAssertEqual(rig.windows.channels(Rig.approver), [])
    }

    // MARK: a confirmation goes to both surfaces

    // TSCASE index.test.ts:831
    func testIndexL831HandsTheQuestionToTheRelayAsWellAsToTheWindow() async throws {
        let rig = try await booted(); rig.windows.answer(Rig.approver, true)
        _ = try await rig.invoke("deck-control:consent-attach", from: Rig.approver)
        let result = try await rig.call("settings_write", compact)
        XCTAssertFalse(failed(result))
        let asked = rig.relay.asked()
        XCTAssertEqual(asked.count, 1); XCTAssertEqual(asked.first?.tool, "settings.write"); XCTAssertEqual(asked.first?.tier, .alter)
        await rig.relay.settledSignal.wait(1)
        let settled = rig.relay.settled()
        XCTAssertEqual(settled.count, 1); XCTAssertEqual(settled.first?.1.granted, true); XCTAssertEqual(settled.first?.1.by, "window")
    }
    // TSCASE index.test.ts:857
    func testIndexL857DoesNotRefuseForWantOfAWindowWhenADeviceCanBeAsked() async throws {
        let rig = try await booted(); rig.relay.delivers(true)
        let arguments = compact
        let call = Task { try await rig.call("settings_write", arguments) }
        // Answered when the question reaches the relay, never after a guessed sleep.
        await rig.relay.askedSignal.wait(1)
        let pending = await rig.runtime.consent.list()
        let question = try XCTUnwrap(pending.first)
        _ = await rig.runtime.consent.respond(id: question.id, approved: true, by: "window")
        let result = try await call.value
        XCTAssertEqual(rig.relay.asked().count, 1)
        XCTAssertFalse(failed(result)); XCTAssertEqual(rig.surface.setting("appearance.density"), .string("compact"))
    }
    // TSCASE index.test.ts:899
    func testIndexL899RefusesAtOnceWhenNeitherSurfaceCanBeAsked() async throws {
        let rig = try await booted(); rig.relay.delivers(false)
        let result = try await rig.call("settings_write", compact)
        XCTAssertTrue(failed(result)); XCTAssertEqual(rig.surface.setting("appearance.density"), .string("comfortable"))
        // The consent clock never moved and holds no timer: the refusal is the
        // no-approver path, not a 150ms timeout wearing its coat.
        XCTAssertEqual(rig.consentClock.pending(), 0)
        XCTAssertTrue(text(result).contains("there is no window open to ask"), text(result))
    }
    // TSCASE index.test.ts:920
    func testIndexL920StillAsksTheWindowWhenTheRelayBlowsUp() async throws {
        let rig = try await booted(); rig.windows.answer(Rig.approver, true)
        _ = try await rig.invoke("deck-control:consent-attach", from: Rig.approver)
        rig.relay.explodes(true)
        let result = try await rig.call("settings_write", compact)
        XCTAssertFalse(failed(result))
    }

    // MARK: the two ends, joined (S1i sweep)

    // TSCASE index.test.ts:397
    /// Drives the real Hoot start (BackendCopilotSessionRuntime.ensure) over the
    /// real door, wired the way BackendHootJoinAssembly wires it: off the live
    /// runtime's own `server` and `hootLayerTitles()`. Native difference, by
    /// design: Hoot is launched with a per-session lease config on that server
    /// (BackendSessionToolLeases), not the shared attended `configPath`, so the
    /// TS `toBe(handle.configPath)` is asserted as "the launched file names the
    /// server that is actually listening, with a bearer that server accepts".
    func testIndexL397IsTheConfigTheCopilotSessionIsActuallyLaunchedWith() async throws {
        let rig = try await booted(), runtime = rig.runtime
        let door = try BackendCopilotSessionMCPDoor(endpoint: BackendCopilotSessionSecurityEndpoint(server: runtime.server),
            userData: rig.root, titles: { runtime.hootLayerTitles() })
        let driver = BackendDeckCoreTestPortS1SweepHootDriver(root: rig.root)
        let hoot = BackendCopilotSessionRuntime(dependencies: .init(userData: rig.root.path, driver: driver,
            records: try BackendDeckCoreTestPortS1SweepHootRecords(rig.root), tools: door))
        addTeardownBlock { _ = try? await hoot.stop(); await door.stop() }

        let state = try await hoot.ensure()
        XCTAssertEqual(state.status, .running, state.problem ?? "")

        let launches = await driver.launches()
        XCTAssertEqual(launches.count, 1)
        let launched = try XCTUnwrap(launches.first)
        let config = try XCTUnwrap(launched.dropFirst().first)
        // The MCP pair, then the copilot's own layer.
        XCTAssertEqual(launched, ["--mcp-config", config, "--strict-mcp-config", "--append-system-prompt-file",
            BackendCopilotPaths(userData: rig.root.path).layer.composed])
        // Asserted on its own so dropping it reads as its own failure.
        XCTAssertTrue(launched.contains("--strict-mcp-config"))
        // The config named is the config of the server that is actually listening.
        let entry = try server(URL(fileURLWithPath: config))
        XCTAssertEqual(entry["url"], .string(runtime.endpoint.url.absoluteString))
        let bearer = try XCTUnwrap(entry["headers"]["Authorization"].string)
        let matched = await runtime.endpoint.callers.match(authorization: bearer)
        let grant = try XCTUnwrap(matched, "the launched config's bearer is not one the listening server accepts")
        let caller = await grant.caller()
        XCTAssertEqual(caller.kind, .local); XCTAssertEqual(caller.sessionID, "copilot-1")
    }
}
