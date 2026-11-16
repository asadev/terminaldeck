import AppKit
import SwiftUI
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// The owner's recorded review of 15 Nov, New session page (items 1-13). Scratch defaults and recorded calls only: no
/// app, engine, session host, Keychain or his files.
@MainActor
final class NewSessionReviewTests: XCTestCase {
    private func scratch() -> UserDefaults {
        let name = "td-new-session-review-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func page(_ engine: LandingNewSessionTests.Engine = .init(), host: Bool = true, lists: NativeRPCValue = NewSessionReviewTests.lists()) -> NativeLandingModel {
        var effects = LandingNewSessionTests.effects(engine, defaults: scratch())
        effects.choices = { _ in lists }
        effects.hostHonoursPick = { host }
        let model = NativeLandingModel(effects: effects)
        model.apply(lists, detected: LandingNewSessionTests.detected, added: .null, pickLead: false)
        return model
    }

    /// The lists as the Mac now sends them: logins by name, with "email" and "state"; two share a name.
    static func lists() -> NativeRPCValue {
        let base = LandingNewSessionTests.lists()
        func account(_ id: String, _ name: String, _ provider: String, email: String?, state: String) -> NativeRPCValue {
            var row = NativeRPCValue.object([.init("id", .string(id)), .init("name", .string(name)), .init("provider", .string(provider)),
                                             .init("state", .string(state))])
            if let email { row = row.setting("email", .string(email)) }
            return row
        }
        return base.setting("accounts", .array([
            account("system", "Your own Claude Code install", "claude", email: "owner@example.com", state: "ready"),
            account("c-imza", "Imza Premium", "claude", email: "imza@example.com", state: "ready"),
            account("c-work", "Work", "claude", email: "work@example.com", state: "signIn"),
            account("c-work-2", "Work", "claude", email: "work2@example.com", state: "limit"),
            account("x-1", "ChatGPT", "codex", email: nil, state: "ready")]))
    }

    // MARK: 1. Every model

    func testEveryModelClaudeCodeOffersIsListedWithNoLiveList() async throws {
        let bare = NativeRPCValue.object([.init("providers", .array([
            .object([.init("id", .string("claude")), .init("name", .string("Claude")), .init("chat", .bool(true)),
                     .init("models", .array([])), .init("efforts", .array(["low", "high"].map(NativeRPCValue.string)))])]))])
        let extras = NativeLandingModels.extras([
            .object([.init("value", .string("claude-fable-5-2[1m]")), .init("label", .string("Fable")),
                     .init("description", .string("Fable 5.2 \u{00B7} Most capable for your hardest tasks"))])])
        XCTAssertEqual(extras.map(\.0), ["claude-fable-5-2[1m]"])
        XCTAssertEqual(extras.map(\.1), ["Fable 5.2 1M"], "named as Claude Code's own /model names it, with its window")
        let filled = await NativeLandingModels.filled(bare, invoke: { _, _ in .array([]) }, defaults: scratch(),
                                                      cliDefault: { _ in ("claude-fable-5-2", nil) }, extras: { _ in extras })
        let ids = filled["providers"].elements?.first?["models"].elements?.compactMap { $0["id"].string }
        XCTAssertEqual(ids, ["claude-fable-5-2[1m]", "opus", "opus[1m]", "sonnet", "sonnet[1m]", "haiku"],
                       "the account's own extra, then every line and window; Fable (the default's own line) is the default row")
        XCTAssertEqual(NativeLandingModels.key("fable[1m]"), "fable[1m]")
        XCTAssertEqual(NativeLandingModels.key("claude-fable-5-2"), "fable")
    }

