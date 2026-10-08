import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// This suite performs real first-use downloads (about 60 MB) into a throwaway
/// data folder. Run only in macos/testpkg-p1 after checking the shared disk guard.
/// No installed app, real project, credential or production app-data is used.
@MainActor final class SFXBundledFlowTests: XCTestCase {
    func testCopiedSwiftProjectSetupRegressionFixAndRestartUsingBundledEngine() async throws {
        let fixture = try SFXBundledFlowFixture.make()
        defer { fixture.remove() }
        let events = SFXBundledFlowEvents()
        let service = fixture.service(events: events)
        let planner = BackendSFXSetupPlanner(userData: fixture.userData, executable: nil,
            inheritedEnvironment: ["HOME": fixture.root.path, "TMPDIR": fixture.root.path],
            locate: { throw NativeRPCError(code: "unavailable", message: "A copied sample must use its own pinned runtime.") },
            loginPath: { "/usr/bin:/bin:/usr/sbin:/sbin" }, provisioning: fixture.runtime)
        let setup = BackendSFXSetupService(
            plan: { try await planner.plan($0, prepareRuntime: $1) },
            setup: { try await service.setup($0) })
        let registry = NativeChannelRegistry()
        try await BackendStaysFixedChannels.register(registry: registry, ownerID: "SFX-isolated-owner", service: service)
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "SFX-isolated-owner")

        let cold = await service.status(fixture.project.path)
        XCTAssertEqual(cold["available"], .bool(true), cold.compact)
        XCTAssertEqual(cold["setUp"], .bool(false))
        XCTAssertTrue(cold["versionNote"].string?.contains("first time") == true)
        XCTAssertTrue(fixture.fetcher.requests.isEmpty, "Reading status must not download anything.")
        let notSetUp = try await registry.invoke("staysfixed:check", context: context, arguments: [.string(fixture.project.path)])
        XCTAssertEqual(notSetUp["ok"], .bool(false))
        XCTAssertTrue(notSetUp["message"].string?.contains("Set it up first") == true, notSetUp.compact)

