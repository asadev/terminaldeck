import Foundation
import SwiftUI
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// L5 slice 1: the Code page (pictures in light and dark, wide and narrow, with every state) and its read tool.
@MainActor
final class CodeBackupPageTests: XCTestCase {
    typealias P = BackendCodeBackupProject
    nonisolated static let now = Date()
    nonisolated static func ago(_ minutes: Double) -> Int64 { Int64((now.timeIntervalSince1970 - minutes * 60) * 1000) }

    nonisolated static func fixture(signedIn: Bool = true) -> BackendCodeBackupReport {
        var deck = P(id: "p1", name: "Terminal Deck"); deck.hasFolder = true; deck.isRepository = true; deck.folderName = "td-native-shell"
        deck.home = "fixture-owner/terminal-deck"; deck.visibility = signedIn ? .isPrivate : .notChecked; deck.branch = "lane/code-page"
        deck.lastCommitAt = ago(35); deck.lastBackedUpAt = ago(26 * 60)
        deck.commitCount = 2; deck.commits = [.init(subject: "Code page: first slice", at: ago(35)), .init(subject: "Read-only Git reader", at: ago(90))]
        deck.changedCount = 3; deck.changedFiles = ["macos/Sources/NativeCodeBackupPage.swift", "README.md", "notes/plan.md"]
        deck.held = [.init(name: ".env", reason: .looksSecret)]
        var site = P(id: "p2", name: "Website"); site.hasFolder = true; site.isRepository = true; site.folderName = "terminaldeck-site"
        site.home = "fixture-owner/terminaldeck-site"; site.visibility = signedIn ? .isPublic : .notChecked; site.branch = "main"
        site.lastCommitAt = ago(80); site.lastBackedUpAt = ago(80); site.changedCount = 3; site.changedFiles = ["index.html", "styles.css", "docs/new.md"]
        var recipes = P(id: "p3", name: "Recipes"); recipes.hasFolder = true; recipes.isRepository = true; recipes.folderName = "recipes"; recipes.branch = "main"
        var old = P(id: "p4", name: "Old App"); old.hasFolder = true; old.folderName = "old-app"; old.problem = "the folder took too long to read"
        var tools = P(id: "p5", name: "Deck Tools"); tools.hasFolder = true; tools.isRepository = true; tools.folderName = "deck-tools"
        tools.home = "fixture-owner/deck-tools"; tools.visibility = signedIn ? .isPrivate : .notChecked; tools.branch = "main"
        tools.lastCommitAt = ago(3 * 24 * 60); tools.lastBackedUpAt = ago(3 * 24 * 60); tools.held = [.init(name: "media/demo.mov", reason: .tooLarge)]
        var clean = P(id: "p6", name: "Hoot Notes"); clean.hasFolder = true; clean.isRepository = true; clean.folderName = "hoot-notes"
        clean.home = "fixture-owner/hoot-notes"; clean.visibility = signedIn ? .isPrivate : .notChecked; clean.branch = "main"
        clean.lastCommitAt = ago(10); clean.lastBackedUpAt = ago(10)
        let notes = P(id: "p7", name: "Ideas")
        var api = P(id: "api", name: "Shop"); api.hasFolder = true; api.isRepository = true; api.folderName = "shop-api"
        api.home = "fixture-owner/shop-api"; api.branch = "main"; api.lastCommitAt = ago(300); api.lastBackedUpAt = ago(300)
        var app = api; app.id = "app"; app.folderName = "shop-app"; app.home = "fixture-owner/shop-app"; app.setAsideCount = 1
        var shop = P.combine(id: "p8", name: "Shop", parts: [api, app])
        // Slice 2: the backup choice on each row, one action where something is not on GitHub, Get the code elsewhere.
        deck.mode = .automatic; clean.mode = .automatic; tools.mode = .automatic; shop.mode = .manual; site.mode = .off
        deck.note = "Not backed up: Git is in the middle of a merge"
        var blog = P(id: "p9", name: "Blog"); blog.hasFolder = true; blog.folderName = "Blog"; blog.waitingForCode = true
        blog.getFrom = "fixture-owner/blog"
        return BackendCodeBackupReport(projects: [notes, clean, tools, old, recipes, site, deck, shop, blog], signedInToGitHub: signedIn, checkedAt: ago(0))
    }

