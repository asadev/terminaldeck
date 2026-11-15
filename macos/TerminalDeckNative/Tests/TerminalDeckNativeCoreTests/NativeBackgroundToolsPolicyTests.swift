import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Asad, 31 Oct and 13 Nov 2026: a session using a simulator or a browser pulled him to that session and held him
// there until it finished. An AI's tool call never moves the person: no file a devices or browser tool reaches may
// select, show, raise or focus anything unless the line names the person's own action or gives his place back.

private func sources() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources", isDirectory: true)
}

@Test func noToolPathMovesThePerson() throws {
    let root = sources()
    var scanned = 0, moving: [String] = []
    for folder in ["TerminalDeckNative", "TerminalDeckBackend", "TerminalDeckNativeCore"] {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard NativeBackgroundToolsPolicy.isToolFile(file.lastPathComponent, source: source) else { continue }
            scanned += 1
            for (index, raw) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
                let code = raw.components(separatedBy: "//").first ?? raw
                let calls = NativeBackgroundToolsPolicy.navigation(in: code)
                guard !calls.isEmpty, !NativeBackgroundToolsPolicy.markers.contains(where: raw.contains) else { continue }
                moving.append(file.lastPathComponent + ":\(index + 1): " + trimmed)
            }
        }
    }
    #expect(scanned > 100, "every file that registers a tool is scanned")
    // MAC-NEXT-13b: the Devices window's devices_page and devices_remove live here; the scan must cover them.
    let devices = try String(contentsOf: root.appendingPathComponent("TerminalDeckNative/NativeMACHINESMCP.swift"), encoding: .utf8)
    #expect(devices.contains("\"devices.page\"") && devices.contains("\"devices.remove\""))
    #expect(NativeBackgroundToolsPolicy.isToolFile("NativeMACHINESMCP.swift", source: devices))
    #expect(moving.isEmpty, Comment(rawValue: "Tool paths that move the person:\n" + moving.joined(separator: "\n")))
}

/// MAC-NEXT-14: no tool path touches the app's keyboard at all, whatever its line says (`background-ok:` is no proof).
@Test func noToolPathTouchesTheKeyboard() throws {
    let root = sources()
    var scanned = 0, touching: [String] = []
    for folder in ["TerminalDeckNative", "TerminalDeckBackend", "TerminalDeckNativeCore"] {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard NativeBackgroundToolsPolicy.isToolFile(file.lastPathComponent, source: source) else { continue }
            scanned += 1
            for (index, raw) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
                let code = raw.components(separatedBy: "//").first ?? raw
                guard !NativeBackgroundToolsPolicy.keyboard(in: code).isEmpty else { continue }
                touching.append(file.lastPathComponent + ":\(index + 1): " + trimmed)
            }
        }
    }
    #expect(scanned > 100)
    #expect(touching.isEmpty, Comment(rawValue: "Tool paths that touch the app's keyboard:\n" + touching.joined(separator: "\n")))
    #expect(NativeBackgroundToolsPolicy.keyboard(in: "window.makeFirstResponder(view) // background-ok: given back") == ["makeFirstResponder("])
    #expect(NativeBackgroundToolsPolicy.keyboard(in: "view.keyDown(with: event)") == [".keyDown(with:"])
    // The browser page never takes the keyboard by itself, and the runtime never sends a page AppKit keys.
    let tab = try String(contentsOf: root.appendingPathComponent("TerminalDeckNative/NativeBrowserTab.swift"), encoding: .utf8)
    #expect(tab.contains("_setShouldSuppressFirstResponderChanges:") && tab.contains("guard NSApp.currentEvent === event"))
    let runtime = try String(contentsOf: root.appendingPathComponent("TerminalDeckNative/NativeSafariRuntime.swift"), encoding: .utf8)
    #expect(runtime.contains("func type(_ id: String, plan: BrowserTypingPlan) -> Bool { false }"))
    #expect(!runtime.contains("withPageKeyboard"))
}

