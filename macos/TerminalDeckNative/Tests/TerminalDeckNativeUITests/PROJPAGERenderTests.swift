import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// WIP actual-view checks. No app/window launch, production graph or AI calls.
/// Root runs through one-build.sh PROJPAGE with TD_PROJPAGE_FOCUSED=1.
final class PROJPAGERenderTests: XCTestCase {
    private func requireFocused() throws {
        guard ProcessInfo.processInfo.environment["TD_PROJPAGE_FOCUSED"] == "1" else {
            throw XCTSkip("WIP PROJPAGE: focused fixture checks only until READY")
        }
        guard (NSHomeDirectory().hasPrefix("/private/tmp/td-projpage-") || NSHomeDirectory().hasPrefix("/tmp/td-projpage-")),
              ProcessInfo.processInfo.environment["TD_NATIVE_DATA_DIR"]?.hasPrefix("/private/tmp/td-projpage-") == true else {
            throw Self.failure("Private PROJPAGE home/data required for every focused fixture test")
        }
    }

    @MainActor func testNewSessionPrefillsProjectAndIndependentClearsFolder() throws {
        try requireFocused()
        let projects = Self.projects
        let model = Self.newSession(projects: projects)
        XCTAssertTrue(model.isRenderFixture)
        XCTAssertEqual(model.projectIdentityID, "fixture-imatch")
        XCTAssertEqual(model.projectName, "iMatch")
        model.chooseProject(projects[2])
        XCTAssertEqual(model.projectIdentityID, "independent")
        XCTAssertNil(model.selectedPath)
        model.chooseProject(projects[1])
        XCTAssertEqual(model.projectIdentityID, "fixture-crm")
        XCTAssertEqual(model.selectedPath, projects[1].folders.first)
        XCTAssertEqual(model.projectName, "CRM")
    }

    @MainActor func testTaskScopeDefaultsAllAndExplicitIdentityOverridesCwd() throws {
        try requireFocused()
        let scope = TKTasksProjectScope.renderFixture(projects: Self.projects)
        let state = Self.taskState
        XCTAssertNil(scope.selectedProjectID)
        XCTAssertEqual(scope.currentName, "All projects")
        XCTAssertEqual(scope.effective, .all)
        XCTAssertEqual(scope.scoped(state).tasks.map(\.id), state.tasks.map(\.id))
        scope.choose("fixture-imatch")
        XCTAssertEqual(scope.scoped(state).tasks.map(\.id), ["imatch-task"])
        scope.choose("independent")
        XCTAssertEqual(scope.scoped(state).tasks.map(\.id), ["independent-task"])
        XCTAssertNil(scope.current)
        scope.choose("fixture-imatch")
        scope.reveal("crm-task", in: state)
        XCTAssertEqual(scope.selectedProjectID, "fixture-crm", "Reminder changes the previous project filter")
        XCTAssertEqual(scope.scoped(state).tasks.map(\.id), ["crm-task"])
        XCTAssertEqual(scope.current, Self.projects[1].folders.first)
        XCTAssertEqual(state.tasks[1].project, Self.projects[0].folders.first,
            "CRM task keeps its separate execution folder")
    }

    @MainActor func testSettingsFixtureChangesUseActualHandlerWithoutTransport() async throws {
        try requireFocused()
        var writes = 0
        let settings = PROJPAGESettingsModel(values: ["defaultCodingAI": "Claude Code"], invoke: { _, _ in
            writes += 1
            throw Self.failure("Fixture attempted settings transport")
        })
        XCTAssertTrue(settings.isRenderFixture)
        await settings.load(Self.projects[0].id)
        settings.set("defaultModel", "Fixture model", projectID: Self.projects[0].id)
        XCTAssertEqual(settings.values["defaultModel"] as? String, "Fixture model")
        XCTAssertFalse(settings.loading)
        XCTAssertEqual(writes, 0)
    }

