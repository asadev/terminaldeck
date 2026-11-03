import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// U36: the app frame's small bugs stay fixed (review items in each test's name comment).
@MainActor
final class AppFrameSmallBugsTests: XCTestCase {
    private func source(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/" + file), encoding: .utf8)
    }
    private func slice(_ text: String, from start: String, to end: String) throws -> Substring {
        let a = try XCTUnwrap(text.range(of: start), start)
        let b = try XCTUnwrap(text.range(of: end, range: a.upperBound..<text.endIndex), end)
        return text[a.lowerBound..<b.lowerBound]
    }

    /// #77: "Add a server…" / "Pair a device…" survive the several detail builds of one pass.
    func testSidePanelActionIsReadNotTakenUntilAnotherPlaceIsChosen() {
        XCTAssertEqual(SHELLRoutes.resolve("servers:add"), SHELLRoutes.servers)
        XCTAssertTrue(SHELLRoutes.asked("servers:add"))
        XCTAssertTrue(SHELLRoutes.asked("servers:add"), "a second build still draws the Add form")
        XCTAssertEqual(SHELLRoutes.resolve(SHELLRoutes.servers), SHELLRoutes.servers)
        XCTAssertTrue(SHELLRoutes.asked("servers:add"), "its own place chosen again keeps the action")
        // Since 30 Oct (f81f0a68) Devices is its own window: "devices:pair" asks AppModel to open it and is never a page
        // selection. Not called here: AppModel cannot start inside the test process (no app bundle).
        XCTAssertEqual(SHELLRoutes.resolve("hoot"), "hoot")
        XCTAssertFalse(SHELLRoutes.asked("servers:add"), "choosing another place ends the action")
    }

    /// #595, #657: Report an Issue goes somewhere a problem can be reported.
    func testReportAnIssueOpensTheSupportPage() throws {
        let item = try XCTUnwrap(AppCommandCatalog.all.first { $0.title == "Report an Issue" })
        XCTAssertEqual(item.action, .openURL("https://terminaldeck.dev/support.html"))
    }

    /// #19: a mistyped plugin action is refused, never read as "remove".
    func testUnknownPluginActionIsRefused() throws {
        let tool = try slice(try source("TerminalDeckNative/NativeCompositionAccessTools.swift"), from: "case \"plugins.manage\":", to: "default:\n                    let on")
        XCTAssertTrue(tool.contains("guard let verb = verbs[action] else { throw NativeRPCError.invalidArguments"))
        XCTAssertFalse(tool.contains(": \"Turn off\")"))
    }

    /// #71: the login row is asked for once the default AI is known.
    func testNewSessionResolvesTheLoginAfterTheDefaultAIArrives() throws {
        let load = try slice(try source("TerminalDeckNative/NativeNewSessionDialog.swift"), from: "    func load() {", to: "    private func loadNativeContext()")
        let provider = try XCTUnwrap(load.range(of: "defaultProvider = NewSessionProviders.isProviderId"))
        let resolve = try XCTUnwrap(load.range(of: "resolveDefaultProfile()"))
        XCTAssertLessThan(provider.lowerBound, resolve.lowerBound)
        XCTAssertEqual(load.components(separatedBy: "resolveDefaultProfile()").count, 2, "asked once, not also before the read")
    }

    /// #104, #644: Siri reads the default AI from settings' values and starts every agent the same way, as a tab.
    func testSiriStartsEveryAgentAsATabAndKnowsTheDefault() throws {
        XCTAssertTrue(try source("TerminalDeckNative/IntentsEngine.swift").contains("(settings[\"values\"] as? [String: Any])?[\"general.defaultProvider\"]"))
        let start = try slice(try source("TerminalDeckNative/IntentsActions.swift"), from: "struct StartSessionIntent", to: "// MARK: - Open a project")
        XCTAssertFalse(start.contains("openScreenWindow"))
        XCTAssertFalse(start.contains("model.newSession(in:"))
        XCTAssertTrue(start.contains("model.selectTab(id)"))
    }

    /// #131: the island's Quit closes sheets first, like every other quit.
    func testIslandQuitGoesThroughNativeQuit() throws {
        let hoot = try source("TerminalDeckNative/NativeCompositionHootUI.swift")
        XCTAssertTrue(hoot.contains("quit: { NativeQuit.terminate(\"Hoot's Quit\") }"))
        XCTAssertFalse(hoot.contains("NSApp.terminate(nil)"))
    }