/// MAC-NEXT-15: the browser's own files (the page view, its tabs, its screen, panels, compositions) are not tool-path
/// files, yet a tool's page lives in them. Every call there that moves the keyboard or puts a sheet over a window is
/// named here, one by one, with why it is the person's own action; a new one fails this test until it is named.
@Test func browserFilesTouchTheKeyboardOnlyWhereNamed() throws {
    let root = sources().appendingPathComponent("TerminalDeckNative", isDirectory: true)
    let prefixes = ["NativeBrowser", "BrowserTabsHook", "NativeCompositionBrowser", "NativeCompositionBR", "NativeCompositionProductionBrowser", "NativeCloudBrowser"]
    let patterns = NativeBackgroundToolsPolicy.keyboardCalls
        + ["addressFocused = true", "focusAddress()", "Focused = true", "focused = true", "initialFirstResponder", "beginSheetModal(", "runModal("]
    // (file, code on the line, why it is his own action)
    let named: [(String, String, String)] = [
        ("NativeBrowserScreen.swift", "if tab.url == nil, !tab.openedByPage { addressFocused = true }",
         "an empty tab HE opened puts his cursor in its address bar; a page's own new window never does, and a tool's tab always has an address and is never shown"),
        ("NativeBrowserScreen.swift", ".onChange(of: tab.focusAddressRequest) { addressFocused = true }", "his ⌘L or his ⌘T (NativeBrowserTab.focusAddress)"),
        ("NativeBrowserScreen.swift", "if let webView = tab.webView { webView.window?.makeFirstResponder(webView) }", "he pressed Enter in the address bar: the page he asked for gets his keyboard"),
        ("NativeBrowserScreen.swift", "oldWindow?.makeFirstResponder(nil)", "a page leaving his window gives the keyboard back (then to his terminal)"),
        ("NativeBrowserScreen.swift", ".onAppear { focused = true }", "the find bar he opened (⌘F / Find in Page) takes his cursor"),
        ("NativeBrowserScreen.swift", ".onChange(of: tab.focusFindRequest) { focused = true }", "his ⌘F again"),
        ("NativeBrowserTab.swift", "operation.runModal(for: window", "the print sheet for his toolbar's Print (browser_page print reaches it too: reported to Decker, MAC-NEXT-15)"),
        ("NativeBrowserTab.swift", "func focusAddress() { focusAddressRequest += 1 }", "the request his ⌘L / ⌘T make"),
        ("NativeBrowserTab.swift", "case \"l\": focusAddress(); return true", "his ⌘L"),
        ("NativeBrowserTab.swift", "return await alert.beginSheetModal(for: window)", "presentAlert: only for the .person dialog route, a camera question or a sign-in while HE uses the page (BrowserPagePersonRule)"),
        ("NativeBrowserTab.swift", "alert.window.initialFirstResponder = field", "a page's prompt shown only on the .person route"),
        ("NativeBrowserTab.swift", "super.keyDown(with: event)", "his own key, already delivered to the page by AppKit, passed on to WebKit (only noticed)"),
        ("NativeBrowserTab.swift", "window.makeFirstResponder(self)", "his own click in the page (NSApp.currentEvent === event); a tool's synthetic click never"),
        ("NativeBrowserTab.swift", "let response = await panel.beginSheetModal(for: window)", "the Mac's file chooser, only when he uses the page and no tool drives it"),
        ("NativeBrowserTab.swift", "alert.window.initialFirstResponder = user.stringValue.isEmpty ? user : password", "a site's sign-in, only while he uses the page"),
        ("NativeBrowserTabs.swift", "if show && url == nil && configuration == nil { tab.focusAddress() }", "his ⌘T: an empty tab shown to him; tools create with an address and show false"),
        ("NativeBrowserPanels.swift", "alert.window.initialFirstResponder = field", "his own New profile press"),
        ("NativeBrowserPanels.swift", "alert.beginSheetModal(for: window, completionHandler: finish)", "his own New profile press"),
        ("NativeBrowserPanels.swift", "finish(alert.runModal())", "his own New profile press, no window to sheet over"),
        ("NativeBrowserPanels.swift", "if autofocus { fieldFocused = true }", "the send row of a panel he opened"),
        ("NativeBrowserMarkup.swift", "textFocused = true", "his click with the text tool on a frozen picture"),
    ]
    var scanned = 0, unnamed: [String] = [], used = Set<Int>()
    for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    where file.pathExtension == "swift" && prefixes.contains(where: { file.lastPathComponent.hasPrefix($0) }) {
        scanned += 1
        let source = try String(contentsOf: file, encoding: .utf8)
        for (index, raw) in source.components(separatedBy: "\n").enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
            let code = raw.components(separatedBy: " //").first ?? raw
            guard patterns.contains(where: { code.contains($0) }) else { continue }
            if let at = named.indices.first(where: { named[$0].0 == file.lastPathComponent && code.contains(named[$0].1) }) { used.insert(at); continue }
            unnamed.append(file.lastPathComponent + ":\(index + 1): " + trimmed)
        }
    }
    #expect(scanned >= 25, "every browser file is read")
    #expect(unnamed.isEmpty, Comment(rawValue: "Keyboard or sheet calls in browser files that are not named as his own action:\n" + unnamed.joined(separator: "\n")))
    let stale = named.indices.filter { !used.contains($0) }.map { named[$0].0 + ": " + named[$0].1 }
    #expect(stale.isEmpty, Comment(rawValue: "Named calls no longer in the source (remove them here):\n" + stale.joined(separator: "\n")))
    // The routes that keep those sheets and the chooser away from a tool's page.
    let tab = try String(contentsOf: root.appendingPathComponent("NativeBrowserTab.swift"), encoding: .utf8)
    #expect(tab.contains("BrowserPagePersonRule.fileChooserOpens(") && tab.contains("BrowserPagePersonRule.dialogRoute("))
    let tabs = try String(contentsOf: root.appendingPathComponent("NativeBrowserTabs.swift"), encoding: .utf8)
    #expect(tabs.contains("BrowserPagePersonRule.newTabShows("))
}

