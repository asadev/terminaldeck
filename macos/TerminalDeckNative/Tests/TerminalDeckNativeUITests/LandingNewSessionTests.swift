import AppKit
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Owner, 14 Nov 05:25 / 05:27: the app opens on a New session page; the page is NOT a session. Opening it, changing
/// its choices or leaving it makes nothing; his first message makes exactly one session, with the choices as they stand.
/// Scratch defaults and recorded calls only: no app, engine, session host or Keychain.
@MainActor
final class LandingNewSessionTests: XCTestCase {
    final class Engine {
        var calls: [(String, [NativeRPCValue])] = []
        var added: [[String: Any]] = []
        var shown: [String] = []
        var onScreen = true
        var typed: [(String, String, String)] = []
        var made: [String] { calls.map(\.0).filter { ["session:create", "session:start-agent", "session:chat:say", "session:chat:options", "projects:add", "prefs:set"].contains($0) } }
    }
    static let work = PROJProject(id: "imatch", name: "iMatch", folders: ["/work/imatch"])
    static let site = PROJProject(id: "site", name: "Website", folders: ["/work/site"])
    static let ownFolder = "/scratch/Terminal Deck/Independent"

    private func scratch() -> UserDefaults {
        let name = "td-landing-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    static func lists() -> NativeRPCValue {
        func ai(_ id: String, _ name: String, chat: Bool, models: [(String, String)], efforts: [String], account: String?) -> NativeRPCValue {
            var row = NativeRPCValue.object([.init("id", .string(id)), .init("name", .string(name)), .init("chat", .bool(chat)),
                .init("models", .array(models.map { .object([.init("id", .string($0.0)), .init("name", .string($0.1))]) })),
                .init("efforts", .array(efforts.map(NativeRPCValue.string)))])
            if let account { row = row.setting("defaultAccount", .string(account)) }
            return row
        }
        return .object([
            .init("providers", .array([ai("claude", "Claude", chat: true, models: [("opus", "Opus"), ("sonnet", "Sonnet")], efforts: ["low", "high", "xhigh"], account: "c-work"),
                                       ai("codex", "Codex", chat: true, models: [("gpt-5", "GPT-5")], efforts: ["low", "medium", "high"], account: "x-1"),
                                       ai("gemini", "Gemini", chat: true, models: [], efforts: [], account: nil),
                                       ai("shell", "Shell", chat: false, models: [], efforts: [], account: nil)])),
            .init("accounts", .array([
                .object([.init("id", .string("c-work")), .init("name", .string("Work")), .init("provider", .string("claude"))]),
                .object([.init("id", .string("c-home")), .init("name", .string("Home")), .init("provider", .string("claude"))]),
                .object([.init("id", .string("x-1")), .init("name", .string("Codex login")), .init("provider", .string("codex"))])])),
            .init("agents", .array([.object([.init("id", .string("lead-1")), .init("name", .string("Builder")), .init("provider", .string("claude")), .init("lead", .bool(true))])])),
            .init("defaultProvider", .string("claude")), .init("openAs", .string("chat"))])
    }
    static let detected = NativeRPCValue.object([
        .init("claude", .object([.init("available", .bool(true))])), .init("codex", .object([.init("available", .bool(true))])),
        .init("gemini", .object([.init("available", .bool(true))]))])

    /// Inert effects: recorded calls, folders under /work exist, the app's own folder is a fixed scratch path.
    static func effects(_ engine: Engine, defaults: UserDefaults, ready: @escaping @MainActor () -> Bool = { true },
                        exists: @escaping @MainActor (String) -> Bool = { $0.hasPrefix("/work/") }) -> NativeLandingModel.Effects {
        var effects = NativeLandingModel.Effects()
        effects.invoke = { channel, args in
            engine.calls.append((channel, args))
            switch channel {
            case "providers:detect": return Self.detected
            case "session:create", "session:start-agent":
                return .object([.init("id", .string("33333333-3333-4333-8333-333333333333")), .init("title", .string("New"))])
            default: return .bool(true)
            }
        }
        effects.ready = ready
        effects.choices = { _ in Self.lists() }
        effects.defaults = defaults
        effects.projects = { [Self.work, Self.site, PROJProjects.independent] }
        effects.addQuietly = { engine.added.append($0) }
        effects.onScreen = { engine.onScreen }
        effects.show = { engine.shown.append($0) }
        effects.typeWhenReady = { engine.typed.append(($0, $1, $2)) }
        effects.exists = exists
        effects.defaultFolder = { Self.ownFolder }
        effects.pause = { await Task.yield() }
        return effects
    }
    private func model(_ engine: Engine, defaults: UserDefaults, ready: Bool = true) -> NativeLandingModel {
        NativeLandingModel(effects: Self.effects(engine, defaults: defaults, ready: { ready }))
    }
    private func cwd(_ engine: Engine) -> String? {
        guard let call = engine.calls.first(where: { ["session:create", "session:start-agent"].contains($0.0) }) else { return nil }
        return call.0 == "session:create" ? call.1.first?["cwd"].string : call.1[2].string
    }