    /// #132: only pages that really reopen are booked as moved to their own window.
    func testRestoreBooksOnlyPagesThatReopen() throws {
        let take = try slice(try source("TerminalDeckNative/AppModel.swift"), from: "func takeScreensToRestore()", to: "func knownSymbol")
        let filter = try XCTUnwrap(take.range(of: "UIGMemoryVisibility.restoredScreens(screensToRestore)"))
        let booked = try XCTUnwrap(take.range(of: "NativePageWindows.shared.requested(ref)"))
        XCTAssertLessThan(filter.lowerBound, booked.lowerBound)
        XCTAssertTrue(take.contains("for ref in restored where"))
    }

    /// #133: the import sheet's folder picker never shares the main window's parked key.
    func testImportFolderPickerHasItsOwnKey() throws {
        let add = try slice(try source("TerminalDeckNative/AGFRAMEImport.swift"), from: "func addFolder()", to: "func createProject(")
        XCTAssertFalse(add.contains("whenPersonActs(\"main\")"))
        XCTAssertTrue(add.contains("whenPersonActs(\"agents-import-folder\")"))
    }

    /// #137: an unreadable project list leaves the Add server form usable with the built-in projects.
    func testAddServerFallsBackToBuiltInProjects() throws {
        let page = try source("TerminalDeckNative/NativeAddServerPage.swift")
        let fallback = try slice(page, from: "private func offerBuiltInProjects()", to: "private func field<")
        XCTAssertTrue(fallback.contains("projectsReady = true"))
        XCTAssertFalse(page.contains("Open this form again to retry"))
    }

    /// #158: Choose logo… picks an image; a refused Stop or folder add is said.
    func testSidePanelLogoAndRefusals() throws {
        let side = try source("TerminalDeckNative/SidebarView.swift")
        XCTAssertFalse(side.contains("Button(\"Choose logo…\") { choose(id + \":settings\") }"))
        XCTAssertTrue(side.contains("store.changeLogo(url, project: project)"))
        XCTAssertFalse(side.contains("try? await EngineBridge.shared.invoke(\"session:kill\""))
        XCTAssertFalse(side.contains("try? await EngineBridge.shared.invoke(\"projects:add\""))
        XCTAssertTrue(side.contains("AppModel.shared.buttonActions.problem = failure"))
    }

    /// #172: one status dot: the pop-out bar and panes draw the side panel's own.
    func testOneSessionStatusDot() throws {
        let dot = try slice(try source("TerminalDeckNative/NativeSessionHeader.swift"), from: "struct NativeSessionStatusDot", to: "struct NativeSessionTitle")
        XCTAssertTrue(dot.contains("SessionStatusDot(status: status.rawValue"))
        XCTAssertFalse(dot.contains("phaseAnimator"))
    }

    /// #463: an approval banner clicked while the app runs in the background brings its windows back.
    func testApprovalBannerReopensTheBackgroundApp() throws {
        let attention = try source("TerminalDeckNative/NativeOwnerAttention.swift")
        XCTAssertTrue(attention.contains("NativeSVResident.shared.reopen()"))
        XCTAssertTrue(attention.contains("NativeLaunchWindow.ensureShown(front: true)"))
    }

    /// #623: help that cannot be read says so, with Try again, instead of spinning for ever.
    func testHelpPanelSaysWhenTheWordsCannotBeRead() throws {
        let help = try source("TerminalDeckNative/NativeHelpPanel.swift")
        XCTAssertTrue(help.contains("NativePageNote(\"The help could not be read.\")"))
        XCTAssertTrue(help.contains("unreadable = content == nil"))
    }

    /// #627: the project guide never picks a task source by itself.
    func testGuideAdoptsOnlyASystemThePersonConnected() throws {
        let guide = try source("TerminalDeckNative/PROJGuideView.swift")
        XCTAssertTrue(guide.contains("if connectingTaskSystem, let added = ids.first(where: { !taskSystemsBefore.contains($0) })"))
        XCTAssertFalse(guide.contains("|| model.taskSystem.isEmpty {"))
    }

    /// #648: a good read clears the keys' read error.
    func testAiAppsReadErrorClearsOnAGoodRead() throws {
        let load = try slice(try source("TerminalDeckNative/NativeAiAppsSettings.swift"), from: "    func load() {", to: "    func setInternet(")
        XCTAssertTrue(load.contains("else if readFailed { problem = nil; readFailed = false }"))
    }
}