        let previewOnly = try await setup.preview(fixture.project.path, checkCommand: SFXBundledFlowFixture.command)
        XCTAssertTrue(fixture.fetcher.requests.isEmpty, "Opening guided setup must remain download-free.")
        XCTAssertNil(BackendStaysFixedWhere.config(fixture.project.path), previewOnly.compact)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent(".staysfixed").path))

        do {
            _ = try await setup.preview(fixture.project.path, checkCommand: "/usr/bin/swift\u{0000} SFXGreeting.swift")
            XCTFail("A command with an embedded NUL must be rejected before configuration or runtime writes.")
        } catch let error as NativeRPCError {
            XCTAssertEqual(error.code, "setup-needs-review", error.localizedDescription)
            XCTAssertTrue(error.message.contains("one line") && error.message.contains("preview"), "Tell the person how to enter a usable command: " + error.message)
        }
        XCTAssertNil(BackendStaysFixedWhere.config(fixture.project.path))
        XCTAssertTrue(fixture.fetcher.requests.isEmpty)

        let missingGit = try await setup.preview(fixture.project.path, checkCommand: SFXBundledFlowFixture.command, prepareRuntime: true)
        XCTAssertEqual(missingGit["canApply"], .bool(false), missingGit.compact)
        XCTAssertTrue(missingGit["problem"].string?.contains("Set up Git") == true
            && missingGit["problem"].string?.contains("preview again") == true,
            "Missing Git needs a clear next step: " + missingGit.compact)
        XCTAssertNil(BackendStaysFixedWhere.config(fixture.project.path))

        // Guided setup requires a Git folder. An initialized repository with no
        // commit still exercises the engine's actionable missing-history error.
        try fixture.initializeRepository()

        let preview = try await setup.preview(fixture.project.path, checkCommand: SFXBundledFlowFixture.command, prepareRuntime: true)
        let token = try XCTUnwrap(preview["token"].string, preview.compact)
        XCTAssertNil(BackendStaysFixedWhere.config(fixture.project.path), "A prepared preview must still write no config.")
        let applied = try await setup.apply(fixture.project.path, token: token)
        XCTAssertEqual(applied["ok"], .bool(true), applied.compact)
        let configName = try XCTUnwrap(BackendStaysFixedWhere.config(fixture.project.path))
        let config = try NativeRPCValue.parseJSON(Data(contentsOf: fixture.project.appendingPathComponent(configName)))
        XCTAssertEqual(config["process"]["commands"].elements?.first?["run"], .string(SFXBundledFlowFixture.command))
        XCTAssertTrue(try fixture.originalIsUntouched(), "Setup may change only the fresh project copy.")
        let installedValue = await fixture.runtime.installed()
        let installed = try XCTUnwrap(installedValue)
        XCTAssertEqual(try installed.engineHome().version, BackendNodelessStaysFixedPins.staysFixedVersion)
        let pins = try BackendNodelessStaysFixedPins.current()
        XCTAssertEqual(fixture.fetcher.requests, pins.artifacts.compactMap { $0.url?.absoluteString }, "Use production pins, once per network artifact.")
        XCTAssertTrue(installed.root.path.hasPrefix(fixture.root.path + "/"))

        let noGit = try await service.check(fixture.project.path, by: "SFX sample")
        XCTAssertEqual(noGit["verdict"], .string("could-not-run"), noGit.compact)
        XCTAssertTrue(noGit["headline"].string?.contains("git") == true, noGit.compact)
        XCTAssertTrue(noGit["headline"].string?.contains("commit") == true, "The error must say how to establish a usable history: " + noGit.compact)
        evidence("missing history", noGit)
        try fixture.createInitialCommit()

        let unchecked = try await service.markGood(fixture.project.path, anyway: false)
        XCTAssertEqual(unchecked["marked"], .bool(false), unchecked.compact)
        XCTAssertEqual(unchecked["already"], .bool(false), unchecked.compact)
        XCTAssertTrue(unchecked["summary"].string?.localizedCaseInsensitiveContains("check") == true, unchecked.compact)
        let first = try await check(registry, context: context, project: fixture.project)
        XCTAssertEqual(first["verdict"], .string("not-compared"), first.compact)
        XCTAssertEqual(first["against"], .null, "A first run must not pretend a baseline already exists.")
        let firstRaw = try lastRaw(fixture.project)
        XCTAssertGreaterThan(firstRaw["coverage"]["paths"].number ?? 0, 0, firstRaw.compact)
        XCTAssertGreaterThan(firstRaw["coverage"]["journeys"].number ?? 0, 0, "The real Swift command must be walked.")
        evidence("first check", first)

        let mark = try await service.markGood(fixture.project.path, anyway: false)
        XCTAssertEqual(mark["marked"], .bool(true), mark.compact)
        let good = try await check(registry, context: context, project: fixture.project)
        XCTAssertEqual(good["verdict"], .string("clean"), good.compact)
        XCTAssertEqual(good["differences"], .array([]))
        XCTAssertFalse(good["against"].isNullish)
        evidence("baseline pass", good)

        try fixture.setRegression(true)
        let broken = try await check(registry, context: context, project: fixture.project)
        XCTAssertEqual(broken["verdict"], .string("differences"), broken.compact)
        let changes = (broken["differences"].elements ?? []).flatMap { $0["changes"].elements ?? [] }
        XCTAssertTrue(changes.contains { change in
            change["before"].string?.contains("Total: 10.00") == true && change["after"].string?.contains("Total: 99.00") == true
        }, "A real printed result must identify the regression, beyond a source-file edit: " + broken.compact)
        let refused = try await service.markGood(fixture.project.path, anyway: false)
        XCTAssertEqual(refused["marked"], .bool(false), refused.compact)
        XCTAssertEqual(refused["refusedFor"], .string("differences"), "A regression must not silently become normal.")
        evidence("intentional regression", broken)

        try fixture.setRegression(false)
        let fixed = try await check(registry, context: context, project: fixture.project)
        XCTAssertEqual(fixed["verdict"], .string("clean"), fixed.compact)
        XCTAssertEqual(fixed["differences"], .array([]))
        evidence("fixed recheck", fixed)
        let off = try await service.setAgents(fixture.project.path, on: false)
        XCTAssertEqual(off["agents"], .bool(false))
        await service.dispose()

        let restartedRuntime = try BackendNodelessStaysFixedRuntime(userData: fixture.userData,
            bundledProduct: fixture.productArchive, fetcher: fixture.fetcher)
        let restoredInstall = await restartedRuntime.installed()
        XCTAssertEqual(restoredInstall, installed, "Restart must reuse the same verified runtime install.")
        let restarted = fixture.service(provisioning: restartedRuntime)
        let restored = await restarted.status(fixture.project.path)
        XCTAssertEqual(restored["setUp"], .bool(true), restored.compact)
        XCTAssertEqual(restored["agents"], .bool(false))
        XCTAssertEqual(restored["last"]["verdict"], .string("clean"))
        XCTAssertEqual(restored["last"]["runId"], fixed["runId"])
        XCTAssertFalse(restored["reference"].isNullish, "The saved good build must survive service restart.")
        let afterRestart = try await restarted.check(fixture.project.path, by: "SFX restart")
        XCTAssertEqual(afterRestart["verdict"], .string("clean"), afterRestart.compact)
        XCTAssertEqual(fixture.fetcher.requests.count, 4, "No extra download after setup, checks or restart.")
        XCTAssertTrue(events.values.count >= 6, "Native state must be announced as setup and checks change.")
        XCTAssertTrue(events.values.allSatisfy { $0 == fixture.project.path }, "Events must name only the copied sample project.")
        XCTAssertTrue(try fixture.originalIsUntouched())

        // A second fresh copy shares only this fixture's isolated verified
        // runtime. No code/command to observe must never produce a clean badge.
        let noCoverageProject = try fixture.copyNoCoverageSample()
        let emptyPreview = try await setup.preview(noCoverageProject.path, prepareRuntime: true)
        XCTAssertEqual(emptyPreview["canApply"], .bool(false), emptyPreview.compact)
        XCTAssertEqual(emptyPreview["commandNeeded"], .bool(true), emptyPreview.compact)
        XCTAssertFalse(emptyPreview["commandExplanation"].string?.isEmpty ?? true)
        XCTAssertNil(BackendStaysFixedWhere.config(noCoverageProject.path), "No useful coverage must not create a fake setup success.")
        let legacySetup = try await restarted.setup(noCoverageProject.path)
        XCTAssertEqual(legacySetup["ok"], .bool(true), legacySetup.compact)
        let nothing = try await restarted.check(noCoverageProject.path, by: "SFX empty sample")
        XCTAssertNotEqual(nothing["verdict"], .string("clean"), nothing.compact)
        let noBaseline = try await restarted.markGood(noCoverageProject.path, anyway: false)
        XCTAssertEqual(noBaseline["marked"], .bool(false), "A run that observed nothing must not become the good build: " + noBaseline.compact)
        let forcedNoBaseline = try await restarted.markGood(noCoverageProject.path, anyway: true)
        XCTAssertEqual(forcedNoBaseline["marked"], .bool(false), "Accepting differences cannot bypass an empty recording: " + forcedNoBaseline.compact)
        XCTAssertEqual(fixture.fetcher.requests.count, 4, "Additional isolated samples reuse this runtime.")
        evidence("no coverage", nothing)
        await restarted.dispose()
        evidence("restart pass", afterRestart)
    }

    func testMissingBundledEngineExplainsUnavailableAndWritesNothing() async throws {
        let fixture = try SFXBundledFlowFixture.make()
        defer { fixture.remove() }
        let missing = try BackendNodelessStaysFixedRuntime(userData: fixture.userData, bundledProduct: nil, fetcher: fixture.fetcher)
        let planner = BackendSFXSetupPlanner(userData: fixture.userData, executable: nil,
            inheritedEnvironment: ["HOME": fixture.root.path],
            locate: { throw NativeRPCError(code: "unavailable", message: "There is no replacement engine in this test.") },
            loginPath: { "/usr/bin:/bin" }, provisioning: missing)
        let service = fixture.service(provisioning: missing)
        let setup = BackendSFXSetupService(plan: { try await planner.plan($0, prepareRuntime: $1) },
                                          setup: { try await service.setup($0) })
        do {
            let preview = try await setup.preview(fixture.project.path, checkCommand: SFXBundledFlowFixture.command, prepareRuntime: true)
            XCTAssertEqual(preview["canApply"], .bool(false), preview.compact)
            XCTAssertFalse(preview["problem"].string?.isEmpty ?? true, "A missing bundled engine needs a visible next step.")
        } catch let error as NativeRPCError {
            XCTAssertEqual(error.code, "unavailable")
            XCTAssertTrue(error.message.contains("Stays Fixed"), error.message)
            XCTAssertTrue(error.message.localizedCaseInsensitiveContains("update")
                || error.message.localizedCaseInsensitiveContains("reopen"), "Missing bundled engine needs an action the user can take: " + error.message)
        }
        XCTAssertTrue(fixture.fetcher.requests.isEmpty, "A missing product archive must fail before any network request.")
        XCTAssertNil(BackendStaysFixedWhere.config(fixture.project.path))
        let installed = await missing.installed()
        XCTAssertNil(installed)
    }

    private func check(_ registry: NativeChannelRegistry, context: NativeRPCContext, project: URL) async throws -> NativeRPCValue {
        let reply = try await registry.invoke("staysfixed:check", context: context, arguments: [.string(project.path)])
        XCTAssertEqual(reply["ok"], .bool(true), reply.compact)
        return reply["results"]
    }

    private func lastRaw(_ project: URL) throws -> NativeRPCValue {
        let data = try Data(contentsOf: project.appendingPathComponent(".staysfixed/v2/last-check.json"))
        let envelope = try NativeRPCValue.parseJSON(data)
        if let json = envelope["result"].string { return try NativeRPCValue.parseJSON(Data(json.utf8)) }
        return envelope["result"]
    }

    private func evidence(_ phase: String, _ value: NativeRPCValue) {
        // Compact, timestamped real-engine results remain in the parent test log.
        print("SFX bundled flow " + ISO8601DateFormatter().string(from: Date()) + " " + phase + ": " + value.compact)
    }
}