    // MARK: Nothing is made until he sends

    func testShowingChangingAndLeavingThePageMakesNothing() async {
        let engine = Engine(), defaults = scratch()
        let page = model(engine, defaults: defaults)
        page.apply(Self.lists(), detected: Self.detected, added: .null, pickLead: false)
        page.chooseProject(Self.site)
        page.chooseAI("codex"); page.chooseModel("gpt-5"); page.chooseEffort("high"); page.chooseChat(false)
        page.chooseAccount("x-1"); page.text = "half a thought"
        // He leaves the page (another session in the side panel). Only the lists were read; nothing was made.
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(engine.made.isEmpty, "\(engine.calls.map(\.0))")
        XCTAssertTrue(Set(engine.calls.map(\.0)).isSubset(of: ["providers:detect", "agents:list", "projects:list"]), "\(engine.calls.map(\.0))")
        XCTAssertTrue(engine.added.isEmpty && engine.shown.isEmpty, "no session, so no side-panel row")
        XCTAssertNil(NativeLandingMemory.lastStart(defaults), "a choice is not a start")
        // His unsent text stays on this Mac, for when he comes back.
        XCTAssertEqual(NativeLandingMemory.draft(defaults), "half a thought")
        XCTAssertEqual(model(engine, defaults: defaults).text, "half a thought")
    }

    func testAnEmptyBoxCannotSend() async {
        let engine = Engine()
        let page = model(engine, defaults: scratch())
        page.text = "   \n"
        XCTAssertFalse(page.canSend)
        await page.sendNow()
        XCTAssertTrue(engine.calls.isEmpty)
    }

    func testFirstMessageMakesExactlyOneSessionWithTheChoices() async throws {
        let engine = Engine(), defaults = scratch()
        let page = model(engine, defaults: defaults)
        page.apply(Self.lists(), detected: Self.detected, added: .null, pickLead: false)
        page.chooseProject(Self.work)
        page.chooseAgent(nil)
        page.chooseAI("claude"); page.chooseAccount("c-home"); page.chooseModel("opus"); page.chooseEffort("xhigh"); page.chooseChat(true)
        page.text = "Fix the login page"
        await page.sendNow()
        let creates = engine.calls.filter { $0.0 == "session:create" }
        XCTAssertEqual(creates.count, 1)
        let input = try XCTUnwrap(creates.first?.1.first)
        XCTAssertEqual(input["cwd"].string, "/work/imatch")
        XCTAssertEqual(input["projectId"].string, "imatch")
        XCTAssertEqual(input["provider"].string, "claude")
        XCTAssertEqual(input["profileId"].string, "c-home")
        XCTAssertEqual(input["model"].string, "opus")
        XCTAssertEqual(input["effort"].string, "xhigh")
        XCTAssertEqual(input["chat"].bool, true)
        let says = engine.calls.filter { $0.0 == "session:chat:say" }
        XCTAssertEqual(says.count, 1)
        XCTAssertEqual(says.first?.1.last?.string, "Fix the login page")
        XCTAssertEqual(engine.calls.filter { $0.0 == "session:chat:options" }.first?.1.last?["model"].string, "claude:opus")
        XCTAssertEqual(engine.added.count, 1, "the session is in the side panel")
        XCTAssertEqual(engine.shown, ["33333333-3333-4333-8333-333333333333"], "he is still on the page: the window shows it")
        XCTAssertEqual(page.text, "")
        XCTAssertEqual(NativeLandingMemory.draft(defaults), "")
        // Next launch opens on exactly these choices.
        let next = try XCTUnwrap(NativeLandingMemory.lastStart(defaults))
        XCTAssertEqual(next.folder, "/work/imatch"); XCTAssertEqual(next.projectName, "iMatch"); XCTAssertEqual(next.provider, "claude")
        XCTAssertEqual(next.account, "c-home"); XCTAssertEqual(next.model, "opus"); XCTAssertEqual(next.effort, "xhigh"); XCTAssertTrue(next.chat)
        let relaunched = model(Engine(), defaults: defaults)
        XCTAssertEqual(relaunched.projectName, "iMatch"); XCTAssertEqual(relaunched.aiName, "Claude")
        XCTAssertEqual(relaunched.modelName, "Opus"); XCTAssertEqual(relaunched.effortName, "Extra"); XCTAssertEqual(relaunched.accountName, "Home")
    }