    @MainActor func testUsageEventWinsOverDelayedRPCAndSettingsDoNotBlockCards() async throws {
        try requireFocused()
        for lateFailure in [false, true] {
            var handlers: [String: ([Any]) -> Void] = [:]
            var usageReply: CheckedContinuation<NativeRPCValue, Error>?
            var settingsReply: CheckedContinuation<NativeRPCValue, Never>?
            let ready = XCTestExpectation(description: "Usage and settings reads are pending together")
            var usageReads = 0, watches = 0, releases = 0, cancellations = 0, settingsWrites = 0
            let project = Self.projects[0], folder = Self.projects[0].folders[0]
            let model = PROJPAGEOverviewModel(read: { channel, args in
                switch channel {
                case "cost:project":
                    usageReads += 1
                    let value: NativeRPCValue = try await withCheckedThrowingContinuation { continuation in
                        usageReply = continuation
                        if settingsReply != nil { ready.fulfill() }
                    }
                    return value.foundation
                case "project-settings:get":
                    let value: NativeRPCValue = await withCheckedContinuation { continuation in
                        settingsReply = continuation
                        if usageReply != nil { ready.fulfill() }
                    }
                    return value.foundation
                case "project-settings:set": settingsWrites += 1; return [:] as [String: Any]
                case "session:list", "servers:list": return [] as [Any]
                case "artifacts:list":
                    XCTAssertEqual((args.first as? [String: String])?["scope"], "project")
                    return ["artifacts": []] as [String: Any]
                default: return [:] as [String: Any]
                }
            }, observe: { channel, receive in
                handlers[channel] = receive
                return { cancellations += 1 }
            }, retainWatch: { path in
                XCTAssertNotNil(handlers["cost:update"], "Subscribe before retaining the watch")
                XCTAssertEqual(path, folder); watches += 1
            }, releaseWatch: { _ in releases += 1 }, sessionStatuses: { [:] })
            let loader = Task { await model.load(project: project, folder: folder) }
            let phase = await XCTWaiter.fulfillment(of: [ready], timeout: 2)
            guard phase == .completed else {
                model.stop()
                usageReply?.resume(throwing: Self.failure("Fixture read timed out")); usageReply = nil
                settingsReply?.resume(returning: .object([])); settingsReply = nil
                await loader.value
                throw Self.failure("Usage and settings reads did not start together")
            }
            XCTAssertEqual(watches, 1)
            XCTAssertNotNil(settingsReply, "Settings stay pending while usage arrives")
            handlers["cost:update"]?([["cwd": folder + "/unrelated", "requests": 99]])
            XCTAssertNil(model.cards["usage"])
            handlers["cost:update"]?([["cwd": folder + "/Sources/..", "requests": 42,
                "periods": ["today": ["requests": 42]]]])
            XCTAssertEqual(model.cards["usage"]?["requests"].number, 42)
            if lateFailure { usageReply?.resume(throwing: Self.failure("Old read failed")) }
            else { usageReply?.resume(returning: try NativeRPCValue.fromFoundation(["cwd": folder, "requests": 1])) }
            usageReply = nil
            settingsReply?.resume(returning: try NativeRPCValue.fromFoundation(["values": ["hiddenOverviewCards": "[\"usage\"]"]]))
            settingsReply = nil
            await loader.value
            XCTAssertEqual(model.cards["usage"]?["requests"].number, 42, "An older RPC cannot replace the event")
            XCTAssertNil(model.failures["usage"], "An older RPC error cannot cover the current event")
            XCTAssertEqual(usageReads, 1, "The event uses its payload without another RPC")
            XCTAssertEqual(settingsWrites, 0, "Initial preference restoration does not write back")
            XCTAssertEqual(model.hidden, ["usage"])
            model.stop()
            XCTAssertEqual(releases, 1)
            XCTAssertEqual(cancellations, 7)
            handlers["cost:update"]?([["cwd": folder, "requests": 999]])
            XCTAssertEqual(model.cards["usage"]?["requests"].number, 42)
        }
    }

    @MainActor func testHiddenCardsRoundTripThroughScalarSettingsFixture() async throws {
        try requireFocused()
        var stored = "[\"usage\",\"unknown\"]"
        var writes = 0
        let written = XCTestExpectation(description: "Hidden-card scalar preference was saved")
        let model = PROJPAGEOverviewModel(read: { channel, args in
            if channel == "project-settings:get" { return ["values": ["hiddenOverviewCards": stored]] }
            if channel == "project-settings:set" {
                let payload = args.first as? [String: Any]
                let values = payload?["values"] as? [String: Any]
                // The current backend sanitizer permits scalar strings, not arrays.
                guard let scalar = values?["hiddenOverviewCards"] as? String else {
                    XCTFail("Preference must survive the scalar settings sanitizer")
                    throw Self.failure("Non-scalar preference")
                }
                stored = scalar; writes += 1; written.fulfill()
                return [:] as [String: Any]
            }
            if channel == "session:list" || channel == "servers:list" { return [] as [Any] }
            return [:] as [String: Any]
        }, observe: { _, _ in {} }, retainWatch: { _ in }, releaseWatch: { _ in }, sessionStatuses: { [:] })
        await model.load(project: Self.projects[0], folder: Self.projects[0].folders[0])
        XCTAssertEqual(model.hidden, ["usage"])
        XCTAssertEqual(writes, 0)
        model.hidden.insert("git")
        let saved = await XCTWaiter.fulfillment(of: [written], timeout: 2)
        guard saved == .completed else {
            model.stop()
            throw Self.failure("Hidden-card preference was not saved")
        }
        XCTAssertEqual(stored, "[\"git\",\"usage\"]")
        XCTAssertEqual(PROJPAGEOverviewModel.decodedHiddenCards(.string(stored)), ["git", "usage"])
        XCTAssertEqual(PROJPAGEOverviewModel.decodedHiddenCards(.array([.string("agents"), .string("unknown")])), ["agents"])
        XCTAssertLessThanOrEqual(PROJPAGEOverviewModel.hideableCards.count, 8)
        model.stop()
        await model.load(project: Self.projects[0], folder: Self.projects[0].folders[0])
        XCTAssertEqual(model.hidden, ["git", "usage"])
        XCTAssertEqual(writes, 1)
        model.stop()
    }