    /// DESIGN-FIXES NS-1, NS-2 (15 Nov): with an EMPTY list from the session host, the model menu still has the seven
    /// models, the default first by its real name; the pill names it ("Fable 5.2"), never "Claude's default".
    func testTheModelMenuHasSevenModelsWithAnEmptyHostList() async throws {
        let filled = await NewSessionReviewPictures.filledLists(defaults: scratch())
        let ids = filled["providers"].elements?.first { $0["id"].string == "claude" }?["models"].elements?.compactMap { $0["id"].string }
        XCTAssertEqual(ids, ["fable[1m]", "opus", "opus[1m]", "sonnet", "sonnet[1m]", "haiku"])
        let model = page(lists: filled)
        model.chooseAI("claude"); model.chooseChat(true); model.chooseAgent(nil)
        let names = model.composerCatalogue.sections.flatMap(\.featured).map(\.name)
        XCTAssertEqual(names, ["Fable 5.2", "Fable 5.2 1M", "Opus", "Opus 1M", "Sonnet", "Sonnet 1M", "Haiku"])
        XCTAssertEqual(model.modelName, "Fable 5.2")
        XCTAssertFalse(names.contains { $0.hasSuffix("'s default") })
        // The account's own extras: one of a listed line and window takes that row's place; the others come last.
        let rows = NativeLandingModels.builtIn("claude", default: "claude-fable-5-2",
                                               extras: [("claude-opus-5-5[1m]", "Opus 5.5 1M"), ("claude-mythos-1", "Mythos 1")])
        XCTAssertEqual(rows.map(\.1), ["Fable 5.2 1M", "Opus", "Opus 5.5 1M", "Sonnet", "Sonnet 1M", "Haiku", "Mythos 1"])
    }

    // MARK: 3. The permission pill

    func testThePermissionPillIsAChoiceOfTheAIsOwnModesAndTheSessionStartsInIt() async throws {
        XCTAssertTrue(NativeLandingHost.pickOffered)
        XCTAssertEqual(NewSessionPermissionModes.modes(provider: "claude"), [.ask, .plan, .changes, .bypass])
        XCTAssertEqual(NewSessionPermissionModes.modes(provider: "shell"), [])
        let engine = LandingNewSessionTests.Engine()
        let model = page(engine)
        model.chooseAI("claude"); model.chooseChat(true); model.chooseAgent(nil)
        XCTAssertEqual(model.shownPermission, .bypass, "Bypass stays the default")
        XCTAssertNil(model.permissionFixedHelp, "a menu, not plain words")
        XCTAssertEqual(model.permissionModes, [.ask, .plan, .changes, .bypass])
        model.choosePermission(.plan)
        XCTAssertEqual(model.shownPermission, .plan)
        model.text = "go"
        await model.sendNow()
        let input = try XCTUnwrap(engine.calls.first { $0.0 == "session:create" }?.1.first)
        XCTAssertEqual(input["permissionMode"].string, "plan")
        XCTAssertEqual(input["chosenStartPermission"].string, "plan", "it really starts in the chosen mode")
        // An older running host: the pill tells the truth (Bypass, plain words), nothing stricter is claimed.
        let old = page(host: false)
        old.choosePermission(.ask)
        XCTAssertEqual(old.shownPermission, .bypass)
        XCTAssertNotNil(old.permissionFixedHelp)
    }

    func testARestoredSessionShowsTheModeItReallyRuns() {
        let bypass = "bypassPermissions"
        // Restored, reported "Ask first", Claude's own setting is Bypass: shows Bypass, with the note.
        XCTAssertEqual(NativeSessionModeTruth.shown(reported: "ask", provider: "claude", resumed: true, changedHere: false, ownDefault: bypass), "bypass")
        let answer = NativeSessionModeTruth.corrected(.object([.init("permissionMode", .string("ask"))]), provider: "claude", resumed: true,
                                                      changedHere: false, ownDefault: bypass)
        XCTAssertEqual(answer["permissionMode"].string, "bypass")
        XCTAssertEqual(answer["permissionNote"].string, NativeSessionModeTruth.note)
        // Fresh (started by name), changed by him since, another AI, or no own setting: the host's answer stands.
        XCTAssertNil(NativeSessionModeTruth.shown(reported: "ask", provider: "claude", resumed: false, changedHere: false, ownDefault: bypass))
        XCTAssertNil(NativeSessionModeTruth.shown(reported: "ask", provider: "claude", resumed: true, changedHere: true, ownDefault: bypass))
        XCTAssertNil(NativeSessionModeTruth.shown(reported: "ask", provider: "codex", resumed: true, changedHere: false, ownDefault: bypass))
        XCTAssertNil(NativeSessionModeTruth.shown(reported: "ask", provider: "claude", resumed: true, changedHere: false, ownDefault: nil))
        XCTAssertNil(NativeSessionModeTruth.shown(reported: "plan", provider: "claude", resumed: true, changedHere: false, ownDefault: bypass))
        XCTAssertEqual(NativeSessionModeTruth.shown(reported: "ask", provider: "claude", resumed: true, changedHere: false, ownDefault: "acceptEdits"), "changes")
        let defaults = scratch()
        XCTAssertFalse(NativeSessionModeTruth.changedHere("s@1", defaults: defaults))
        NativeSessionModeTruth.noteChanged("s@1", defaults: defaults)
        XCTAssertTrue(NativeSessionModeTruth.changedHere("s@1", defaults: defaults))
        XCTAssertFalse(NativeSessionModeTruth.changedHere("s@2", defaults: defaults), "a later launch of it is not trusted")
    }

