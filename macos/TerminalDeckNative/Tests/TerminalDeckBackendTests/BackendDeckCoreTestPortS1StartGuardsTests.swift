import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// start-guards.test.ts: what `sessions.start` refuses (its prechecks, which
/// run ahead of the budget and any dialog), and starting with a brief, which
/// reaches disk before a process reaches the machine. Real catalogue tool,
/// real brief writer on a scratch folder, real delivery loop on a fake clock.
final class BackendDeckCoreTestPortS1StartGuardsTests: BackendDeckCoreTestPortSecurityCase {
    private typealias F = BackendDeckCoreTestPortS1StartFixture
    private typealias Surface = BackendDeckCoreTestPortS1StartSurface
    private typealias Builtins = BackendDeckCoreCatalogueBuiltins

    private struct StartRig {
        let surface: Surface
        let copilot: String
        let context: BackendDeckCoreSecurityCallContext
        let start: BackendDeckCoreSecurityToolPolicy
        var specs: String { BackendDeckCoreBrief.specsDirectory(copilotRoot: URL(fileURLWithPath: copilot)).path }
    }
    /// start-guards.test.ts `rig()` (named apart from the base case's `rig`): state is `<scratch>/state` (not created),
    /// the copilot's home is `<state>/copilot`, and it is an open folder too.
    private func startRig(projects: [String]? = nil, sessions: [V] = [], owned: [String] = []) throws -> StartRig {
        let state = try scratch().appendingPathComponent("state", isDirectory: true)
        let copilot = state.appendingPathComponent("copilot", isDirectory: true).path
        let surface = Surface(sessions: sessions, projects: projects ?? ["/work/api", "/work/web", copilot],
                              stateRoot: state.path, homeRoot: copilot, naming: .copilot)
        let context = F.context(callID: "row-1", now: F.guardsNow, owned: .init(Set(owned)))
        return StartRig(surface: surface, copilot: copilot, context: context, start: try F.start(surface))
    }
    private func live(_ id: String, _ cwd: String, exitCode: Double? = nil) -> V {
        Surface.session(id, cwd: cwd, title: cwd, exitCode: exitCode)
    }
    private var brief: String {
        "Base branch is main. Fix auth.test.ts, which is flaky because of the clock. Done means it passes ten runs in a row. Do not touch the fixtures."
    }

    // MARK: what sessions.start refuses

    // TSCASE start-guards.test.ts:149
    func testStartGuardsL149NeverStartsInsideAppOwnStorage() throws {
        let built = try startRig(), precheck = try XCTUnwrap(built.start.precheck)
        XCTAssertThrowsError(try precheck(o([("cwd", .string(built.copilot))]), built.context)) { error in
            let refused = error as? BackendDeckCoreSecurityRefusal
            XCTAssertNotNil(refused, "\(error)")
            XCTAssertEqual(refused?.reason.rawValue, "not-permitted")
            XCTAssertTrue(refused?.message.contains("own storage") == true, refused?.message ?? "")
        }
    }
    // TSCASE start-guards.test.ts:160
    func testStartGuardsL160SecondCopilotSessionInSameTreeRefused() throws {
        let built = try startRig(sessions: [live("mine-1", "/work/api")], owned: ["mine-1"]), precheck = try XCTUnwrap(built.start.precheck)
        assertError({ try precheck(self.o([("cwd", .string("/work/api"))]), built.context) }, contains: "one working tree")
        // A different folder is fine: the rule is about the tree, not about a count.
        XCTAssertNoThrow(try precheck(o([("cwd", .string("/work/web"))]), built.context))
    }
    // TSCASE start-guards.test.ts:175
    func testStartGuardsL175PersonOwnSessionInFolderIsNotVetoed() throws {
        let built = try startRig(sessions: [live("theirs", "/work/api")]), precheck = try XCTUnwrap(built.start.precheck)
        XCTAssertNoThrow(try precheck(o([("cwd", .string("/work/api"))]), built.context))
    }
    // TSCASE start-guards.test.ts:180
    func testStartGuardsL180CapsHowManyRunAtOnce() throws {
        let many = (0..<Builtins.maxCopilotSessions).map { live("c\($0)", "/work/\($0)") }
        let built = try startRig(projects: ["/work/api"] + many.map { $0["cwd"].string ?? "" }, sessions: many, owned: many.map { $0["id"].string ?? "" })
        let precheck = try XCTUnwrap(built.start.precheck)
        assertError({ try precheck(self.o([("cwd", .string("/work/api"))]), built.context) }, contains: "is the limit")
    }
    // TSCASE start-guards.test.ts:192
    func testStartGuardsL192ExitedSessionsDoNotCountTowardsCap() throws {
        let dead = (0..<Builtins.maxCopilotSessions).map { live("c\($0)", "/work/\($0)", exitCode: 0) }
        let built = try startRig(projects: ["/work/api"] + dead.map { $0["cwd"].string ?? "" }, sessions: dead, owned: dead.map { $0["id"].string ?? "" })
        let precheck = try XCTUnwrap(built.start.precheck)
        XCTAssertNoThrow(try precheck(o([("cwd", .string("/work/api"))]), built.context))
    }
    // TSCASE start-guards.test.ts:205
    func testStartGuardsL205BriefTooShortAndTooLongRefused() throws {
        let built = try startRig(), precheck = try XCTUnwrap(built.start.precheck)
        assertError({ try precheck(self.o([("cwd", .string("/work/api")), ("brief", .string("fix it")), ("title", .string("fix"))]), built.context) },
                    contains: "at least \(BackendDeckCoreBrief.minBriefChars) characters")
        let long = String(repeating: "x", count: BackendDeckCoreBrief.maxBriefChars + 1)
        assertError({ try precheck(self.o([("cwd", .string("/work/api")), ("brief", .string(long)), ("title", .string("fix"))]), built.context) },
                    contains: "Scope the work")
    }
    // TSCASE start-guards.test.ts:218
    func testStartGuardsL218BriefMustBeNamedForItsFilename() throws {
        let built = try startRig(), precheck = try XCTUnwrap(built.start.precheck)
        let named = String(repeating: "x", count: BackendDeckCoreBrief.minBriefChars + 1)
        assertError({ try precheck(self.o([("cwd", .string("/work/api")), ("brief", .string(named))]), built.context) }, contains: "needs a `title`")
    }