    func testAProjectsLeadAndATerminalStart() async throws {
        let engine = Engine(), defaults = scratch()
        let page = model(engine, defaults: defaults)
        page.apply(Self.lists(), detected: Self.detected, added: .null, pickLead: true)
        XCTAssertEqual(page.chosenAgent?.name, "Builder", "picking a project picks its lead, as the form did")
        page.chooseChat(false)
        page.text = "run the tests"
        await page.sendNow()
        XCTAssertEqual(engine.calls.filter { $0.0 == "session:start-agent" }.count, 1)
        XCTAssertEqual(engine.calls.filter { $0.0 == "session:chat:say" }.count, 0, "a terminal gets it typed at the AI's prompt")
        XCTAssertEqual(engine.typed.first?.1, "claude")
        XCTAssertEqual(engine.typed.first?.2, "run the tests")
    }

    // MARK: Review LANDING-2

    /// Blocker 1: status empty, then idle on a blank screen, then a shell prompt, then the AI's own prompt: typed once,
    /// only at the AI's prompt, never at the blank start, a shell prompt or a folder-trust question.
    func testTerminalFirstMessageIsTypedOnlyAtTheAIsPrompt() async {
        let claude = "╭───────────────────────────╮\n│ ✻ Welcome to Claude Code! │\n╰───────────────────────────╯\n\n❯ \n? for shortcuts"
        let trust = "Do you trust the files in this folder?\n❯ 1. Yes, proceed\n  2. No, exit"
        let states: [(TerminalStatus?, String)] = [(nil, ""), (.idle, ""), (.waiting, "someone@mac ~ %"), (.waiting, "someone@mac:~$ "),
                                                   (.input, trust), (.waiting, trust), (.waiting, claude)]
        var step = 0, typedAt: Int?, submittedAt: Int?
        let typed = await NativeLandingTerminal.deliver(provider: "claude", text: "run the tests",
            read: { (states[min(step, states.count - 1)].0, states[min(step, states.count - 1)].1) },
            type: { _ in typedAt = step }, submit: { submittedAt = step }, pause: { step += 1 }, attempts: 20)
        XCTAssertTrue(typed)
        XCTAssertEqual(typedAt, states.count - 1, "typed only once the AI's own prompt was on screen")
        XCTAssertNotNil(submittedAt)
        for (status, screen) in states.dropLast() {
            XCTAssertEqual(NativeLandingTerminal.step(provider: "claude", status: status, screen: screen), .wait, screen)
        }
        XCTAssertEqual(NativeLandingTerminal.step(provider: "shell", status: .waiting, screen: "someone@mac ~ %"), .type, "a plain Shell types at its own prompt")
        // Never ready: never typed, and the text comes back into the box after what he typed since.
        var never = 0
        let gaveUp = await NativeLandingTerminal.deliver(provider: "claude", text: "x", read: { (.waiting, "someone@mac:~$ ") },
            type: { _ in never += 1 }, submit: { never += 1 }, pause: {}, attempts: 5)
        XCTAssertFalse(gaveUp); XCTAssertEqual(never, 0)
        let page = model(Engine(), defaults: scratch())
        page.text = "a new idea"
        page.giveBack("run the tests")
        XCTAssertEqual(page.text, "a new idea\n\nrun the tests", "added to his text, never replacing it")
        XCTAssertNotNil(page.problem)
    }