    // MARK: 4, 5, 11. The project menu

    func testTheProjectStartsWithItsLeadAndNoProjectReadsIndependent() {
        let model = page()
        XCTAssertNil(model.folder)
        XCTAssertEqual(NativeLandingPlaceMenu(model: model).placeName, "Independent", "never \"No project\"")
        model.chooseProject(LandingNewSessionTests.work)
        // The lead is chosen when the lists come back for the project (pickLead); here they are applied directly.
        model.apply(Self.lists(), detected: LandingNewSessionTests.detected, added: .null, pickLead: true)
        XCTAssertEqual(model.agentID, "lead-1", "a new session starts with the project's lead: nobody has to choose")
        XCTAssertEqual(NativeLandingPlaceMenu(model: model).placeName, "iMatch", "the lead is the default, so only the project shows")
    }

    // MARK: 6, 7. The account menu

    func testAccountsShowByNameWithTheirRealState() {
        let model = page()
        let claude = model.accounts.filter { $0.provider == "claude" }
        XCTAssertEqual(claude.map(\.name), ["Your own Claude Code install", "Imza Premium", "Work", "Work"])
        XCTAssertEqual(claude.filter(\.needsHim).map(\.id), ["c-work", "c-work-2"], "only a login that needs him has a mark")
        XCTAssertEqual(claude.first { $0.id == "c-work" }?.stateWords, "Needs sign-in")
        XCTAssertEqual(claude.first { $0.id == "c-work-2" }?.stateWords, "Limit reached")
        XCTAssertNil(claude.first { $0.id == "c-imza" }?.stateWords)
        // The Mac's own naming rules.
        let named = CodingAIAccount(id: "k", name: "Imza Premium", provider: "claude")
        XCTAssertEqual(NativePhoneStart.accountName(named, CodingAISignIn(state: .signedIn, account: "imza@example.com")), "Imza Premium")
        let own = CodingAIAccount(id: "system", name: "Default", provider: "claude", system: true)
        XCTAssertEqual(NativePhoneStart.accountName(own, CodingAISignIn(state: .signedIn, account: "me@example.com")), "Your own Claude Code install")
        XCTAssertEqual(NativePhoneStart.accountState(CodingAISignIn(state: .signedOut), limited: false), "signIn")
        XCTAssertEqual(NativePhoneStart.accountState(CodingAISignIn(state: .signedIn), limited: true), "limit")
        XCTAssertEqual(NativePhoneStart.accountState(CodingAISignIn(state: .signedIn), limited: false), "ready")
        XCTAssertEqual(NativePhoneStart.accountState(nil, limited: false), "unknown")
    }
}