/// MAC-NEXT-15b: no tool path reads or writes his clipboard. The few pasteboard calls on tool-path files are named one
/// by one with why they are his own action or never reach his clipboard.
@Test func noToolPathTouchesHisClipboard() throws {
    let root = sources()
    let named: [(String, String, String)] = [
        ("NativeFIXESDeviceContextMenu.swift", "let clipboard = NSPasteboard.general", "his own right-click Copy ID on a device row"),
        ("NativeSafariPasswords.swift", "NSPasteboard.general.clearContents()", "his own Copy in Passwords settings (native UI only; the passwords tool has no copy)"),
        ("NativeSafariPasswords.swift", "guard NSPasteboard.general.setString(text, forType: .string) else {", "the same Copy"),
        ("BackendAppDeviceOwnIOS.swift", "[\"simctl\", \"pbcopy\", udid]", "the simulator's own pasteboard; refused unless the typing is marked as his (BackendSimulatorPasteboard.typingForPerson) when Apple's Simulator app would copy it to his Mac"),
    ]
    var scanned = 0, unnamed: [String] = [], used = Set<Int>()
    for folder in ["TerminalDeckNative", "TerminalDeckBackend", "TerminalDeckNativeCore"] {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard NativeBackgroundToolsPolicy.isToolFile(file.lastPathComponent, source: source) else { continue }
            scanned += 1
            for (index, raw) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
                let code = raw.components(separatedBy: "//").first ?? raw
                guard !NativeBackgroundToolsPolicy.pasteboard(in: code).isEmpty else { continue }
                if let at = named.indices.first(where: { named[$0].0 == file.lastPathComponent && code.contains(named[$0].1) }) { used.insert(at); continue }
                unnamed.append(file.lastPathComponent + ":\(index + 1): " + trimmed)
            }
        }
    }
    #expect(scanned > 100)
    #expect(unnamed.isEmpty, Comment(rawValue: "Tool paths that reach a clipboard:\n" + unnamed.joined(separator: "\n")))
    #expect(used.count == named.count, "every named clipboard call is still there (else remove it here)")
    let ios = try String(contentsOf: root.appendingPathComponent("TerminalDeckBackend/BackendAppDeviceOwnIOS.swift"), encoding: .utf8)
    // MAC-NEXT-15c: refused by default; only his own marked typing (the panel from the app window, his phone) may use it.
    #expect(ios.contains("!BackendSimulatorPasteboard.typingForPerson, await Self.pasteboardReachesTheMac()"),
            "any typing not marked as his checks Simulator's sync before the pasteboard path")
    let channels = try String(contentsOf: root.appendingPathComponent("TerminalDeckBackend/BackendAppDeviceChannels.swift"), encoding: .utf8)
    #expect(channels.contains("$typingForPerson.withValue(Self.fromHisPanel(context))"), "the panel's typing is his only from the app's own window")
    let toolService = try String(contentsOf: root.appendingPathComponent("TerminalDeckBackend/BackendAppDeviceManager.swift"), encoding: .utf8)
    #expect(!toolService.contains("typingForPerson.withValue"), "the devices tools never mark their typing as his")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("TerminalDeckBackend/BackendMacClipboardGuard.swift").path),
            "no save-and-restore of his clipboard")
    let detect = try String(contentsOf: root.appendingPathComponent("TerminalDeckBackend/BackendSimulatorPasteboard.swift"), encoding: .utf8)
    #expect(NativeBackgroundToolsPolicy.pasteboard(in: detect.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined()).isEmpty,
            "finding out whether Simulator syncs never reads his clipboard")
}