    func testThePageInLightAndDarkWideAndNarrow() throws {
        let dir = ProcessInfo.processInfo.environment["TD_CODE_PAGE_FRAMES"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("code-page.noindex").path
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [false, true] {
            let name = dark ? "dark" : "light"
            try MACHINESHiddenRender.render(NativeCodeBackupPage(model: .init(fixture: Self.fixture(), opened: ["p1", "p8"], now: Self.now)), dark: dark,
                size: CGSize(width: 900, height: 1040), to: out.appendingPathComponent("MACHINES-code-page-\(name).png"))
            try MACHINESHiddenRender.render(NativeCodeBackupPage(model: .init(fixture: Self.fixture(signedIn: false), opened: ["p5"], now: Self.now)), dark: dark,
                size: CGSize(width: 520, height: 760), to: out.appendingPathComponent("MACHINES-code-page-narrow-signed-out-\(name).png"))
        }
        print("Code page pictures: \(out.path)")
    }

    func testThePageIsBesideProjects() {
        XCTAssertTrue(SHELLRoutes.owns(Sidebar21Pages.codeID))
        XCTAssertNotNil(SHELLRoutes.detail(kind: "panel", id: Sidebar21Pages.codeID))
        let ids = Sidebar21Pages.standard.map(\.id)
        XCTAssertEqual(ids.firstIndex(of: Sidebar21Pages.codeID), ids.firstIndex(of: Sidebar21Pages.projectsID).map { $0 + 1 })
    }

    func access() -> BackendDeckToolsAppAccess {
        BackendDeckToolsAppAccess(caller: { _ in .init(kind: .local) }, knownFolder: { _, path in path },
            session: { _, _ in .null }, runnableProject: { _, path in path },
            rpc: { _ in .init(caller: .nativeApp, ownerID: "code-page-fixture") },
            authorize: { _, _, _, tier, _, _ in XCTAssertEqual(tier, .read) }, record: { _, _, _, _ in })
    }
    func context(_ tool: String) -> BackendMCPCallContext {
        .init(sessionID: "code-fixture", machineID: "", projectRoot: nil, attended: true, allowedTools: [tool], allowedTiers: [.read], cancellation: .init())
    }
    func reply(_ value: BackendMCPToolReply) throws -> NativeRPCValue {
        try NativeRPCValue.parseJSON(Data((value.content.first?["text"].string ?? "null").utf8))
    }

    /// Slice 2: every action asks the owner first with a line naming the project and the GitHub address.
    func testTheActionToolsAskTheOwnerNamingProjectAndAddress() async throws {
        actor Lines { var said: [String] = []; var done: [String] = []; func add(_ line: String) { said.append(line) }; func did(_ what: String) { done.append(what) } }
        let lines = Lines()
        let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: .local) }, knownFolder: { _, path in path },
            session: { _, _ in .null }, runnableProject: { _, path in path },
            rpc: { _ in .init(caller: .nativeApp, ownerID: "code-page-fixture") },
            authorize: { _, _, _, tier, sentence, ask in XCTAssertEqual(tier, .alter); XCTAssertTrue(ask); await lines.add(sentence) }, record: { _, _, _, _ in })
        let act = BackendCodeBackupTools.Act(signedIn: { true }, target: { name in
            name == "Website" ? BackendCodeBackupActions.Target(projectID: "p2", name: "Website", address: "github.com/fixture-owner/terminaldeck-site", newHome: false, folder: "~/Code/site")
            : name == "Recipes" ? BackendCodeBackupActions.Target(projectID: "p3", name: "Recipes", address: "github.com/fixture-owner/recipes", newHome: true, folder: nil) : nil
        }, backUp: { id in await lines.did("backup " + id); return BackendCodeBackupActions.Outcome(ok: true, line: "Backed up to github.com/fixture-owner/x") },
           getCode: { id in await lines.did("get " + id); return BackendCodeBackupActions.Outcome(ok: true, line: "Code is here · branch main") },
           setMode: { id, mode in await lines.did("mode \(id) \(mode.rawValue)") })
        let tools = try BackendCodeBackupTools.definitions(access: access, read: { _ in Self.fixture() }, act: act)
        XCTAssertEqual(tools.map(\.spec.wireName), ["code_projects", "code_backup_now", "code_get_code", "code_set_mode"])
        func call(_ wire: String, _ args: NativeRPCValue) async throws -> BackendMCPToolReply {
            let tool = try XCTUnwrap(tools.first { $0.spec.wireName == wire })
            return try await tool.handler(.init(sessionID: "code-fixture", machineID: "", projectRoot: nil, attended: true, allowedTools: [tool.spec.id],
                                                allowedTiers: [.alter], cancellation: .init()), args)
        }
        _ = try await call("code_backup_now", .object([.init("project", .string("Website"))]))
        _ = try await call("code_backup_now", .object([.init("project", .string("Recipes"))]))
        _ = try await call("code_get_code", .object([.init("project", .string("Website"))]))
        _ = try await call("code_set_mode", .object([.init("project", .string("Website")), .init("mode", .string("off"))]))
        let missing = try await call("code_backup_now", .object([.init("project", .string("Nope"))]))
        XCTAssertTrue(missing.isError)
        let said = await lines.said, done = await lines.done
        XCTAssertEqual(said, [
            "Back up “Website” to github.com/fixture-owner/terminaldeck-site (adds only; nothing on GitHub is changed or removed)",
            "Back up “Recipes”: make a new private home github.com/fixture-owner/recipes on your GitHub account and send its code there (adds only)",
            "Get the code of “Website” from github.com/fixture-owner/terminaldeck-site into ~/Code/site",
            "Set the backup of “Website” to Off (github.com/fixture-owner/terminaldeck-site)",
        ])
        XCTAssertEqual(done, ["backup p2", "backup p3", "get p2", "mode p2 off"])
    }

    func testTheToolAnswersThePagesRowsAndOnlyReads() async throws {
        actor Asked { var refresh: [Bool] = []; func note(_ value: Bool) { refresh.append(value) } }
        let asked = Asked()
        let tool = try XCTUnwrap(try BackendCodeBackupTools.definitions(access: access(), read: { refresh in
            await asked.note(refresh); return Self.fixture() }).first)
        XCTAssertEqual(tool.spec.id, "code.projects"); XCTAssertEqual(tool.spec.wireName, "code_projects"); XCTAssertEqual(tool.spec.tier, .read)
        let all = try reply(await tool.handler(context("code.projects"), .object([])))
        let rows = all["projects"].elements ?? []
        XCTAssertEqual(rows.first?["name"].string, "Terminal Deck", "what needs attention first, as on the page")
        XCTAssertEqual(rows.first?["summary"].string, "2 commits not on GitHub · 3 files changed since " + BackendCodeBackupWords.short(Self.ago(35), now: Date()) + " · 1 secret file not sent to GitHub")
        XCTAssertEqual(rows.first?["visibility"].string, "private")
        XCTAssertEqual(rows.first?["commitsNotOnGitHub"]["count"].number, 2)
        XCTAssertEqual(rows.first { $0["name"].string == "Ideas" }?["summary"].string, "No code folder on this Mac")
        XCTAssertEqual(rows.first { $0["name"].string == "Old App" }?["summary"].string, "Could not check (the folder took too long to read)")
        XCTAssertEqual(rows.first { $0["name"].string == "Recipes" }?["summary"].string, "Not on GitHub yet")
        let shop = try XCTUnwrap(rows.first { $0["name"].string == "Shop" })
        XCTAssertEqual(shop["summary"].string, "shop-app: 1 set-aside change not on GitHub")
        XCTAssertEqual(shop["backup"].string, "manual")
        XCTAssertEqual(rows.first { $0["name"].string == "Website" }?["summary"].string, "Backup off · 3 files changed since " + BackendCodeBackupWords.short(Self.ago(80), now: Date()))
        XCTAssertEqual(rows.first { $0["name"].string == "Blog" }?["getCodeFrom"].string, "fixture-owner/blog")
        XCTAssertEqual(shop["folders"].elements?.count, 2)
        let text = String(decoding: try all.encodedJSON(), as: UTF8.self)
        XCTAssertFalse(text.contains("\"p1\""), "no project ids")
        let one = try reply(await tool.handler(context("code.projects"), .object([.init("project", .string("website")), .init("refresh", .bool(true))])))
        XCTAssertEqual(one["projects"].elements?.map { $0["name"].string ?? "" }, ["Website"])
        let refreshes = await asked.refresh
        XCTAssertEqual(refreshes, [false, true])
        let missing = try await tool.handler(context("code.projects"), .object([.init("project", .string("Nope"))]))
        XCTAssertTrue(missing.isError)
        let refused = try await tool.handler(context("devices.page"), .object([]))
        XCTAssertTrue(refused.isError, "a caller without the tool is refused")
    }
}