    /// Blocker 2 (model side; the window side is LandingKeepsHisTypingTests): he left the page while it was sending.
    func testASendFinishingAfterHeLeftThePageDoesNotMoveHimAndKeepsHisNewText() async {
        let engine = Engine(), defaults = scratch()
        var effects = Self.effects(engine, defaults: defaults)
        let gate = LandingGate()
        effects.invoke = { channel, args in
            engine.calls.append((channel, args))
            if channel == "session:create" { return await gate.wait() }
            return channel == "providers:detect" ? Self.detected : .bool(true)
        }
        let page = NativeLandingModel(effects: effects)
        page.apply(Self.lists(), detected: Self.detected, added: .null, pickLead: false)
        page.text = "Fix it"
        let sending = Task { await page.sendNow() }
        while !engine.calls.contains(where: { $0.0 == "session:create" }) { await Task.yield() }
        page.text += " and add a test"   // typed after Return
        engine.onScreen = false          // he went to another session
        gate.open(.object([.init("id", .string("77777777-7777-4777-8777-777777777777"))]))
        await sending.value
        XCTAssertEqual(engine.added.count, 1, "added quietly to the side panel")
        XCTAssertTrue(engine.shown.isEmpty, "the window is not pulled to it")
        XCTAssertEqual(page.text, " and add a test", "only the sent text left the box")
    }

    /// Blocker 3 and 4: no project never means his home folder; a remembered folder that is gone falls back silently;
    /// a Return before the lists arrive is held and honours his agent; nothing half-applied is remembered.
    func testDeadFolderEarlyReturnAndNeverHome() async throws {
        let engine = Engine(), defaults = scratch()
        NativeLandingMemory.remember(NativeLastStart(folder: "/gone/deleted-project", projectID: "deleted", projectName: "Deleted",
            provider: "claude", providerName: "Claude", account: nil, accountName: nil, model: "opus", modelName: "Opus", effort: nil,
            chat: true, agentID: "lead-1", agentName: "Builder"), defaults)
        final class Flag { var up = false }
        let flag = Flag()
        let page = NativeLandingModel(effects: Self.effects(engine, defaults: defaults, ready: { flag.up }))
        XCTAssertNil(page.folder, "a folder that is gone is not used"); XCTAssertEqual(page.projectName, "Independent")
        page.text = "hello"
        let sending = Task { await page.sendNow() }
        for _ in 0..<3 { await Task.yield() }
        XCTAssertTrue(engine.made.isEmpty, "his Return is held until the app is up and his choices are checked")
        flag.up = true
        await sending.value
        XCTAssertEqual(engine.calls.filter { $0.0 == "session:start-agent" }.count, 1, "his agent, not the plain AI")
        XCTAssertEqual(cwd(engine), Self.ownFolder, "the app's own folder, never the dead one, never home")
        XCTAssertNotEqual(cwd(engine), NSHomeDirectory())
        let kept = try XCTUnwrap(NativeLandingMemory.lastStart(defaults))
        XCTAssertNil(kept.folder); XCTAssertEqual(kept.agentID, "lead-1")
        // Never ready: nothing is made and nothing is remembered.
        let stuck = Engine(), fresh = scratch()
        let waiting = NativeLandingModel(effects: Self.effects(stuck, defaults: fresh, ready: { false }))
        waiting.text = "hello"
        await waiting.sendNow()
        XCTAssertTrue(stuck.made.isEmpty); XCTAssertNil(NativeLandingMemory.lastStart(fresh)); XCTAssertEqual(waiting.text, "hello")
        XCTAssertNotNil(waiting.problem)
        // Picking Independent: the app's own folder too.
        let other = Engine()
        let plain = NativeLandingModel(effects: Self.effects(other, defaults: scratch()))
        plain.apply(Self.lists(), detected: Self.detected, added: .null, pickLead: false)
        plain.chooseProject(PROJProjects.independent)
        plain.text = "hi"
        await plain.sendNow()
        XCTAssertEqual(cwd(other), Self.ownFolder)
        XCTAssertEqual(NativeLandingPlaces.independent(home: "/Users/someone").path, "/Users/someone/Terminal Deck/Independent")
    }

    // MARK: The doors, the tools and the setting

    func testAToolNeverOpensThePageThePersonDoes() async {
        final class Doors { var presented: [String?] = []; var prepared: [String?] = [] }
        let doors = Doors()
        let actions = NativeButtonActions(effects: .init(invoke: { _, _ in NSNull() },
            presentSession: { doors.presented.append($0) }, prepareSession: { doors.prepared.append($0) }, confirm: { _ in true }))
        actions.ingest(SidebarState(groups: [], projects: [SidebarProject(id: "/work", title: "Work", expanded: true, sessions: [])], selectedId: nil))
        _ = await actions.runForTool(.newSession).value
        _ = await actions.runForTool(.newSessionIn("/work")).value
        XCTAssertEqual(doors.presented.count, 0, "a tool never shows the page or takes his keyboard")
        XCTAssertEqual(doors.prepared, [nil, "/work"])
        _ = await actions.run(.newSession).value
        XCTAssertEqual(doors.presented.count, 1, "his own press opens it")
    }