    @MainActor func testOverviewUsesProjectProvenanceClockAndRunningAssignments() throws {
        try requireFocused()
        let project = Self.projects[0]
        let model = PROJPAGEOverviewModel(read: { _, _ in throw Self.failure("No reads in metadata fixture") },
            observe: { _, _ in {} }, retainWatch: { _ in }, releaseWatch: { _ in }, sessionStatuses: { [:] },
            now: { Self.fixtureNow }, calendar: Self.fixtureCalendar)
        model.project = project; model.folder = project.folders[0]
        let inferred = try NativeRPCValue.fromFoundation(["projectId": "independent", "projectIdInferred": true,
            "cwd": project.folders[0] + "/Sources"])
        XCTAssertTrue(model.belongs(inferred), "Fallback identity resolves from the registered folder")
        XCTAssertFalse(model.belongs(inferred.setting("projectIdInferred", .bool(false))), "Explicit Independent remains independent")
        XCTAssertFalse(model.belongs(inferred.setting("cwd", .string("/scratch/unrelated"))))
        XCTAssertEqual(model.sessionAge(try NativeRPCValue.fromFoundation(["createdAt": Self.fixtureNow.timeIntervalSince1970 * 1000 - 7200000])), "2 hr")
        XCTAssertNil(model.sessionAge(.object([])))
        let state = try NativeRPCValue.fromFoundation([
            "agents": [["id": "a", "projectId": project.id, "status": "active"],
                       ["id": "b", "projectId": project.id, "status": "active"]],
            "tasks": [["id": "1", "projectId": project.id, "assignee": "a", "process": "running"],
                      ["id": "2", "projectId": project.id, "assignee": "a", "process": "running"],
                      ["id": "3", "projectId": project.id, "assignee": "b", "process": "queued"],
                      ["id": "4", "projectId": "independent", "assignee": "b", "process": "running"]]])
        XCTAssertEqual(model.workingAgentCount(state), 1, "Unique running assignments, not active profile settings")
        let day = try XCTUnwrap(Self.fixtureCalendar.dateInterval(of: .day, for: Self.fixtureNow))
        let artifacts = try NativeRPCValue.fromFoundation(["artifacts": [
            ["firstAt": day.start.timeIntervalSince1970 * 1000],
            ["firstAt": Self.fixtureNow.timeIntervalSince1970 * 1000],
            ["firstAt": day.end.timeIntervalSince1970 * 1000],
            ["firstAt": day.start.timeIntervalSince1970 * 1000 - 1]]])
        XCTAssertEqual(model.artifactsToday(artifacts), 2, "Today uses an inclusive start and exclusive end")
    }

