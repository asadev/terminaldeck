import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class INT2SessionStartBriefTests: XCTestCase {
    private let brief = "Work only in this repository on the auth regression. Use main as the base. Done means the relevant tests pass. Do not touch account files or deploy anything."

    private func surface() throws -> BackendDeckCoreTestPortS1StartSurface {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("INT2-first-brief-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return .init(sessions: [], projects: ["/work/api"], stateRoot: root.path,
                     homeRoot: root.appendingPathComponent("hoot").path, naming: .copilot)
    }

    func testSessionsStartWaitsPastStartupThenCommitsTheBriefAsFirstUserMessage() async throws {
        let surface = try surface()
        // Commander saw an empty prompt at startup. Keep that deceptive frame
        // visible for longer than the old20s ceiling, but with no ready signal.
        surface.screen = "❯ "
        surface.readyAtMilliseconds = 25_000
        let tool = try BackendDeckCoreTestPortS1StartFixture.start(surface)
        let context = BackendDeckCoreTestPortS1StartFixture.context(callID: "INT2-start", now: 1_000, owned: .init(Set<String>()))
        let args = NativeRPCValue.object([.init("cwd", .string("/work/api")), .init("provider", .string("claude")),
                                         .init("brief", .string(brief)), .init("title", .string("Scoped auth fix"))])
        let output = try await tool.run(args, context)
        let spec = output.value["spec"]
        XCTAssertEqual(spec["delivered"], .bool(true))
        XCTAssertGreaterThanOrEqual(spec["waitedMs"].number ?? 0, 25_000)
        XCTAssertEqual(surface.writesBeforeReady, 0)
        let path = try XCTUnwrap(spec["path"].string)
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).contains(brief))
        XCTAssertEqual(surface.committedMessages, [BackendDeckCoreBrief.deliveryLine(path)])
        XCTAssertEqual(surface.typed, [BackendDeckCoreBrief.deliveryLine(path), "\r"])
        XCTAssertEqual(surface.started.count, 1)
    }

    /// 17 Oct: a chat started through the tool door got its brief typed into the composer and never sent, while the
    /// reply said delivered. The brief is sent as the chat's first message, as the window's Return would.
    func testToolDoorChatStartSendsTheBriefAsItsFirstMessage() async throws {
        let surface = try surface()
        surface.startsChats = true
        surface.screen = nil
        let tool = try BackendDeckCoreTestPortS1StartFixture.start(surface)
        let context = BackendDeckCoreTestPortS1StartFixture.context(callID: "door-chat", now: 1_000, owned: .init(Set<String>()))
        let args = NativeRPCValue.object([.init("cwd", .string("/work/api")), .init("provider", .string("claude")), .init("mode", .string("chat")),
                                         .init("brief", .string(brief)), .init("title", .string("Scoped auth fix"))])
        let output = try await tool.run(args, context)
        let spec = output.value["spec"], path = try XCTUnwrap(spec["path"].string)
        XCTAssertEqual(surface.started.first?["chat"], .bool(true))
        XCTAssertEqual(spec["delivered"], .bool(true))
        XCTAssertEqual(surface.typed, [BackendDeckCoreBrief.deliveryLine(path), "\r"])
        XCTAssertEqual(surface.committedMessages, [BackendDeckCoreBrief.deliveryLine(path)])
    }

    /// U110 #110: the session is running even when typing its brief fails, so its handle comes back with the reason
    /// instead of an error that would make the caller start a second session.
    func testABriefThatCannotBeTypedStillReturnsTheRunningSession() async throws {
        let surface = try surface()
        surface.submitFailure = NativeRPCError(code: "unavailable", message: "The session helper dropped the line.")
        let tool = try BackendDeckCoreTestPortS1StartFixture.start(surface)
        let context = BackendDeckCoreTestPortS1StartFixture.context(callID: "INT2-glitch", now: 1_000, owned: .init(Set<String>()))
        let args = NativeRPCValue.object([.init("cwd", .string("/work/api")), .init("provider", .string("claude")),
                                         .init("brief", .string(brief)), .init("title", .string("Scoped auth fix"))])
        let output = try await tool.run(args, context)
        XCTAssertFalse(output.value["session"].isNullish)
        XCTAssertEqual(output.value["spec"]["delivered"], .bool(false))
        XCTAssertEqual(output.value["spec"]["sent"], .bool(false))
        XCTAssertTrue(output.value["spec"]["nextStep"].string?.contains("dropped the line") == true, "\(output.value["spec"])")
        XCTAssertEqual(surface.started.count, 1)
    }

    func testAChatThatCannotTakeItsBriefSaysWhyAndIsNeverCalledDelivered() async throws {
        let surface = try surface()
        surface.sessions = [.object([.init("id", .string("new")), .init("chat", .bool(true)), .init("exitCode", .null)])]
        surface.submitFailure = NativeRPCError(code: "unavailable", message: "claude could not be found on the login shell's PATH.")
        let result = try await BackendDeckCoreBrief.deliver(surface: surface, sessionID: "new", line: "Read the saved scoped brief.", clock: surface.clock)
        XCTAssertEqual(result["delivered"], .bool(false))
        XCTAssertEqual(result["sent"], .bool(false))
        XCTAssertTrue(result["reason"].string?.contains("could not be found") == true)
        XCTAssertTrue(surface.committedMessages.isEmpty)
    }

    func testNoReadySignalNeverTypesIntoAPromptLookingStartupFrame() async throws {
        let surface = try surface()
        surface.sessions = [.object([.init("id", .string("new")), .init("exitCode", .null)])]
        surface.readyAtMilliseconds = .infinity
        let result = try await BackendDeckCoreBrief.deliver(surface: surface, sessionID: "new", line: "Read the saved scoped brief before starting any work.",
                                                          timeoutMs: 2_000, clock: surface.clock)
        XCTAssertEqual(result["delivered"], .bool(false))
        XCTAssertTrue(surface.typed.isEmpty)
        XCTAssertTrue(result["reason"].string?.contains("has not signalled") == true)
    }

    func testAReadySignalDoesNotAnswerAStartupChoice() async throws {
        let surface = try surface()
        surface.sessions = [.object([.init("id", .string("new")), .init("exitCode", .null)])]
        surface.screen = "Welcome to Claude Code\n❯ 1. Choose a login method"
        let result = try await BackendDeckCoreBrief.deliver(surface: surface, sessionID: "new", line: "Read the saved scoped brief before starting any work.",
                                                          timeoutMs: 2_000, clock: surface.clock)
        XCTAssertEqual(result["delivered"], .bool(false))
        XCTAssertTrue(surface.typed.isEmpty)
        XCTAssertTrue(result["reason"].string?.contains("choice") == true)
    }

    /// 11 Oct rule: one echoed character is not "seen". The whole line is typed once more and then sent
    /// (never a cut-off message: the clear key goes first), and the answer says sent, not delivered.
    func testOneCharacterEchoIsNeverCalledDeliveredAndTheWholeMessageIsSentOnce() async throws {
        let surface = try surface()
        surface.sessions = [.object([.init("id", .string("new")), .init("exitCode", .null)])]
        surface.echoCharacters = 1
        let line = "Read the saved scoped brief before starting any work."
        let result = try await BackendDeckCoreBrief.deliver(surface: surface, sessionID: "new", line: line, clock: surface.clock)
        XCTAssertEqual(result["delivered"], .bool(false))
        XCTAssertEqual(result["sent"], .bool(true))
        XCTAssertEqual(surface.typed, [line, "\u{15}", line, "\r"])
        XCTAssertEqual(surface.committedMessages, [line])
    }

    func testProductionSurfaceRequiresTheAcceptedSessionReadySignal() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("INT2-live-ready-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rig = try await BackendDeckCoreTestPortS1LiveSurfaceRig.make(root: folder)
        addTeardownBlock { await rig.state.stop() }
        let signal = BackendDeckCoreSecurityTestBox<NativeRPCValue>(.null)
        let live = try BackendDeckCoreTestPortS1LiveSurfaceRig.surface(state: rig.state, scope: rig.scope, record: rig.record,
                                                                    acceptedStatus: { _ in signal.get() })
        let starting = try await live.sessionIsReady(id: "new", screen: "❯ ")
        XCTAssertFalse(starting, "A decorative startup prompt is not a CLI-ready signal")
        signal.edit { $0 = .object([.init("status", .string("waiting"))]) }
        let ready = try await live.sessionIsReady(id: "new", screen: "❯ ")
        XCTAssertTrue(ready)
        let choice = try await live.sessionIsReady(id: "new", screen: "❯ 1. Select a login method")
        XCTAssertFalse(choice)
        signal.edit { $0 = .object([.init("status", .string("working"))]) }
        let working = try await live.sessionIsReady(id: "new", screen: "❯ ")
        XCTAssertFalse(working)
    }

    func testSameMinuteAndTitleCannotReplaceAWaitingSessionsBrief() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("INT2-immutable-brief-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = NativeRPCValue.object([.init("title", .string("Auth fix")), .init("brief", .string(brief)), .init("at", .number(1_000))])
        let second = first.setting("brief", .string("A different caller's scoped brief that must never replace the first one."))
        let a = try BackendDeckCoreBrief.writeSpec(directory: root, input: first, ownership: .exclusive)
        let b = try BackendDeckCoreBrief.writeSpec(directory: root, input: second, ownership: .exclusive)
        let aPath = try XCTUnwrap(a["path"].string), bPath = try XCTUnwrap(b["path"].string)
        XCTAssertNotEqual(aPath, bPath)
        XCTAssertTrue(try String(contentsOfFile: aPath, encoding: .utf8).contains(brief))
        XCTAssertFalse(try String(contentsOfFile: aPath, encoding: .utf8).contains("different caller"))
        XCTAssertTrue(try String(contentsOfFile: bPath, encoding: .utf8).contains("different caller"))
    }
}