    /// Item 6: a tool never changes the page while he is on it or has typed there.
    func testToolsPrepareOnlyAnIdlePage() async throws {
        let engine = Engine(), defaults = scratch()
        let page = model(engine, defaults: defaults)
        page.apply(Self.lists(), detected: Self.detected, added: .null, pickLead: false)
        page.chooseProject(Self.work)
        page.prepareForTool(folder: "/work/site", onScreen: true)
        XCTAssertEqual(page.folder, "/work/imatch", "he is on the page: a tool changes nothing")
        page.text = "my words"
        page.prepareForTool(folder: "/work/site", onScreen: false)
        XCTAssertEqual(page.folder, "/work/imatch", "words in the box: a tool changes nothing")
        page.text = ""
        page.prepareForTool(folder: "/work/site", onScreen: false)
        XCTAssertEqual(page.folder, "/work/site")
        XCTAssertTrue(engine.made.isEmpty)
    }

    /// LANDING-3 B: with no New session form open, new-session-start refuses and names the right tool; nothing starts.
    func testNewSessionStartWithNoFormRefusesAndStartsNothing() async {
        final class Calls { var channels: [String] = [] }
        let calls = Calls()
        let actions = NativeButtonActions(effects: .init(invoke: { channel, _ in calls.channels.append(channel); return NSNull() },
            presentSession: { _ in }, confirm: { _ in true }))
        XCTAssertFalse(NativeNewSession.isOpen)
        let outcome = await actions.runForTool(.submitNewSession).value
        XCTAssertEqual(outcome, .refused("No New session form is open. Use sessions_start_agent to start a session."))
        XCTAssertFalse(calls.channels.contains { $0.hasPrefix("session:") }, "zero sessions")
    }

    func testWhenTerminalDeckOpensSetting() {
        let setting = SettingsSchema.setting(NativeLandingOpensOn.settingID)
        XCTAssertEqual(setting?.label, "When Terminal Deck opens")
        XCTAssertEqual(setting?.options.map(\.label), ["New session", "Hoot chat", "Where I left off"], "Owner, 15 Nov: no Overview")
        XCTAssertEqual(setting?.defaultValue.string, "new-session")
        XCTAssertEqual(SettingsSchema.setting("general.restoreSessions")?.label, "Reopen sessions after a restart", "one setting for one thing")
        let defaults = scratch()
        XCTAssertEqual(NativeLandingOpensOn.current(defaults), .newSession)
        NativeLandingOpensOn.mirror("hoot", defaults); XCTAssertEqual(NativeLandingOpensOn.current(defaults), .hoot)
        NativeLandingOpensOn.mirror("nonsense", defaults); XCTAssertEqual(NativeLandingOpensOn.current(defaults), .hoot)
        // An older build's "Overview" opens New session, in this Mac's copy and in the saved settings alike.
        NativeLandingOpensOn.mirror("overview", defaults); XCTAssertEqual(NativeLandingOpensOn.current(defaults), .newSession)
        defaults.set("overview", forKey: NativeLandingOpensOn.mirrorKey); XCTAssertEqual(NativeLandingOpensOn.current(defaults), .newSession)
        let merged = SettingsSchema.merge([NativeLandingOpensOn.settingID: .string("overview")])
        XCTAssertEqual(merged[NativeLandingOpensOn.settingID]?.string, "new-session")
    }

