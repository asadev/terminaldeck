import AppKit
import SwiftUI
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Review of e425bca2e (MERGE AFTER FIXES): "Before it changes files" never starts weaker than the page showed; picking
/// an account keeps the agent; file names from "+" are never read as a command; the send arrow says the truth; a file
/// the chat cannot take is never dropped silently. Scratch defaults and recorded calls only (LandingNewSessionTests'
/// inert effects): no app, engine, session host or Keychain.
@MainActor
final class LandingStartsInHisModeTests: XCTestCase {
    typealias Engine = LandingNewSessionTests.Engine

    private func scratch() -> UserDefaults {
        let name = "td-landing-mode-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// The lists, with one agent per AI whose own settings say Bypass (as an agent saved with Bypass, or an AI whose
    /// saved default in Settings is Bypass, hands it to the launch).
    static func lists(agentMode: String? = nil, agentProvider: String = "claude") -> NativeRPCValue {
        var value = LandingNewSessionTests.lists()
        var agent = NativeRPCValue.object([.init("id", .string("own-1")), .init("name", .string("Decker")),
                                           .init("provider", .string(agentProvider)), .init("lead", .bool(false))])
        if let agentMode { agent = agent.setting("permissionMode", .string(agentMode)) }
        value = value.setting("agents", .array([agent]))
        return value
    }

    /// `host`: what the running session host says it can start (`NativeLandingHost`); true is the new host.
    private func page(_ engine: Engine, _ defaults: UserDefaults, lists: NativeRPCValue = lists(),
                      failing: Set<String> = [], host: @escaping @MainActor () -> Bool = { true }) -> NativeLandingModel {
        var effects = LandingNewSessionTests.effects(engine, defaults: defaults)
        effects.hostHonoursPick = host
        let inner = effects.invoke
        effects.invoke = { channel, args in
            if failing.contains(channel) {
                engine.calls.append((channel, args))
                throw NativeRPCError(code: "unavailable", message: "Not now.")
            }
            return try await inner(channel, args)
        }
        effects.choices = { _ in lists }
        let model = NativeLandingModel(effects: effects)
        model.apply(lists, detected: LandingNewSessionTests.detected, added: .null, pickLead: false)
        return model
    }

    private static func cli(_ mode: HootPermissionMode, _ provider: String) -> String {
        BackendHOOTSIMPermissionMode(rawValue: mode.rawValue)!.cliMode(provider: HootChatProvider(rawValue: provider)!)
    }

    // MARK: Blocker 1: the session starts IN the mode the page shows

    func testEveryAIStartsInThePagesModeInChatAndTerminal() async throws {
        for provider in ["claude", "codex", "gemini"] {
            for chat in [true, false] {
                for mode in HootPermissionMode.allCases {
                    let engine = Engine()
                    let model = page(engine, scratch())
                    model.chooseAgent(nil); model.chooseAI(provider); model.chooseChat(chat); model.choosePermission(mode)
                    XCTAssertEqual(model.shownPermission, mode)
                    model.text = "go"
                    await model.sendNow()
                    let label = "\(provider) chat=\(chat) \(mode)"
                    let input = try XCTUnwrap(engine.calls.first { $0.0 == "session:create" }?.1.first, label)
                    // Passed as his explicit pick, so neither the AI's saved default (Bypass) nor R73 replaces it.
                    XCTAssertEqual(input["permissionMode"].string, Self.cli(mode, provider), label)
                    XCTAssertEqual(input["chosenStartPermission"].string, Self.cli(mode, provider), label)
                    // The mode is never applied afterwards (a failed later call can no longer leave it on Bypass).
                    XCTAssertFalse(engine.calls.contains { $0.0 == "session:chat:options" && !$0.1.last!["permissionMode"].isNullish }, label)
                }
            }
        }
    }

    func testNoPickStartsInBypassAsTheLineSays() async throws {
        let engine = Engine()
        let model = page(engine, scratch())
        model.chooseAgent(nil); model.chooseAI("claude"); model.chooseChat(false)
        XCTAssertEqual(model.shownPermission, .bypass)
        model.text = "go"
        await model.sendNow()
        let input = try XCTUnwrap(engine.calls.first { $0.0 == "session:create" }?.1.first)
        XCTAssertEqual(input["permissionMode"].string, "bypassPermissions")
    }

    func testAnAgentWhoseOwnModeIsBypassStartsInHisPick() async throws {
        for (provider, own) in [("claude", "bypassPermissions"), ("codex", "danger-full-access"), ("gemini", "yolo")] {
            for chat in [true, false] {
                for mode in HootPermissionMode.allCases {
                    let engine = Engine()
                    let model = page(engine, scratch(), lists: Self.lists(agentMode: own, agentProvider: provider))
                    model.chooseAgent("own-1")
                    XCTAssertEqual(model.shownPermission, .bypass, "the agent's own mode shows until he picks")
                    model.chooseChat(chat); model.choosePermission(mode)
                    model.text = "go"
                    await model.sendNow()
                    let label = "\(provider) chat=\(chat) \(mode)"
                    let args = try XCTUnwrap(engine.calls.first { $0.0 == "session:start-agent" }?.1, label)
                    XCTAssertEqual(args.count, 7, label)
                    XCTAssertEqual(args[4].string, Self.cli(mode, provider), label)
                    XCTAssertEqual(args[6].bool, true, "his explicit pick: the agent's own Bypass never wins")
                }
            }
        }
    }

    func testAnAgentsOwnModeShowsOnTheLineAndIsWhatStarts() async throws {
        let engine = Engine(), defaults = scratch()
        let model = page(engine, defaults, lists: Self.lists(agentMode: "plan"))
        model.choosePermission(.ask)                       // his remembered pick, before the agent
        model.chooseAgent("own-1")
        XCTAssertEqual(model.shownPermission, .plan, "the agent's own setting, not Bypass and not his older pick")
        XCTAssertEqual(model.composerDraft.permissionMode, .plan)
        model.chooseChat(false); model.text = "go"
        await model.sendNow()
        let args = try XCTUnwrap(engine.calls.first { $0.0 == "session:start-agent" }?.1)
        XCTAssertEqual(args[4].string, "plan")
        // The agent's mode is never remembered as his: his own pick stays Ask.
        XCTAssertEqual(NativeLandingMemory.lastStart(defaults)?.permission, HootPermissionMode.ask.rawValue)
        // He can still change it while that agent is chosen.
        let again = page(Engine(), scratch(), lists: Self.lists(agentMode: "plan"))
        again.chooseAgent("own-1"); again.choosePermission(.changes)
        XCTAssertEqual(again.shownPermission, .changes)
    }

    func testAnAIWithNoModesShowsAndSendsNone() async throws {
        let engine = Engine()
        let model = page(engine, scratch())
        model.chooseAgent(nil); model.chooseAI("shell"); model.choosePermission(.ask)
        XCTAssertFalse(model.hasPermissionModes)
        XCTAssertNil(model.startPermission)
        model.text = "ls"
        await model.sendNow()
        let input = try XCTUnwrap(engine.calls.first { $0.0 == "session:create" }?.1.first)
        XCTAssertTrue(input["permissionMode"].isNullish)
        XCTAssertTrue(input["chosenStartPermission"].isNullish)
        // The remembered pick is still Ask (never turned into Bypass for another AI).
        model.chooseAI("claude")
        XCTAssertEqual(model.shownPermission, .ask)
    }

    func testAFailedOptionsCallSendsNothing() async {
        let engine = Engine()
        let model = page(engine, scratch(), failing: ["session:chat:options"])
        model.chooseAgent(nil); model.chooseAI("claude"); model.chooseChat(true); model.chooseModel("opus"); model.choosePermission(.ask)
        model.text = "Fix the login page"
        await model.sendNow()
        XCTAssertTrue(engine.calls.contains { $0.0 == "session:chat:options" })
        XCTAssertFalse(engine.calls.contains { $0.0 == "session:chat:say" }, "never sent without his model")
        let held = engine.calls.first { $0.0 == "session:chat:draft" }
        XCTAssertEqual(held?.1.last?.string, "Fix the login page", "held in that chat's own box")
    }

    // MARK: Point 7: gated on what the RUNNING session host can start

    /// An older host (the Mac mini's 0.21.3-host3) starts every new session in Bypass: the page shows Bypass as plain
    /// words, sends nothing explicit and keeps his stricter pick stored, not shown as active. Chat and Terminal, plain
    /// AI and agent.
    func testAnOlderHostShowsBypassDisplayOnlyAndSendsNoPick() async throws {
        for withAgent in [false, true] {
            for chat in [true, false] {
                let engine = Engine(), defaults = scratch()
                let model = page(engine, defaults, lists: Self.lists(agentMode: "plan"), host: { false })
                model.choosePermission(.ask)                 // his stored pick
                model.chooseAI("claude"); model.chooseChat(chat)
                model.chooseAgent(withAgent ? "own-1" : nil)
                let label = "agent=\(withAgent) chat=\(chat)"
                XCTAssertEqual(model.shownPermission, .bypass, label)
                XCTAssertEqual(model.composerDraft.permissionMode, .bypass, label)
                XCTAssertNotNil(model.permissionFixedHelp, "display-only: no menu, " + label)
                XCTAssertFalse(model.sendsChosenStart, label)
                model.text = "go"
                await model.sendNow()
                if withAgent {
                    let args = try XCTUnwrap(engine.calls.first { $0.0 == "session:start-agent" }?.1, label)
                    XCTAssertEqual(args[4].string, "bypassPermissions", "what R73 starts, " + label)
                    XCTAssertEqual(args[6].bool, false, "not his explicit pick, " + label)
                } else {
                    let input = try XCTUnwrap(engine.calls.first { $0.0 == "session:create" }?.1.first, label)
                    XCTAssertEqual(input["permissionMode"].string, "bypassPermissions", label)
                    XCTAssertTrue(input["chosenStartPermission"].isNullish, "nothing explicit sent, " + label)
                }
                XCTAssertFalse(engine.calls.contains { $0.0 == "session:chat:options" && !$0.1.last!["permissionMode"].isNullish }, label)
                // His stricter pick stays stored for later.
                XCTAssertEqual(NativeLandingMemory.lastStart(defaults)?.permission, HootPermissionMode.ask.rawValue, label)
            }
        }
    }

    /// 15 Nov review item 3: the switch is ON. A host that says it can start in the pick, and no host at all, offer it; an
    /// older host (no flag) or one not ready yet gives the display-only Bypass line and sends nothing explicit, Chat and
    /// Terminal, plain AI and agent: what shows is what starts.
    func testTheSwitchIsOnAndFollowsTheRunningHost() async throws {
        XCTAssertTrue(NativeLandingHost.pickOffered, "the pill is a real choice (15 Nov)")
        XCTAssertTrue(NativeLandingHost.honours(offered: true, helper: .hello(chosenStartPermission: 1)))
        XCTAssertTrue(NativeLandingHost.honours(offered: true, helper: .none))
        XCTAssertFalse(NativeLandingHost.honours(offered: true, helper: .hello(chosenStartPermission: nil)))
        XCTAssertFalse(NativeLandingHost.honours(offered: true, helper: .notReady))
        for helper in [NativeLandingHost.Helper.hello(chosenStartPermission: 1), .none] {
            XCTAssertFalse(NativeLandingHost.honours(offered: false, helper: helper), "the switch still gates it: \(helper)")
        }
        for helper in [NativeLandingHost.Helper.hello(chosenStartPermission: nil), .notReady] {
            for withAgent in [false, true] {
                for chat in [true, false] {
                    let engine = Engine(), defaults = scratch()
                    let model = page(engine, defaults, lists: Self.lists(agentMode: "plan"),
                                     host: { NativeLandingHost.honours(offered: NativeLandingHost.pickOffered, helper: helper) })
                    model.choosePermission(.ask)
                    model.chooseAI("claude"); model.chooseChat(chat)
                    model.chooseAgent(withAgent ? "own-1" : nil)
                    let label = "\(helper) agent=\(withAgent) chat=\(chat)"
                    XCTAssertEqual(model.shownPermission, .bypass, label)
                    XCTAssertNotNil(model.permissionFixedHelp, "plain words, no menu, " + label)
                    model.text = "go"
                    await model.sendNow()
                    if withAgent {
                        let args = try XCTUnwrap(engine.calls.first { $0.0 == "session:start-agent" }?.1, label)
                        XCTAssertEqual(args[4].string, "bypassPermissions", label)
                        XCTAssertEqual(args[6].bool, false, label)
                    } else {
                        let input = try XCTUnwrap(engine.calls.first { $0.0 == "session:create" }?.1.first, label)
                        XCTAssertEqual(input["permissionMode"].string, "bypassPermissions", label)
                        XCTAssertTrue(input["chosenStartPermission"].isNullish, label)
                    }
                }
            }
        }
    }

    func testANewHostShowsAndSendsThePick() async throws {
        let engine = Engine()
        let model = page(engine, scratch(), host: { true })
        model.chooseAgent(nil); model.chooseAI("claude"); model.chooseChat(true); model.choosePermission(.ask)
        XCTAssertEqual(model.shownPermission, .ask)
        XCTAssertNil(model.permissionFixedHelp, "a real choice")
        model.text = "go"
        await model.sendNow()
        let input = try XCTUnwrap(engine.calls.first { $0.0 == "session:create" }?.1.first)
        XCTAssertEqual(input["chosenStartPermission"].string, "default")
    }

    /// The host changes under the app (a reconnect to another helper): the page follows without an app restart, and a
    /// stricter mode it showed is never started as Bypass behind his back.
    func testThePageFollowsTheHostAcrossAReconnect() async throws {
        final class Host { var honours = false }
        let host = Host()
        let engine = Engine()
        let model = page(engine, scratch(), host: { host.honours })
        model.chooseAgent(nil); model.chooseAI("claude"); model.chooseChat(false); model.choosePermission(.plan)
        XCTAssertEqual(model.shownPermission, .bypass)
        host.honours = true; model.refreshHost()          // NativeLanding.hostChanged() after the reconnect
        XCTAssertEqual(model.shownPermission, .plan, "his stored pick is active once the host can start it")
        host.honours = false                           // the helper changes again just before he sends
        model.text = "go"
        await model.sendNow()
        XCTAssertFalse(engine.calls.contains { ["session:create", "session:start-agent"].contains($0.0) }, "nothing started weaker than shown")
        XCTAssertNotNil(model.problem)
        XCTAssertEqual(model.text, "go")
        XCTAssertEqual(model.shownPermission, .bypass, "the line now says what will start")
        await model.sendNow()
        let input = try XCTUnwrap(engine.calls.first { $0.0 == "session:create" }?.1.first)
        XCTAssertEqual(input["permissionMode"].string, "bypassPermissions")
        XCTAssertTrue(input["chosenStartPermission"].isNullish)
    }

    // MARK: Blocker 2: picking an account keeps the agent

    func testPickingAnotherAccountOfTheSameAIKeepsTheAgent() async throws {
        let engine = Engine()
        let model = page(engine, scratch())
        model.chooseAgent("own-1")
        model.pickAccount("c-home", of: "claude")
        XCTAssertEqual(model.chosenAgent?.id, "own-1")
        XCTAssertEqual(model.effectiveAccount, "c-home")
        model.chooseChat(false); model.text = "go"
        await model.sendNow()
        let args = try XCTUnwrap(engine.calls.first { $0.0 == "session:start-agent" }?.1)
        XCTAssertEqual(args[0].string, "own-1")
        XCTAssertEqual(args[5].string, "c-home", "the account picked here wins over the agent's own")
        // Another AI's account changes the AI, and so drops the agent.
        model.pickAccount("x-1", of: "codex")
        XCTAssertNil(model.chosenAgent)
        XCTAssertEqual(model.chosenProvider, "codex")
    }

    // MARK: Blocker 3: file names from "+" in Terminal

    func testFileNamesAreOneSingleQuotedArgumentEach() async throws {
        let names = ["a;b.txt", "x $(touch y).txt", "it's.txt", "q\"q.txt", "back`tick`.txt"]
        XCTAssertEqual(NativeLandingModel.shellQuoted("/w/a;b.txt"), "'/w/a;b.txt'")
        XCTAssertEqual(NativeLandingModel.shellQuoted("/w/x $(touch y).txt"), "'/w/x $(touch y).txt'")
        XCTAssertEqual(NativeLandingModel.shellQuoted("/w/it's.txt"), "'/w/it'\\''s.txt'")
        XCTAssertEqual(NativeLandingModel.shellQuoted("/w/q\"q.txt"), "'/w/q\"q.txt'")
        // A real shell reads each back as exactly one argument, unchanged, and runs nothing.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("td-landing-quote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        for name in names {
            let path = "/w/" + name
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.currentDirectoryURL = folder
            shell.arguments = ["-c", "set -- " + NativeLandingModel.shellQuoted(path) + "; printf '%s\\n' \"$#\" \"$1\""]
            let out = Pipe(); shell.standardOutput = out
            try shell.run(); shell.waitUntilExit()
            let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.suffix(2), ["1", path], name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("y").path), "$(touch y) never ran")
        // Through the page: the words, then each path as one quoted argument.
        let engine = Engine()
        let model = page(engine, scratch())
        model.chooseAgent(nil); model.chooseAI("shell"); model.chooseChat(false)
        model.attachments = names.map { HootComposerAttachment(url: URL(fileURLWithPath: "/w/" + $0)) }
        model.text = "cat"
        await model.sendNow()
        XCTAssertEqual(engine.typed.first?.2, "cat " + names.map { NativeLandingModel.shellQuoted("/w/" + $0) }.joined(separator: " "))
    }

    // MARK: The send decision is made at the press (integrator, a8f63dbaa)

    /// As LandingKeepsHisTypingTests' HisWindow: an off-screen window is never really key, and the box only takes
    /// typing and Return in a key window (HootComposer's input rule), so the check window says it is.
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }

    private func pageWindow(_ model: NativeLandingModel) async -> (NSWindow, NSView, NSTextView?) {
        let window = KeyWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 700, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        let focus = NativeLandingFocus()
        focus.personAsked()
        let host = NSHostingView(rootView: NativeLandingPage(model: model, focus: focus, fixture: true).frame(width: 700, height: 760))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 760)
        window.contentView = host
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); await Task.yield(); Self.spin(0.02) }
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.accessibilityIdentifier() == "landing.box" { return text }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        let box = find(host)
        if let box, window.firstResponder !== box { window.makeFirstResponder(box) }
        XCTAssertTrue(window.firstResponder === box, "the box has the keyboard before he types")
        return (window, host, box)
    }
    private static func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    private func press(_ characters: String, keyCode: UInt16 = 0, in window: NSWindow) {
        for character in characters {
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: String(character),
                                                charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: keyCode) {
                    window.sendEvent(event)
                }
            }
        }
    }

    /// He types and presses Return at once, before the page draws again: it sends, once. A file alone and Return:
    /// nothing is sent (the page's own rule, asked at the press, not at the last draw).
    func testReturnRightAfterTypingSendsOnceAndAFileAloneSendsNothing() async throws {
        let engine = Engine()
        let model = page(engine, scratch())
        model.chooseAgent(nil); model.chooseAI("claude"); model.chooseChat(false); model.text = ""
        let (window, _, box) = await pageWindow(model)
        defer { window.close() }
        XCTAssertNotNil(box)
        press("Fix it", in: window)
        press("\r", keyCode: 36, in: window) // no redraw in between
        for _ in 0..<200 where !engine.calls.contains(where: { $0.0 == "session:create" }) { await Task.yield(); Self.spin(0.01) }
        XCTAssertEqual(engine.calls.filter { $0.0 == "session:create" }.count, 1)

        let fileEngine = Engine()
        let fileOnly = page(fileEngine, scratch())
        fileOnly.chooseAgent(nil); fileOnly.chooseAI("claude"); fileOnly.chooseChat(false); fileOnly.text = ""
        fileOnly.attachments = [HootComposerAttachment(url: URL(fileURLWithPath: "/w/shot.png"))]
        let (second, _, _) = await pageWindow(fileOnly)
        defer { second.close() }
        press("\r", keyCode: 36, in: second)
        for _ in 0..<20 { await Task.yield(); Self.spin(0.01) }
        XCTAssertFalse(fileEngine.calls.contains { ["session:create", "session:start-agent"].contains($0.0) }, "a file alone sends nothing")
        XCTAssertEqual(fileOnly.attachments.count, 1, "and stays in the box")
    }

    // MARK: Small ones

    func testAFileAloneCannotSendAndTheArrowSaysSo() {
        let model = page(Engine(), scratch())
        model.attachments = [HootComposerAttachment(url: URL(fileURLWithPath: "/w/shot.png"))]
        model.text = ""
        XCTAssertTrue(model.composerDraft.canSend, "the box alone would light the arrow")
        XCTAssertFalse(model.canSend, "the page's own word keeps it inactive (HootComposer sendAllowed)")
    }

    func testAChatFileItCannotTakeStopsTheSendWithTheChatsOwnLine() async {
        let engine = Engine()
        let model = page(engine, scratch())
        model.chooseAgent(nil); model.chooseAI("claude"); model.chooseChat(true)
        let limits = try? XCTUnwrap(model.attachmentLimits)
        model.attachments = [HootComposerAttachment(url: URL(fileURLWithPath: "/w/notes.txt"))]
        model.text = "look at this"
        await model.sendNow()
        XCTAssertFalse(engine.calls.contains { ["session:create", "session:start-agent", "session:chat:say"].contains($0.0) }, "nothing made, nothing sent")
        XCTAssertEqual(model.problem, limits?.note, "the open chat's own words for a file it cannot take")
        XCTAssertEqual(model.text, "look at this")
        XCTAssertEqual(model.attachments.count, 1)
    }
}