    // MARK: starting with a brief

    // TSCASE start-guards.test.ts:231
    func testStartGuardsL231WritesSpecThenPointsSessionAtIt() async throws {
        let built = try startRig()
        let output = try await built.start.run(o([("cwd", .string("/work/api")), ("brief", .string(brief)), ("title", .string("Fix the flaky auth test"))]), built.context)
        let spec = output.value["spec"]
        XCTAssertEqual(spec["delivered"], .bool(true))
        let path = try XCTUnwrap(spec["path"].string)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: built.specs).count, 1)
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).contains("Do not touch the fixtures."))
        // One line naming the file, then the return as its own write.
        XCTAssertEqual(built.surface.typed.count, 2)
        XCTAssertTrue(built.surface.typed.first?.contains(path) == true, built.surface.typed.first ?? "")
        XCTAssertEqual(built.surface.typed.last, "\r")
    }
    // TSCASE start-guards.test.ts:264
    func testStartGuardsL264KeepsSpecAndSaysWhatToDoWhenUndelivered() async throws {
        let built = try startRig()
        // The CLI died on startup: no screen, and the session is gone by the next look.
        built.surface.screen = nil
        built.surface.exitOnLook = true
        let output = try await built.start.run(o([("cwd", .string("/work/api")), ("brief", .string(brief)), ("title", .string("Fix the flaky auth test"))]), built.context)
        let spec = output.value["spec"]
        XCTAssertEqual(spec["delivered"], .bool(false))
        XCTAssertTrue(built.surface.typed.isEmpty)
        let path = try XCTUnwrap(spec["path"].string)
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).contains("Base branch is main."))
        XCTAssertTrue(spec["nextStep"].string?.contains("sessions.send") == true, spec["nextStep"].compact)
    }
    // TSCASE start-guards.test.ts:302
    func testStartGuardsL302RefusesWithoutStartingWhenBriefCannotBeWritten() async throws {
        let built = try startRig()
        // A regular file where the specs directory must go: a real filesystem refusal.
        try FileManager.default.createDirectory(atPath: built.copilot, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: URL(fileURLWithPath: built.specs))
        let args = o([("cwd", .string("/work/api")), ("brief", .string(brief)), ("title", .string("Fix the flaky auth test"))]), context = built.context
        await assertAsyncError({ _ = try await built.start.run(args, context) })
        // No session, no spend, nothing typed at anything.
        XCTAssertTrue(built.surface.started.isEmpty)
        XCTAssertTrue(built.surface.sessions.isEmpty)
        XCTAssertTrue(built.surface.typed.isEmpty)
    }
    // TSCASE start-guards.test.ts:319
    func testStartGuardsL319StartsWithoutBriefWhenNothingToScope() async throws {
        let built = try startRig()
        let output = try await built.start.run(o([("cwd", .string("/work/api")), ("provider", .string("shell"))]), built.context)
        XCTAssertEqual(output.value["spec"], .null)
        XCTAssertTrue(built.surface.typed.isEmpty)
    }
}