    /// Owner, 14 Nov: on his Macs ("Your own Claude Code install" in effect) the live catalogue has no Claude list, so the
    /// page showed no Model at all and "Default effort". The model is always offered and named; so is the effort.
    func testTheModelIsAlwaysThereAndNamedWithNoLiveList() async throws {
        let defaults = scratch()
        // What NativePhoneStart gives with no live Claude list: Claude with no models, efforts as AGSCapabilities has them.
        let bare = NativeRPCValue.object([.init("providers", .array([
            .object([.init("id", .string("claude")), .init("name", .string("Claude")), .init("chat", .bool(true)),
                     .init("models", .array([])), .init("efforts", .array(["low", "medium", "high", "xhigh"].map(NativeRPCValue.string)))]),
            .object([.init("id", .string("shell")), .init("name", .string("Shell")), .init("chat", .bool(false)),
                     .init("models", .array([])), .init("efforts", .array([]))])])),
            .init("defaultProvider", .string("claude"))])
        let chatID = "44444444-4444-4444-8444-444444444444"
        final class Asked { var channels: [String] = [] }
        let asked = Asked()
        // A running Claude chat: its box offers Claude Code's own choices and reports the model it runs.
        let invoke: NativeLandingModels.Invoke = { channel, _ in
            asked.channels.append(channel)
            switch channel {
            case "session:list":
                return .array([.object([.init("id", .string(chatID)), .init("provider", .string("claude")), .init("chat", .bool(true))])])
            case "session:chat:options":
                return .object([.init("model", .string("claude:opus")), .init("models", .array([
                    .object([.init("id", .string("claude:default")), .init("name", .string("Default"))]),
                    .object([.init("id", .string("claude:opus")), .init("name", .string("Opus"))]),
                    .object([.init("id", .string("claude:sonnet")), .init("name", .string("Sonnet"))])]))])
            default: return .null
            }
        }
        let filled = await NativeLandingModels.filled(bare, invoke: invoke, defaults: defaults, cliDefault: { _ in (nil, "xhigh") })
        XCTAssertEqual(Set(asked.channels), ["session:list", "session:chat:options"], "reads only")
        let engine = Engine()
        var effects = Self.effects(engine, defaults: defaults)
        effects.choices = { _ in filled }
        let page = NativeLandingModel(effects: effects)
        page.apply(filled, detected: Self.detected, added: .null, pickLead: false)
        page.chooseAI("claude")
        XCTAssertTrue(page.showsModel, "the Model choice is on the page")
        XCTAssertEqual(page.models.map(\.id), ["opus", "sonnet"], "Claude Code's own choices, no blank \"default\" row")
        XCTAssertEqual(page.modelName, "Opus", "the model that will really be used, named")
        XCTAssertEqual(page.defaultModelLabel, "Opus (default)")
        XCTAssertEqual(page.effortName, "Extra", "the effort that will really be used, named")
        XCTAssertEqual(page.defaultEffortLabel, "Extra (default)")
        page.chooseModel("sonnet"); XCTAssertEqual(page.modelName, "Sonnet")
        page.chooseAI("shell")
        XCTAssertFalse(page.showsModel, "Shell has no models")

        // Next launch, no chat running: the list and default seen last time on this Mac.
        let later = await NativeLandingModels.filled(bare, invoke: { _, _ in .array([]) }, defaults: defaults, cliDefault: { _ in (nil, nil) })
        XCTAssertEqual(later["providers"].elements?.first?["models"].elements?.compactMap { $0["id"].string }, ["opus", "sonnet"])
        XCTAssertEqual(later["providers"].elements?.first?["defaultModel"].string, "opus")
        // The CLI's own setting wins over what a chat reports; a bare alias reads as a name.
        let configured = await NativeLandingModels.filled(bare, invoke: invoke, defaults: scratch(), cliDefault: { _ in ("claude-fable-5-2", nil) })
        XCTAssertEqual(configured["providers"].elements?.first?["defaultModel"].string, "claude-fable-5-2")
        XCTAssertEqual(NativeLandingModels.name("claude-fable-5-2"), "Fable 5.2")
        XCTAssertEqual(NativeLandingModels.name("opus[1m]"), "Opus 1M")
    }