/// MAC-NEXT-15: who answers what a page asks.
@Test func aToolsPageNeverAsksThePerson() {
    typealias Rule = BrowserPagePersonRule
    #expect(Rule.toolDriving(toolAt: 100, personAt: nil, now: 101))
    #expect(Rule.toolDriving(toolAt: 100, personAt: 99, now: 101))
    #expect(!Rule.toolDriving(toolAt: 100, personAt: 100.5, now: 101), "his click after the tool's: his page")
    #expect(!Rule.toolDriving(toolAt: 100, personAt: nil, now: 100 + Rule.toolWindowSeconds), "an AI's page from long ago is not driven now")
    #expect(!Rule.toolDriving(toolAt: nil, personAt: nil, now: 5))
    #expect(Rule.dialogRoute(standingAnswer: true, toolDriving: true, personOnPage: true, shownToPerson: true) == .standing)
    #expect(Rule.dialogRoute(standingAnswer: false, toolDriving: true, personOnPage: true, shownToPerson: true) == .tool)
    // MAC-NEXT-15b: his own page is never answered for him: shown when he is on it, held when he is not.
    #expect(Rule.dialogRoute(standingAnswer: false, toolDriving: false, personOnPage: true, shownToPerson: true) == .person)
    #expect(Rule.dialogRoute(standingAnswer: false, toolDriving: false, personOnPage: false, shownToPerson: true) == .hold)
    // MAC-NEXT-15c: an AI's page he has never been shown never holds a question, however long since the AI's last step.
    #expect(Rule.dialogRoute(standingAnswer: false, toolDriving: false, personOnPage: false, shownToPerson: false) == .tool)
    #expect(Rule.dialogRoute(standingAnswer: true, toolDriving: false, personOnPage: false, shownToPerson: false) == .standing)
    #expect(!Rule.fileChooserOpens(toolDriving: true, onScreen: true))
    #expect(!Rule.fileChooserOpens(toolDriving: false, onScreen: false))
    #expect(Rule.fileChooserOpens(toolDriving: false, onScreen: true))
    // Reads, screenshots and state are not driving; the driver's acting scripts are.
    #expect(Rule.actingScripts == ["scriptedInput", "domAction", "focusAndSelect", "select", "files"])
    #expect(!Rule.newTabShows(personAskedToShow: true, toolDriving: true))
    #expect(Rule.newTabShows(personAskedToShow: true, toolDriving: false))
}

/// MAC-NEXT-15c: an AI's free-form script (evaluate) can change the page, so it is driving; collect only reads rows
/// (its next-page click and scroll are acting scripts, marked in evaluate by their names).
@Test func onlyActingCommandsDriveAPage() throws {
    let root = sources()
    let automation = try String(contentsOf: root.appendingPathComponent("TerminalDeckNative/NativeSafariAutomation.swift"), encoding: .utf8)
    #expect(automation.contains("case \"evaluate\": drove(id); return try await evaluateCommand("))
    #expect(automation.contains("case \"collect\": return try await collectCommand("))
    #expect(!automation.contains("case \"collect\": drove(id)"))
    #expect(BrowserPagePersonRule.actingScripts.isSuperset(of: ["scriptedInput", "domAction"]), "collect's click and scroll still count")
    let runtime = try String(contentsOf: root.appendingPathComponent("TerminalDeckNative/NativeSafariRuntime.swift"), encoding: .utf8)
    #expect(runtime.contains("if BrowserPagePersonRule.actingScripts.contains(name) { drove(id) }"))
}

/// The two paths that explained "takes me there" and "makes me stay there" stay closed in the source itself.
@Test func theTwoReportedPathsStayClosed() throws {
    let root = sources()
    let engine = try String(contentsOf: root.appendingPathComponent("TerminalDeckNativeCore/BrowserDriverEngine.swift"), encoding: .utf8)
    #expect(!engine.contains("host.reveal("), "every browser_step click/type re-selected the tab")
    #expect(engine.contains("host.readyForInput(id)"))
    let menu = try String(contentsOf: root.appendingPathComponent("TerminalDeckNative/NativeFIXESDeviceContextMenu.swift"), encoding: .utf8)
    #expect(menu.contains("beside(entry, sessionID: sessionID, choosingTheSession: false)"), "devices_open_app chose the session")
    let runtime = try String(contentsOf: root.appendingPathComponent("TerminalDeckNative/NativeSafariRuntime.swift"), encoding: .utf8)
    #expect(!runtime.contains("tabs.reveal("))
}