    @MainActor private static var fixtureNow: Date { Date(timeIntervalSince1970: 1_791_619_200) }
    @MainActor private static var fixtureCalendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    @MainActor private static func fixedFixture(project: PROJProject, firstRun: Bool,
        askAI: @escaping NativeSFXModel.AskAI) async -> NativeSFXModel {
        let checkedAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-300))
        let model = NativeSFXModel(invoke: { channel, _ in
            switch channel {
            case StaysFixedWire.status:
                var status: [String: Any] = ["projectPath": project.folders[0], "available": true,
                    "setUp": !firstRun, "git": true, "agents": !firstRun,
                    "versionNote": "Fixture checker", "guards": [["name": "Swift tests", "because": "Check behavior before saving"]]]
                if !firstRun {
                    status["reference"] = ["name": "Known good build", "setAt": checkedAt]
                    status["last"] = ["runId": "fixture-healthy", "at": checkedAt, "durationMs": 1200,
                        "verdict": "clean", "headline": "The checked behavior still works.",
                        "against": "Known good build", "checked": "Fixture Swift checks", "differences": [] as [Any],
                        "unchanged": "All recorded fixture checks passed.", "unsteady": 0, "detail": "Fixture report"]
                }
                return status
            case SFXSetupWire.preview:
                return ["partialSetup": false, "alreadySetUp": !firstRun,
                    "summary": "Review the checks before setting up this fixture project.",
                    "configFile": ".staysfixed.json", "canApply": firstRun, "token": firstRun ? "fixture-preview" : "",
                    "checkCommand": "swift test", "commandExplanation": "Run the fixture project's Swift checks.",
                    "ready": ["Swift tests", "Git working tree"],
                    "files": [["path": ".staysfixed.json", "action": "create", "summary": "Save the reviewed checks"]],
                    "products": [["name": "Swift fixture", "kind": "command-line", "evidence": ["Package.swift"]]]] as [String: Any]
            default: throw Self.failure("Unexpected Stays Fixed fixture call: \(channel)")
            }
        }, askAI: askAI)
        model.show(project.folders[0]); await model.load()
        return model
    }

    // Draft only: insert these methods in PROJPAGERenderTests.
    // Run through the parent's focused XCTest gate; no product/test target save here.
    // All invokes, storage and navigation are supplied stubs. No real AI is launched.

    @MainActor private static func submittingModel(effects: NativeNewSessionEffects,
                                                  context: NewSessionContext? = nil) -> NativeNewSessionModel {
        let model = NativeNewSessionModel(
            context: context ?? .init(projectPath: projects[0].folders[0]),
            projectID: projects[1].id, effects: effects)
        model.configureRenderFixture(projects: projects,
            providers: NewSessionProviders.rows(detected: CodingAIJSON(["claude": true]), added: []))
        model.chosenProvider = "claude"
        return model
    }

    @MainActor func testNativeSubmitKeepsExplicitProjectSeparateFromFolder() async throws {
        try requireFocused()
        var inputs: [[String: Any]] = [], calls: [String] = [], opened: [String] = []
        var savedMemory: [String] = [], lastFolders: [String] = [], dismissals = 0
        let projectID = Self.projects[1].id, folder = Self.projects[0].folders[0]
        let effects = NativeNewSessionEffects(invoke: { channel, args in
            calls.append(channel)
            if channel == "session:create" {
                let input = try XCTUnwrap(args.first as? [String: Any])
                inputs.append(input)
                return ["id": "fake-session", "cwd": folder, "projectId": projectID] as [String: Any]
            }
            XCTAssertEqual(channel, "projects:add")
            XCTAssertEqual(args.first as? String, folder)
            return true
        }, writeMemory: { savedMemory.append($0) }, writeLastFolder: { lastFolders.append($0) },
           openedLocal: { opened.append($0["id"] as? String ?? "missing") }, dismiss: { dismissals += 1 })
        let model = Self.submittingModel(effects: effects)
        XCTAssertTrue(model.canStart)
        await model.submitNative()
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0]["projectId"] as? String, projectID)
        XCTAssertEqual(inputs[0]["cwd"] as? String, folder)
        XCTAssertNil(inputs[0]["firstPrompt"], "No message may be sent automatically before login")
        XCTAssertEqual(calls, ["session:create", "projects:add"])
        XCTAssertEqual(opened, ["fake-session"])
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(lastFolders, [folder])
        XCTAssertEqual(savedMemory.count, 1)
        XCTAssertEqual(NewSessionMemory.parse(savedMemory[0]).defaults(for: folder).provider, "claude")
        XCTAssertEqual(model.createdSessionID, "fake-session")
        XCTAssertFalse(model.starting)
        XCTAssertNil(model.error)
        await model.submitNative()
        XCTAssertEqual(inputs.count, 1, "A completed submit must not create again")
    }

    @MainActor func testFailedNativeStartKeepsDialogOpenAndReportsError() async throws {
        try requireFocused()
        var calls = 0, opens = 0, saves = 0, dismissals = 0
        let effects = NativeNewSessionEffects(invoke: { channel, _ in
            XCTAssertEqual(channel, "session:create")
            calls += 1
            throw NSError(domain: "PROJPAGE-stub", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The fixture refused the session."])
        }, writeMemory: { _ in saves += 1 }, openedLocal: { _ in opens += 1 },
           dismiss: { dismissals += 1 })
        let model = Self.submittingModel(effects: effects)
        await model.submitNative()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(dismissals, 0)
        XCTAssertNil(model.createdSessionID)
        XCTAssertFalse(model.starting)
        XCTAssertEqual(model.error, "The fixture refused the session.")
    }

    @MainActor func testCreatedSessionSurvivesRecentFolderFailureWithoutDuplicateCreate() async throws {
        try requireFocused()
        var creates = 0, opens = 0, dismissals = 0
        let projectID = Self.projects[1].id
        let effects = NativeNewSessionEffects(invoke: { channel, _ in
            if channel == "session:create" {
                creates += 1
                return ["id": "already-created", "projectId": projectID] as [String: Any]
            }
            XCTAssertEqual(channel, "projects:add")
            throw NSError(domain: "PROJPAGE-stub", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Recent folders are busy."])
        }, openedLocal: { _ in opens += 1 }, dismiss: { dismissals += 1 })
        let model = Self.submittingModel(effects: effects)
        await model.submitNative()
        XCTAssertEqual(model.createdSessionID, "already-created")
        XCTAssertNil(model.error, "The session exists; this is an ancillary warning")
        XCTAssertTrue(model.warning?.hasPrefix("Session started.") == true)
        XCTAssertFalse(model.canStart)
        XCTAssertEqual(dismissals, 0, "The warning stays visible until Done")
        await model.submitNative()
        XCTAssertEqual(creates, 1)
        XCTAssertEqual(opens, 1)
        model.cancel()
        XCTAssertEqual(dismissals, 1)
    }

    @MainActor func testRememberOffSkipsChoiceWriteButRetainsLastLocalFolder() async throws {
        try requireFocused()
        var memoryWrites = 0, lastFolders: [String] = []
        let effects = NativeNewSessionEffects(invoke: { channel, _ in
            channel == "session:create"
                ? ["id": "remember-off", "projectId": Self.projects[1].id] as [String: Any] as Any
                : true as Any
        }, writeMemory: { _ in memoryWrites += 1 }, writeLastFolder: { lastFolders.append($0) })
        let model = Self.submittingModel(effects: effects)
        model.remember = false
        await model.submitNative()
        XCTAssertEqual(memoryWrites, 0)
        XCTAssertEqual(lastFolders, [Self.projects[0].folders[0]])
    }

    @MainActor func testNativeRemoteIdentityGapRefusesBeforeAnyCreate() async throws {
        try requireFocused()
        var invokes = 0, memoryWrites = 0, dismissals = 0
        let effects = NativeNewSessionEffects(invoke: { _, _ in
            invokes += 1
            XCTFail("A machine with no project identity contract must not receive any create")
            return false
        }, writeMemory: { _ in memoryWrites += 1 }, dismiss: { dismissals += 1 })
        let context = NewSessionContext(projectPath: "/scratch/remote/execution", machineId: "fixture-peer",
            machines: [.init(id: "fixture-peer", name: "Fixture peer", folders: ["/scratch/remote/execution"])])
        let model = Self.submittingModel(effects: effects, context: context)
        await model.submitNative()
        XCTAssertEqual(invokes, 0)
        XCTAssertEqual(memoryWrites, 0)
        XCTAssertEqual(dismissals, 0)
        XCTAssertTrue(model.error?.contains("retain the selected project") == true)
        XCTAssertNil(model.createdSessionID)
    }

    @MainActor func testIdentityAwareRemoteHandlerDoesNoLocalBookkeeping() async throws {
        try requireFocused()
        var localInvokes = 0, localMemoryWrites = 0, observed: [(String, String, String)] = [], opened = 0
        let effects = NativeNewSessionEffects(invoke: { _, _ in
            localInvokes += 1; XCTFail("Remote submit must not register a local folder"); return false
        }, writeMemory: { _ in localMemoryWrites += 1 }, startMachine: { machine, request, projectID in
            observed.append((machine, request.cwd, projectID))
            return "observed-remote-session" // Stub represents actual machines:state observation, not Bool sent.
        }, openedMachine: { machine, session, projectID in
            XCTAssertEqual(machine, "fixture-peer")
            XCTAssertEqual(session, "observed-remote-session")
            XCTAssertEqual(projectID, Self.projects[1].id)
            opened += 1
        })
        let context = NewSessionContext(projectPath: "/scratch/remote/execution", machineId: "fixture-peer",
            machines: [.init(id: "fixture-peer", name: "Fixture peer", folders: ["/scratch/remote/execution"])])
        let model = Self.submittingModel(effects: effects, context: context)
        await model.submitNative()
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed[0].0, "fixture-peer")
        XCTAssertEqual(observed[0].1, "/scratch/remote/execution")
        XCTAssertEqual(observed[0].2, Self.projects[1].id)
        XCTAssertEqual(localInvokes, 0)
        XCTAssertEqual(localMemoryWrites, 0)
        XCTAssertEqual(opened, 1)
    }

    @MainActor func testReadinessRingKeepsUnavailableChecksUnfinished() throws {
        try requireFocused()
        let progress = AIRReadinessProgress(report: Self.report)
        XCTAssertEqual(progress.passing, 4)
        XCTAssertEqual(progress.remaining, 2)
        XCTAssertFalse(progress.ready)
        let unverified = AIRReadinessProgress(report: .init(projectPath: Self.projects[0].folders[0], score: 100,
            band: .strong, checks: [.init(id: "readme", status: .pass),
                .init(id: "test-script", status: .skip, detail: "This check could not run: fixture command unavailable.")]))
        XCTAssertEqual(unverified.passing + unverified.remaining, 2)
        XCTAssertEqual(unverified.unverified, 1)
        XCTAssertEqual(unverified.skipped, 0)
        XCTAssertFalse(unverified.ready)
    }

    @MainActor func testActualViewsRenderLightAndDarkWithoutAppOrWindowLaunch() async throws {
        try requireFocused()
        guard (NSHomeDirectory().hasPrefix("/private/tmp/td-projpage-") || NSHomeDirectory().hasPrefix("/tmp/td-projpage-")),
              ProcessInfo.processInfo.environment["TD_NATIVE_DATA_DIR"]?.hasPrefix("/private/tmp/td-projpage-") == true,
              let destination = ProcessInfo.processInfo.environment["TD_PROJPAGE_OUTPUT"],
              URL(fileURLWithPath: destination).lastPathComponent == "built.noindex" else {
            throw Self.failure("Private PROJPAGE test home/data and built.noindex output are required")
        }
        let output = URL(fileURLWithPath: destination).standardizedFileURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let report = Self.report
        let project = Self.projects[0]
        var transportAttempts = 0
        var aiAttempts = 0
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let readiness = NativeAIRReadinessModel(report: report, dependencies: .init(
                invoke: { channel, _ in
                    transportAttempts += 1
                    XCTFail("Render attempted transport: \(channel)")
                    throw Self.failure("Fixture transport is forbidden")
                }, launchSession: { _ in
                    aiAttempts += 1
                    XCTFail("Render attempted AI launch")
                    throw Self.failure("Fixture AI is forbidden")
                }, observe: { _, _ in {} }))
            try await Self.capture(Self.page(project: project, selected: .readiness) {
                NativeAIRReadinessScreen(model: readiness, projectPath: project.folders[0], projectName: project.name,
                    onFixAllWithHoot: {}, onReviewChanges: {}, embedded: true)
            }, dark: dark, size: .init(width: 1320, height: 820),
                to: output.appendingPathComponent("PROJPAGE-provisional-readiness-\(suffix).png"))
            let overview = PROJPAGEOverviewModel(cards: try Self.overviewCards(), read: { channel, _ in
                transportAttempts += 1
                XCTFail("Render attempted overview transport: \(channel)")
                throw Self.failure("Fixture transport is forbidden")
            }, now: { Self.fixtureNow }, calendar: Self.fixtureCalendar)
            overview.project = project
            overview.folder = project.folders[0]
            XCTAssertEqual(overview.git?.unstaged.count, 19)
            XCTAssertEqual(overview.git?.untracked.count, 302)
            let agents = overview.cards["tasks"]?["agents"].elements ?? []
            XCTAssertEqual(agents.filter(overview.belongs).count, 24)
            XCTAssertFalse(overview.belongs(.object([.init("projectId", .string("independent"))])))
            try await Self.capture(Self.page(project: project, selected: .overview) {
                PROJPAGEOverviewContent(model: overview, project: project, navigate: { _ in }, fixWithHoot: {})
            }, dark: dark, size: .init(width: 1320, height: 820),
                to: output.appendingPathComponent("PROJPAGE-provisional-overview-\(suffix).png"))
            try await Self.capture(NativeNewSessionDialog(model: Self.newSession(projects: Self.projects))
                .background(PROJPAGEStyle.page), dark: dark, size: .init(width: 640, height: 560),
                to: output.appendingPathComponent("PROJPAGE-provisional-new-session-\(suffix).png"))
            let scope = TKTasksProjectScope.renderFixture(projects: Self.projects)
            try await Self.capture(TKTasksProjectBar(projects: scope).padding(24).background(PROJPAGEStyle.page),
                dark: dark, size: .init(width: 880, height: 180),
                to: output.appendingPathComponent("PROJPAGE-provisional-task-scope-\(suffix).png"))
            let files = Self.filesFixture(project: project)
            try await Self.capture(Self.page(project: project, selected: .files) {
                NativeFilesScreen(model: files, projectPath: project.folders[0], embedded: true, lifecycleEnabled: false)
            }, dark: dark, size: .init(width: 1320, height: 820),
                to: output.appendingPathComponent("PROJPAGE-provisional-files-\(suffix).png"))
            let changes = Self.gitFixture(project: project)
            try await Self.capture(Self.page(project: project, selected: .code) {
                PROJPAGECodeContent(selection: .constant("Changes")) {
                    NativeGitScreen(model: changes, projectPath: project.folders[0], embedded: true, lifecycleEnabled: false)
                }
            }, dark: dark, size: .init(width: 1320, height: 820),
                to: output.appendingPathComponent("PROJPAGE-provisional-changes-\(suffix).png"))
            // GH needs the lifecycle seam described below; no selected detail, so no child detail load.
            for area in [NativeGHArea.pulls, .issues, .actions] {
                let github = Self.githubFixture(project: project, area: area)
                var auth = GitHubAuthState()
                auth.connected = true; auth.login = "fixture-author"; auth.source = "gh-cli"
                auth.scopes = ["repo", "read:user"]; auth.scopesReported = true; auth.ghInstalled = true
                let account = GitHubScreenModel.renderFixture(cwd: project.folders[0], auth: auth)
                try await Self.capture(Self.page(project: project, selected: .code) {
                    PROJPAGECodeContent(selection: .constant(area.title)) {
                        NativeGitHubScreen(model: account, workspaceModel: github, projectPath: project.folders[0],
                            embedded: true, section: area.title, lifecycleEnabled: false)
                    }
                }, dark: dark, size: .init(width: 1320, height: 820),
                    to: output.appendingPathComponent("PROJPAGE-provisional-code-\(area.rawValue)-\(suffix).png"))
            }
            for firstRun in [false, true] {
                let fixed = await Self.fixedFixture(project: project, firstRun: firstRun, askAI: { _, _ in
                    aiAttempts += 1; XCTFail("Render attempted Stays Fixed AI launch")
                    throw Self.failure("Fixture AI is forbidden")
                })
                XCTAssertNotNil(fixed.status)
                XCTAssertNil(fixed.status?.running)
                if firstRun { XCTAssertFalse(fixed.status?.setUp ?? true); XCTAssertNotNil(fixed.preview) }
                else { XCTAssertEqual(fixed.status?.last?.verdict, .clean) }
                let state = firstRun ? "first-run" : "healthy"
                try await Self.capture(Self.page(project: project, selected: .staysFixed) {
                    NativeSFXPage(model: fixed, sourceControl: {}, copy: { _ in })
                }, dark: dark, size: .init(width: 1320, height: 820),
                    to: output.appendingPathComponent("PROJPAGE-provisional-stays-fixed-\(state)-\(suffix).png"))
                fixed.leave()
            }
            for section in ["General", "Server", "Tasks", "Agents", "Coding AI"] {
                let settings = PROJPAGESettingsModel(values: ["linkedServers": "Fixture server",
                    "taskSystem": "Connected task system", "agentsFolder": ".claude/agents",
                    "defaultCodingAI": "Claude Code", "defaultModel": "Opus"], invoke: { channel, _ in
                    transportAttempts += 1
                    XCTFail("Render attempted settings transport: \(channel)")
                    throw Self.failure("Fixture transport is forbidden")
                })
                try await Self.capture(PROJPAGEProjectSettings(project: project, model: settings, section: section)
                    .background(PROJPAGEStyle.page), dark: dark, size: .init(width: 680, height: 560),
                    to: output.appendingPathComponent("PROJPAGE-provisional-settings-\(section.lowercased().replacingOccurrences(of: " ", with: "-"))-\(suffix).png"))
            }
            
        }
        XCTAssertEqual(transportAttempts, 0)
        XCTAssertEqual(aiAttempts, 0)
        // All page sections have provisional fixtures. Final shared adapters and visual inspection remain.
        let notes = """
        Thirty-two provisional actual-view screenshots: every project tab, five settings sections, New session and Tasks project bar, light/dark.
        Detached NSHostingView only. No NSApplication.shared, NSWindow, hosting controller or app launch.
        Model tests call the real project/reminder handlers; screenshots do not prove physical input or window stability.
        Remaining: shared GLITCH adapters, actual project settings data/schema and mockup comparison. GitHub detail and physical input are not covered.
        Native materials/system menus need visual inspection. Final PROJPAGE render coverage is incomplete.
        """
        try notes.write(to: output.appendingPathComponent("PROJPAGE-provisional-test-render-notes.txt"),
            atomically: true, encoding: .utf8)
    }

    @MainActor private static var projects: [PROJProject] { [
        .init(id: "fixture-imatch", name: "iMatch", folders: ["/scratch/PROJPAGE/ClaudeiMatch"], colour: "blue"),
        .init(id: "fixture-crm", name: "CRM", folders: ["/scratch/PROJPAGE/ClaudeCRM"], colour: "purple"),
        .init(id: "independent", name: "Independent", colour: "graphite")
    ] }
    @MainActor private static var taskState: TasksState { .init(tasks: [
        .init(id: "imatch-task", project: projects[0].folders[0], projectID: "fixture-imatch"),
        .init(id: "crm-task", project: projects[0].folders[0], projectID: "fixture-crm"),
        .init(id: "independent-task", project: projects[0].folders[0], projectID: "independent")
    ]) }
    @MainActor private static func newSession(projects: [PROJProject]) -> NativeNewSessionModel {
        let model = NativeNewSessionModel(context: .init(projectPath: projects[0].folders[0]), effects: .init())
        model.configureRenderFixture(projects: projects,
            providers: NewSessionProviders.rows(detected: CodingAIJSON(["claude": true, "codex": true]), added: []))
        return model
    }
    @MainActor private static var report: ReadinessReport { .init(projectPath: projects[0].folders[0], score: 67,
        band: .fair, checks: [
            .init(id: "readme", status: .fail, detail: "Without it, an AI can't tell how to run and test the project.",
                fix: .init(id: "create-readme", label: "Fix it", touches: ["README.md"])),
            .init(id: "git-clean", status: .warn, detail: "302 files are not committed, so an AI's work mixes with yours."),
            .init(id: "agents", status: .pass, detail: "24 agents in .claude/agents"),
            .init(id: "test-script", status: .pass, detail: "swift test · 41 s"),
            .init(id: "claude-md", status: .pass, detail: "CLAUDE.md and AGENTS.md found"),
            .init(id: "secrets", status: .pass, detail: ".env files are ignored")
        ], scannedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120))) }
    @MainActor private static func overviewCards() throws -> [String: NativeRPCValue] {
        let id = projects[0].id
        let usage: [String: Any] = ["usage": ["input": 940000, "output": 300000], "requests": 38,
            "usageByModel": ["Opus": ["input": 940000, "output": 300000]],
            "bars": [0.30, 0.52, 0.24, 0.64, 0.40, 0.78, 0.58, 0.90, 0.44, 0.70, 0.36, 0.82]]
        let raw: [String: Any] = [
            "sessions": [["id": "fixture-commander", "projectId": id, "title": "Commander", "provider": "claude",
                "model": "Opus 5.5", "status": "Working", "createdAt": Self.fixtureNow.timeIntervalSince1970 * 1000 - 3600000, "lastLine": "Fixing the matchmaker tests that broke after the location tree change."],
                ["id": "fixture-session", "projectId": id, "title": "Session 1", "provider": "claude",
                 "model": "Opus 5.5", "status": "At a prompt", "createdAt": Self.fixtureNow.timeIntervalSince1970 * 1000 - 600000, "lastLine": "Finished: Panel table layouts now fill the width."]],
            "tasks": ["agents": (0..<24).map { ["id": "agent-\($0)", "name": "Agent \($0)", "projectId": id, "sourceDirectory": projects[0].folders[0] + "/.claude/agents", "icon": "sf:wrench.and.screwdriver", "colour": $0.isMultiple(of: 2) ? "blue" : "purple", "status": "active"] },
                "tasks": (0..<12).map { ["id": "task-\($0)", "projectId": id, "crmStatus": $0 < 3 ? "Stuck" : "To-Do", "process": $0 < 3 ? "running" : "idle", "assignee": "agent-\($0)"] }],
            "git": ["repo": true, "branch": ["name": "main", "ahead": 56], "staged": [] as [Any],
                "unstaged": (0..<19).map { ["path": "Sources/File\($0).swift", "kind": "modified"] },
                "untracked": (0..<302).map { ["path": "NewFile\($0).swift", "kind": "added"] },
                "lastCommit": ["subject": "Location tree: Bayut parents"]],
            "usage": ["periods": ["today": usage, "week": usage]],
            "servers": [["id": "fixture-server", "projectId": id, "name": "iMatch production"]],
            "receiver": ["sources": [["id": "fixture-source", "projectId": id, "name": "WhatsApp gateway"]]],
            "artifacts": ["artifacts": (0..<7).map { index -> [String: Any] in ["id": "fixture-artifact-\(index)", "firstAt": Self.fixtureNow.timeIntervalSince1970 * 1000 - Double(index < 5 ? 600000 : 172800000)] }]
        ]
        var values = try raw.mapValues { try NativeRPCValue.fromFoundation($0) }
        values["readiness"] = AIRReadinessWire.wire(report)
        return values
    }
    @MainActor private static func filesFixture(project: PROJProject) -> FilesScreenModel {
        var tree = FileTreeState()
        tree.loaded("", .init(entries: [
            .init(name: "Sources", relPath: "Sources", isDir: true),
            .init(name: "Tests", relPath: "Tests", isDir: true),
            .init(name: "README.md", relPath: "README.md", isDir: false),
            .init(name: "AGENTS.md", relPath: "AGENTS.md", isDir: false)]))
        tree.loaded("Sources", .init(relPath: "Sources", entries: [
            .init(name: "Project.swift", relPath: "Sources/Project.swift", isDir: false)]))
        tree.expand("Sources")
        let text = "# Fixture project\n\nRun `swift test` to check the project.\n\nUse Sources for app code and Tests for behavior checks.\n"
        return FilesScreenModel.renderFixture(root: project.folders[0], tree: tree, selected: "README.md",
            view: .ready(path: "README.md", read: .text(relPath: "README.md", text: text, bytes: text.utf8.count)))
    }
    @MainActor private static func gitFixture(project: PROJProject) -> GitScreenModel {
        let status = GitRepoStatus(cwd: project.folders[0], root: project.folders[0],
            branch: .init(name: "main", upstream: "origin/main", ahead: 3),
            staged: [.init(path: "Sources/Project.swift", group: .staged, code: "M ", kind: .modified)],
            unstaged: [.init(path: "README.md", group: .unstaged, kind: .modified),
                       .init(path: "Tests/ProjectTests.swift", group: .unstaged, kind: .modified)],
            untracked: [.init(path: "AGENTS.md", group: .untracked, code: "??", kind: .untracked)])
        return GitScreenModel.renderFixture(cwd: project.folders[0], status: .repo(status), chosen: "README.md",
            diff: .ready(path: "README.md", text: "diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1,2 +1,3 @@\n # Fixture project\n+Run swift test before saving.\n"), focusGroup: .unstaged)
    }
    @MainActor private static func githubFixture(project: PROJProject, area: NativeGHArea) -> NativeGHWorkspaceModel {
        let model = NativeGHWorkspaceModel(cwd: project.folders[0])
        model.area = area; model.repo = "fixture/project"; model.branch = "main"
        model.items = (1...5).map { number in
            let raw: [String: Any] = ["id": number, "number": number, "title": "Review project change \(number)",
                "display_title": "Swift checks \(number)", "state": "open", "status": "completed",
                "conclusion": "success", "repository": ["full_name": "fixture/project"],
                "user": ["login": "fixture-author"], "html_url": "https://example.invalid/project/\(number)"]
            return NativeGHItem(raw: CodingAIJSON(raw), area: area, fallbackRepo: "fixture/project")
        }
        return model
    }
    
    @MainActor private static func page<C: View>(project: PROJProject, selected: PROJPAGETab,
        @ViewBuilder content: @escaping () -> C) -> some View {
        PROJPAGEPage(title: project.name, subtitle: "~/ClaudeiMatch · main · 19 changed", project: project, scrolling: selected == .overview || selected == .readiness) {
            PROJPAGESwitch(selection: .constant(selected), items: PROJPAGETab.allCases)
        } actions: {
            Button {} label: { Image(systemName: "gearshape").frame(width: 28, height: 28) }
                .buttonStyle(.borderless).help("Project settings")
            Button {} label: { Label("New session", systemImage: "plus") }
                .buttonStyle(.borderedProminent).tint(Color.accentColor)
        } content: { content() }
    }
    @MainActor private static func capture<V: View>(_ view: V, dark: Bool, size: CGSize, to output: URL) async throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height))
        host.appearance = appearance
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw failure("No cached bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw failure("No PNG data") }
        XCTAssertEqual(host.bounds.size, size)
        try png.write(to: output, options: .atomic)
        print("PROJPAGE rendered \(output.lastPathComponent): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
    private static func failure(_ message: String) -> NSError {
        .init(domain: "PROJPAGERenderTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