    /// LANDING-FIX-2 (the MacBook): no live list, no chat ever run, nothing seen before. The model is still offered,
    /// from Claude Code's own aliases, with the default named; the first real list replaces them.
    func testAMacThatNeverSawAListStillOffersTheModel() async throws {
        let defaults = scratch()
        let bare = NativeRPCValue.object([.init("providers", .array([
            .object([.init("id", .string("claude")), .init("name", .string("Claude")), .init("chat", .bool(true)),
                     .init("models", .array([])), .init("efforts", .array(["low", "medium", "high", "xhigh"].map(NativeRPCValue.string)))])])),
            .init("defaultProvider", .string("claude"))])
        let nothing: NativeLandingModels.Invoke = { _, _ in .array([]) }
        let first = await NativeLandingModels.filled(bare, invoke: nothing, defaults: defaults, cliDefault: { _ in ("claude-fable-5-2", "xhigh") })
        let row = try XCTUnwrap(first["providers"].elements?.first)
        // LANDING-FIX-3 (b): one row per model line: "Fable" is the default's own line, already its first row.
        // 15 Nov review item 1: every model Claude Code itself offers (its 1M windows and Haiku too).
        XCTAssertEqual(row["models"].elements?.compactMap { $0["id"].string }, ["fable[1m]", "opus", "opus[1m]", "sonnet", "sonnet[1m]", "haiku"])
        XCTAssertEqual(row["defaultModel"].string, "claude-fable-5-2")
        let page = NativeLandingModel(effects: Self.effects(Engine(), defaults: scratch()))
        page.apply(first, detected: Self.detected, added: .null, pickLead: false)
        XCTAssertTrue(page.showsModel)
        XCTAssertEqual(page.modelName, "Fable 5.2", "the default is named, never blank")
        XCTAssertEqual(page.defaultModelLabel, "Fable 5.2 (default)")
        XCTAssertEqual(page.models.map(\.name), ["Fable 5.2 1M", "Opus", "Opus 1M", "Sonnet", "Sonnet 1M", "Haiku"], "menu: Fable 5.2 (default), then every other model")
        page.chooseModel("opus"); XCTAssertEqual(page.modelName, "Opus", "he can choose another")
        // The built-in names are never remembered: a real list, once seen, is what this Mac keeps.
        let real = bare.setting("providers", .array([try XCTUnwrap(bare["providers"].elements?.first)
            .setting("models", .array([.object([.init("id", .string("claude-fable-5-2")), .init("name", .string("Fable 5.2"))])]))]))
        _ = await NativeLandingModels.filled(real, invoke: nothing, defaults: defaults, cliDefault: { _ in (nil, nil) })
        let later = await NativeLandingModels.filled(bare, invoke: nothing, defaults: defaults, cliDefault: { _ in (nil, nil) })
        XCTAssertEqual(later["providers"].elements?.first?["models"].elements?.compactMap { $0["id"].string }, ["claude-fable-5-2"])
    }

    /// LANDING-FIX-3 (a) (the MacBook): the AI does not say which model it runs: the page says whose default it is.
    func testAnUnknownDefaultIsNamedAfterTheAI() async throws {
        let bare = NativeRPCValue.object([.init("providers", .array([
            .object([.init("id", .string("claude")), .init("name", .string("Claude")), .init("chat", .bool(true)),
                     .init("models", .array([])), .init("efforts", .array(["low", "high"].map(NativeRPCValue.string)))])])),
            .init("defaultProvider", .string("claude"))])
        let filled = await NativeLandingModels.filled(bare, invoke: { _, _ in .array([]) }, defaults: scratch(), cliDefault: { _ in (nil, nil) })
        XCTAssertEqual(filled["providers"].elements?.first?["models"].elements?.compactMap { $0["id"].string },
                       ["fable", "fable[1m]", "opus", "opus[1m]", "sonnet", "sonnet[1m]", "haiku"])
        let page = NativeLandingModel(effects: Self.effects(Engine(), defaults: scratch()))
        page.apply(filled, detected: Self.detected, added: .null, pickLead: false)
        XCTAssertTrue(page.showsModel)
        XCTAssertEqual(page.modelName, "Claude's default", "never a bare \"Default model\"")
        XCTAssertEqual(page.defaultModelLabel, "Claude's default")
        XCTAssertEqual(NativeLandingModels.line("claude-opus-5-5"), "opus"); XCTAssertEqual(NativeLandingModels.line("opus[1m]"), "opus")
    }