/// Pictures for the 15 Nov review, light and dark, into `macos/night/codex/new-session-review-evidence/`: the empty page,
/// the project menu, the account menu, the model menu and the permission menu (system menus drawn as their rows, in the
/// shared row style). Hidden passive panels only; no AppModel.shared, no engine, no microphone lookup.
@MainActor
final class NewSessionReviewPictures: XCTestCase {
    private var out: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("night/codex/new-session-review-evidence")
    }

    /// The page's lists as the Mac fills them when the session host gives NO model list (NS-2): Claude Code's own
    /// models, its default read from its settings ("claude-fable-5-2", Extra high). No host, no file read.
    static func filledLists(defaults: UserDefaults) async -> NativeRPCValue {
        let base = NewSessionReviewTests.lists()
        let providers = (base["providers"].elements ?? []).map { row in
            row["id"].string == "claude" ? row.setting("models", .array([])) : row
        }
        return await NativeLandingModels.filled(base.setting("providers", .array(providers)), invoke: { _, _ in .array([]) },
                                                defaults: defaults,
                                                cliDefault: { $0 == "claude" ? ("claude-fable-5-2", "xhigh") : (nil, nil) },
                                                extras: { _ in [] })
    }

    private func model() async -> NativeLandingModel {
        let name = "td-new-session-review-pictures-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        var effects = LandingNewSessionTests.effects(LandingNewSessionTests.Engine(), defaults: defaults)
        effects.hostHonoursPick = { true }
        let model = NativeLandingModel(effects: effects)
        // The fill the app does (NS-2); the earlier pictures used a list with no default and Terminal with the lead,
        // where the menu is closed by design (an agent's Terminal start cannot take a model).
        let lists = await Self.filledLists(defaults: defaults)
        model.apply(lists, detected: LandingNewSessionTests.detected, added: .null, pickLead: false)
        model.chooseProject(LandingNewSessionTests.work)
        model.apply(lists, detected: LandingNewSessionTests.detected, added: .null, pickLead: true)
        model.pickAccount("c-imza", of: "claude")
        model.chooseChat(true)
        return model
    }

    private func capture<V: View>(_ view: V, _ name: String, width: CGFloat, height: CGFloat) throws {
        for dark in [false, true] {
            let root = view.environment(\.agkitOffscreenSolid, true).environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: width, height: height).background(DeckTokens.chatPage)
            let host = NSHostingView(rootView: root)
            let panel = NativePassiveChatPanel(contentRect: .init(x: -30000, y: -30000, width: width, height: height),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.prepareForPassiveCapture()
            panel.identifier = .init("dev.terminaldeck.new-session-review-pictures.scratch")
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            panel.contentView = host
            defer { panel.contentView = nil; panel.close() }
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("NEW-SESSION-\(name)-\(dark ? "dark" : "light").png"), options: .atomic)
            XCTAssertEqual(bitmap.pixelsWide, Int(width))
            XCTAssertFalse(panel.isVisible)
        }
    }

    private func menu<V: View>(@ViewBuilder _ rows: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 0) { rows() }
            .padding(6).frame(width: 280, alignment: .leading)
            .background(DeckTokens.card, in: .rect(cornerRadius: 10))
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func testPictures() async throws {
        let page = await model()
        try capture(NativeLandingPage(model: page, focus: NativeLandingFocus(), fixture: true), "empty-page", width: 1000, height: 780)
        try capture(NativeLandingPage(model: page, focus: NativeLandingFocus(), fixture: true), "empty-page-narrow", width: 520, height: 700)
        try capture(LandingPlaceMenuRows(model: page), "project-menu", width: 340, height: 300)
        try capture(NativeLandingAccountList(model: page).background(DeckTokens.card, in: .rect(cornerRadius: 10)).padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), "account-menu", width: 440, height: 380)
        let catalogue = page.composerCatalogue
        let rows = catalogue.sections.flatMap(\.featured)
        XCTAssertEqual(rows.map(\.name), ["Fable 5.2", "Fable 5.2 1M", "Opus", "Opus 1M", "Sonnet", "Sonnet 1M", "Haiku"])
        XCTAssertEqual(page.composerDraft.effort, "xhigh", "the effort pill beside it reads Extra high")
        try capture(menu {
            NewSessionMenuTitle(text: page.aiName, provider: page.chosenProvider)
            ForEach(rows) { row in NewSessionMenuRow(title: row.name, chosen: row.id == page.composerDraft.modelID) {} }
        }, "model-menu", width: 340, height: 300)
        try capture(menu {
            ForEach(page.permissionModes, id: \.self) { mode in
                NewSessionMenuRow(title: mode.fullName, chosen: mode == page.shownPermission) {}
            }
        }, "permission-menu", width: 340, height: 220)
    }
}