/// The second round's three (13 Nov): ai_apps.create, and the downloads, passwords, screenshot and sign-in tools.
@Test func toolsHandBackPathsInsteadOfMovingThePerson() throws {
    let root = sources()
    func file(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
    let access = try file("TerminalDeckNative/NativeCompositionAccessTools.swift")
    #expect(!access.contains("requestSettings()"), "ai_apps.create opened Settings")
    let downloads = try file("TerminalDeckBackend/BackendBrowserDownloadsRPC.swift")
    // The person's own Downloads channel (browser-download:open/reveal) still opens and shows; the tool no longer does.
    #expect(!downloads.contains("(action == \"open\" ? downloads.open(id, context: context)"), "the download tool opened another app or showed Finder")
    #expect(downloads.contains(".init(\"path\", .string(row.path))"))
    let profiles = try file("TerminalDeckBackend/BackendBrowserProfilesChannels.swift")
    #expect(!profiles.contains("case \"reveal\": guard try await passwords.reveal()"), "browser.passwords reveal showed Finder")
    #expect(profiles.components(separatedBy: "signIn.handover(").count == 2, "only the sign-in band's channel opens the system browser")
    let service = try file("TerminalDeckBackend/BackendBrowserService.swift")
    #expect(service.contains("return try await screenshotPlace(context"), "browser_page reveal showed Finder")
    let fork = try file("TerminalDeckNative/NativeChatFork.swift")
    #expect(fork.contains("if chooseForPerson { AppModel.shared.select(id) }"), "sessions_chat_fork chose the new chat")
}

@Test func theScanSeesACallAndItsMarkers() {
    #expect(NativeBackgroundToolsPolicy.navigation(in: "AppModel.shared.selectTab(sessionID)") == ["selectTab("])
    #expect(NativeBackgroundToolsPolicy.navigation(in: "window.makeFirstResponder(view)") == ["makeFirstResponder("])
    #expect(!NativeBackgroundToolsPolicy.navigation(in: "NSApp.activate(ignoringOtherApps: true)").isEmpty)
    #expect(NativeBackgroundToolsPolicy.navigation(in: "_ = await host.readyForInput(id)").isEmpty)
    #expect(NativeBackgroundToolsPolicy.isToolPath("NativeSafariRuntime.swift"))
    #expect(NativeBackgroundToolsPolicy.isToolPath("BackendANDROIDPhoneOpenApp.swift"))
    #expect(!NativeBackgroundToolsPolicy.isToolPath("SidebarView.swift"))
}

@Test func theRowCarriesOnlyQuietMarks() {
    typealias P = NativeBackgroundToolsPolicy
    #expect(P.marks(phone: false, browser: false, handover: false).isEmpty)
    #expect(P.marks(phone: true, browser: false, handover: false) == [.phone])
    #expect(P.marks(phone: true, browser: true, handover: false) == [.phone, .browser])
    #expect(P.marks(phone: false, browser: true, handover: true) == [.handover], "the hand replaces the globe")
    #expect(P.Mark.handover.symbol == "hand.raised.fill", "the row's existing needs-you glyph (StatusMark)")
}

/// MAC-NEXT-13 B3: only a page an AI opened in the background (never in one of his windows) goes quiet when parked.
@Test func onlyAnAIsBackgroundPageGoesQuiet() {
    typealias P = NativeBackgroundToolsPolicy
    #expect(P.silencesParkedPage(shownToPerson: false, inWindow: false))
    #expect(!P.silencesParkedPage(shownToPerson: true, inWindow: false), "a page he left playing in another tab keeps its sound")
    #expect(!P.silencesParkedPage(shownToPerson: true, inWindow: true) && !P.silencesParkedPage(shownToPerson: false, inWindow: true))
}

/// MAC-NEXT-13 B1/B2: the row opens the session as always; the hand is its own click; a folded group and an
/// out-of-sight Hoot line still carry the hand.
@Test func theRowOpensTheSessionAndTheHandOpensThePage() throws {
    let root = sources()
    let sidebar = try String(contentsOf: root.appendingPathComponent("TerminalDeckNative/SidebarView.swift"), encoding: .utf8)
    #expect(sidebar.contains("open: { choose(session.id) },"))
    #expect(!sidebar.contains("NativeWaitingPages.page(forSession: session.id) { NativeWaitingPages.open"), "the row no longer opens the page")
    #expect(sidebar.contains("Button { choose(item.id) } label:"), "Hoot's line opens Hoot; its hand opens the page")
    #expect(sidebar.contains("onScrollVisibilityChange") && sidebar.contains("SIDEBARWaitingLine(page: page)"))
    let archived = try String(contentsOf: root.appendingPathComponent("TerminalDeckNative/NativeChatOrganization.swift"), encoding: .utf8)
    #expect(archived.contains("if let waiting { SIDEBARWaitingHand(page: waiting) }"), "the folded Archived chats header carries the hand")
}