    /// LANDING-FIX-4: an agent that brings its own model and effort shows them, not changeable; one that leaves them
    /// open gets the normal choices in a Chat (applied right after its start) and a named line in Terminal.
    func testAnAgentsModelAndEffortAreAlwaysShown() async throws {
        // The saved records: Builder brings Opus and High in its own settings; Helper leaves them open.
        let listed = Self.lists().setting("agents", .array([
            .object([.init("id", .string("lead-1")), .init("name", .string("Builder")), .init("provider", .string("claude")), .init("lead", .bool(true))]),
            .object([.init("id", .string("helper")), .init("name", .string("Helper")), .init("provider", .string("claude")), .init("lead", .bool(false))])]))
        let saved: NativeLandingModels.Invoke = { channel, _ in
            guard channel == "tasks:state" else { return .null }
            return .object([.init("agents", .array([
                .object([.init("id", .string("lead-1")), .init("model", .string("sonnet")),
                         .init("agoptSettings", .object([.init("model", .string("opus")), .init("effort", .string("high"))]))]),
                .object([.init("id", .string("helper"))])]))])
        }
        var lists = await NativeLandingModels.withAgentChoices(listed, invoke: saved)
        // Claude names its default (as NativeLandingModels.filled gives it).
        lists = lists.setting("providers", .array((lists["providers"].elements ?? []).map { row in
            row["id"].string == "claude" ? row.setting("defaultModel", .string("opus")).setting("defaultEffort", .string("xhigh")) : row }))
        let engine = Engine()
        var effects = Self.effects(engine, defaults: scratch())
        effects.choices = { _ in lists }
        let page = NativeLandingModel(effects: effects)
        page.apply(lists, detected: Self.detected, added: .null, pickLead: false)

        page.chooseAgent("lead-1")
        XCTAssertTrue(page.agentBrings)
        XCTAssertFalse(page.showsModel); XCTAssertFalse(page.showsEffort)
        XCTAssertEqual(page.agentRuns, "Opus \u{00B7} High", "its own settings win over its record's field; no name in the line")
        XCTAssertEqual(page.agentRunsHelp, "Set by Builder")

        page.chooseAgent("helper"); page.chooseChat(true)
        XCTAssertNil(page.agentRuns, "it leaves them open: the normal choices")
        XCTAssertNil(page.agentRunsHelp)
        XCTAssertTrue(page.showsModel); XCTAssertTrue(page.showsEffort)
        page.chooseModel("sonnet"); page.chooseEffort("high")
        page.text = "hello"
        await page.sendNow()
        XCTAssertEqual(engine.calls.filter { $0.0 == "session:start-agent" }.count, 1)
        let options = try XCTUnwrap(engine.calls.first { $0.0 == "session:chat:options" }?.1.last)
        XCTAssertEqual(options["model"].string, "claude:sonnet"); XCTAssertEqual(options["effort"].string, "high")

        page.chooseAgent("helper"); page.chooseChat(false)
        XCTAssertFalse(page.showsModel, "Terminal: nothing can carry a choice to an agent's start")
        XCTAssertEqual(page.agentRuns, "Opus \u{00B7} Extra", "so the page names what it will run with")
        XCTAssertEqual(page.agentRunsHelp, "Claude's default for this session")
    }

    /// His remembered model stays chosen when the list does not carry it.
    func testHisLastModelStaysChosen() async {
        let engine = Engine(), defaults = scratch()
        NativeLandingMemory.remember(NativeLastStart(folder: nil, projectID: nil, projectName: nil, provider: "claude", providerName: "Claude",
            account: nil, accountName: nil, model: "opus[1m]", modelName: "Opus 1M", effort: "high", chat: true, agentID: nil, agentName: nil), defaults)
        let page = model(engine, defaults: defaults)
        page.apply(Self.lists(), detected: Self.detected, added: .null, pickLead: false)
        XCTAssertEqual(page.model, "opus[1m]")
        XCTAssertEqual(page.modelName, "Opus 1M")
        XCTAssertTrue(page.models.contains { $0.id == "opus[1m]" })
    }

    func testFocusTicketsComeOnlyFromThePerson() {
        let focus = NativeLandingFocus()
        XCTAssertFalse(focus.take(), "no ticket: the page never takes the keyboard by itself")
        focus.personAsked()
        XCTAssertTrue(focus.take()); XCTAssertFalse(focus.take(), "once per ask, never on a redraw")
    }

    /// Item 5's rule: first load only, page on screen, nothing else holding the keyboard.
    func testTheHiddenPageTakesTheKeyboardOnlyOnTheFirstLoadWhenFree() {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300)), his = NSTextView(frame: NSRect(x: 200, y: 0, width: 200, height: 300))
        window.contentView?.addSubview(page); window.contentView?.addSubview(his)
        XCTAssertTrue(NativePageKeyboard.mayTake(firstLoad: true, pageOnScreen: true, window: window, page: page))
        XCTAssertFalse(NativePageKeyboard.mayTake(firstLoad: false, pageOnScreen: true, window: window, page: page), "a reload never")
        XCTAssertFalse(NativePageKeyboard.mayTake(firstLoad: true, pageOnScreen: false, window: window, page: page), "under a native screen never")
        window.makeFirstResponder(his)
        XCTAssertFalse(NativePageKeyboard.mayTake(firstLoad: true, pageOnScreen: true, window: window, page: page), "he holds the keyboard")
    }
}

/// Holds a channel's answer until the test lets it go.
@MainActor final class LandingGate {
    private var waiting: CheckedContinuation<NativeRPCValue, Never>?
    private var answer: NativeRPCValue?
    func wait() async -> NativeRPCValue {
        if let answer { return answer }
        return await withCheckedContinuation { waiting = $0 }
    }
    func open(_ value: NativeRPCValue) {
        answer = value
        waiting?.resume(returning: value); waiting = nil
    }
}
