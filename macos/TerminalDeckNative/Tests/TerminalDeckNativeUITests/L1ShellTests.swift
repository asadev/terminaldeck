import AppKit
import SwiftUI
import Testing
import ScreenCaptureKit
import WebKit
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// L1-SHELL: shared page wrapper, fixed frame shade, native-only places, and offscreen
/// light/dark renders (NSHostingView + cacheDisplay only; no window, no app launch).
@Suite("L1 shell", .serialized)
@MainActor
struct L1ShellTests {
    /// #95: the side panel and tab bar keep one shade whichever page is on show.
    @Test func frameShadeNeverFollowsThePage() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var terminal: NSColor?, page: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                terminal = NativeChrome.frameNS(paper: true).usingColorSpace(.sRGB)
                page = NativeChrome.frameNS(paper: false).usingColorSpace(.sRGB)
            }
            #expect(terminal != nil && terminal == page)
        }
    }

    /// #95/#91: no page content can raise the window's minimum height.
    @Test func pageContentNeverGrowsTheWindow() {
        let tall = VStack(spacing: 0) {
            ForEach(0..<300, id: \.self) { Text("Row \($0)").frame(height: 30) }
        }.fixedSize(horizontal: false, vertical: true)
        let root = NSHostingView(rootView: DeckPage(deckContent: AnyView(tall)))
        root.sizingOptions = [.minSize]
        #expect(root.fittingSize.height < 100, "bounded root min height \(root.fittingSize.height)")
        let page = NSHostingView(rootView: DeckPage(title: "Dummy", subtitle: "Tall content") { tall })
        page.sizingOptions = [.minSize]
        #expect(page.fittingSize.height < 200, "DeckPage min height \(page.fittingSize.height)")
    }

    /// Real-app test 11 Oct, item 13: the page-level project filter showed plain text. macOS 27
    /// hides a menu's pictures unless each row asks to keep its own, so every pictured row must ask.
    @Test func theProjectFilterMenuKeepsItsPictures() {
        let projects = [PROJProject(id: "imatch", name: "iMatch", folders: ["/scratch/iMatch"], colour: "blue"),
                        PROJProject(id: "crm", name: "CRM", folders: ["/scratch/CRM"], colour: "purple")]
        var chosen: [String?] = []
        let menu = ProjectPicker.menu(projects: projects, selection: "crm", choose: { chosen.append($0) }, openProject: {})
        let rows = menu.items.filter { !$0.isSeparatorItem }
        #expect(rows.map(\.title) == ["All projects", "iMatch", "CRM", "Independent", "New project…"])
        #expect(rows.dropLast().allSatisfy { $0.image != nil && $0.deckPictureKept })
        #expect(rows.last?.image == nil)
        #expect(rows.filter { $0.state == .on }.map(\.title) == ["CRM"])
        // Choosing still works: each row runs its own choice.
        for row in rows.dropLast() {
            if let target = row.target as? NSObject, let action = row.action { _ = target.perform(action, with: row) }
        }
        #expect(chosen == [nil, "imatch", "crm", PROJProjects.independentID])
    }

    /// Asad, 11 Oct (his real app): "@" in a task's comment box, click an agent, and nothing is
    /// mentioned; the box still reads "@…". The same message box serves Hoot's chat. A pick (a click,
    /// or Return / Tab on the highlighted row: both call the box's one insert) must put the mention
    /// over the "@…" being typed, in the box AND in the draft behind it, for both kinds of draft:
    /// the task comment box keeps its draft in the view itself, Hoot's chat keeps it in its model.
    @Test func aPickedMentionGoesIntoTheTaskCommentDraftAndIntoHootsDraft() throws {
        let critic = HootMention(id: "critic", kind: .agent, name: "critic", project: "Memory Test")
        let hoot = L1MentionDraftModel()
        let task = L1MentionDraftSeen()
        let boxes: [(String, NSView, () -> Binding<HootComposerDraft>?)] = [
            ("Hoot's box", NSHostingView(rootView: L1HootDraftBox(model: hoot)), { Bindable(hoot).draft }),
            ("a task's comment box", NSHostingView(rootView: L1TaskDraftBox(seen: task)), { task.binding }),
        ]
        for (name, host, bindingOf) in boxes {
            // Never ordered in: nothing is shown.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 220), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded(); Self.spin(0.3)
            let draft = try #require(bindingOf(), "\(name): no draft")
            let box = try #require(Self.textViews(in: host).first, "\(name): no message box")
            #expect(box.string == "ask @cri", "\(name) starts with what was typed")
            box.setSelectedRange(NSRange(location: (box.string as NSString).length, length: 0))
            // What the list does for a pick: the box's own insert, over the "@…" before the caret.
            let editor = HootComposerEditorHandle()
            editor.textView = box
            editor.insert(critic, draft: draft, replaceQuery: true)
            Self.spin(0.3)
            #expect(draft.wrappedValue.text == "ask " + critic.marker, "\(name): the draft holds the mention where \"@cri\" was")
            #expect(draft.wrappedValue.mentions == [critic], "\(name): the draft knows who was mentioned")
            #expect(box.string == "ask \u{FFFC}", "\(name): the box shows the mention, not \"@cri\"")
            #expect(draft.wrappedValue.wire["mentions"].elements?.count == 1, "\(name): the mention is sent with the message")
            withExtendedLifetime(window) {}
        }
        // The comment box's own "Mention someone" (@) button: an "@" typed at the caret THROUGH the
        // box, so the box's own change notice runs (that notice is what opens the @ list when the
        // person types "@"); a space first when it would stick to the word before it.
        for (text, caret, wanted) in [("ask critic", 3, "ask @ critic"), ("", 0, "@"), ("hi ", 3, "hi @")] {
            let box = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
            box.string = text
            box.setSelectedRange(NSRange(location: caret, length: 0))
            let heard = L1TextChangeListener()
            box.delegate = heard
            let editor = HootComposerEditorHandle()
            editor.textView = box
            editor.typeMentionSign()
            #expect(box.string == wanted, "the button types the @ where the caret is")
            #expect(heard.changes == 1, "the box's own change notice ran once, as for a typed @")
            let caretNow = box.selectedRange().location
            #expect((box.string as NSString).substring(to: caretNow).hasSuffix("@"), "the caret sits right after the @, where the list filters from")
        }
    }

    /// Real-app test 11 Oct, items 32 / 53: "Who uses what" was never on the Settings page. One picture of
    /// it as the page draws it, and one with an older background helper (read-only, with the reason).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["L1_RENDER_OUT"] != nil))
    func whoUsesWhatIsDrawnAlsoWithAnOlderHelper() async throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["L1_RENDER_OUT"] ?? "")
        var mac = CodingAIAccount(id: "system", name: "you@example.com"); mac.provider = "claude"; mac.system = true
        var work = CodingAIAccount(id: "work", name: "Work"); work.provider = "claude"
        var side = CodingAIAccount(id: "side", name: "Side"); side.provider = "claude"
        let imatch = PROJProject(id: "imatch", name: "iMatch", folders: ["/scratch/iMatch"], colour: "blue")
        let rows = [
            NativeAccountLevelRow(id: "app", kind: .app, title: "Whole Terminal Deck", levels: [["kind": "app"]]),
            NativeAccountLevelRow(id: "seat:orchestrator", kind: .hoot, title: "Hoot", detail: "Every project", levels: [["kind": "seat", "key": "orchestrator"]]),
            NativeAccountLevelRow(id: "project:imatch", kind: .project, title: "iMatch", project: imatch, levels: [["kind": "project", "path": "/scratch/iMatch"]]),
            NativeAccountLevelRow(id: "seat:role:imatch/builder", kind: .role, title: "Builder", detail: "×2", project: imatch, levels: [["kind": "seat", "key": "role:imatch/builder"]]),
        ]
        for older in [false, true] {
            NativeAccountLevelsModel.shared.setFixture(app: ["claude": "work"], projects: ["/scratch/iMatch": ["claude": "side"]], seats: [:],
                                                       sessions: [], usage: [:], olderHelper: older)
            #expect(NativeAccountLevelsModel.shared.olderHelper == older)
            let view = Form { NativeAccountLevelsSection(accounts: [mac, work, side], fixtureRows: rows) }.formStyle(.grouped)
            try await Self.render(AnyView(view), size: CGSize(width: 680, height: 430), appearance: .aqua,
                                  to: out.appendingPathComponent("L1-accounts-table-" + (older ? "older-helper" : "normal") + ".png"))
        }
    }

    /// Real-app test 11 Oct: "@…helpers" took the real agent "matchmaker" (its DESCRIPTION says "helpers")
    /// ahead of the agent NAMED "MT Helper", and a space after "@MT" closed the list so Return sent.
    @Test func theMentionListRanksNamesFirstAndStaysOpenAcrossASpaceInAName() {
        func agent(_ id: String, _ name: String, _ about: String) -> DeckMentionRow {
            DeckMentionRow(mention: HootMention(id: id, kind: .agent, name: name), section: .agents,
                           picture: .symbol("person.crop.circle"), title: name, detail: about)
        }
        let rows = [agent("matchmaker", "matchmaker", "CRM · pairs buyers with helpers and listings"),
                    agent("xhelper", "Rehelper", "CRM · an old one"),
                    agent("mt-builder", "MT Builder", "Memory Test · Builder"),
                    agent("mt-helper", "MT Helper", "Memory Test · Helper"),
                    agent("helper-bot", "Helper Bot", "Independent · Agent"),
                    DeckMentionRow(mention: HootMention(id: "s1", kind: .session, name: "helper notes"), section: .sessions,
                                   picture: .symbol("terminal"), title: "helper notes", detail: "iMatch · Session")]
        func names(_ query: String) -> [String] { DeckMentionRows.ranked(rows, query: query).map(\.title) }
        // Name starts with it, then a word of the name starts with it, then the name contains it, and only
        // then a description; inside a group the list's own order.
        #expect(names("help") == ["Helper Bot", "helper notes", "MT Helper", "Rehelper", "matchmaker"])
        #expect(names("helpers") == ["matchmaker"])                    // only the description has the "s"
        #expect(names("MT helper") == ["MT Helper"])                   // the name wins; the description match is not even in it
        #expect(names("mt") == ["MT Builder", "MT Helper"])
        #expect(names("MT ") == ["MT Builder", "MT Helper"])           // the space alone does not empty the list
        #expect(names("mt hel") == ["MT Helper"])
        #expect(names("zzz").isEmpty)
        #expect(names("").count == rows.count)
        #expect(DeckMentionRows.ranked(rows, query: "help").first?.mention.id == "helper-bot")   // what Return takes

        // What counts as still asking for the list.
        let known = { rows.map(\.title) }
        func open(_ typed: String) -> String? { DeckMentionQuery.open(before: typed, names: known) }
        #expect(open("ask @MT") == "MT")
        #expect(open("ask @MT ") == "MT ")
        #expect(open("ask @MT Hel") == "MT Hel")
        #expect(open("ask @MT Helper") == "MT Helper")
        #expect(open("ask @MT Helper ") == nil)                        // past the name: the list closes
        #expect(open("ask @MT helpers") == nil)                        // no NAME holds that
        #expect(open("ask @ MT") == nil)
        #expect(open("ask @MT\nHel") == nil)
        #expect(open("ask MT") == nil)
        #expect(open("@") == "")
    }

    static func textViews(in view: NSView) -> [NSTextView] {
        ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(textViews)
    }

    /// #107: the new side-panel places stay native; action ids open the place, never select themselves.
    @Test func nativeOnlyPlaces() {
        #expect(SHELLRoutes.owns("servers"))
        #expect(!SHELLRoutes.owns("devices")) // Devices opens its own window (lane/devices-window), never a side-panel place
        #expect(SHELLRoutes.owns("project:/scratch/iMatch"))
        #expect(!SHELLRoutes.owns("project:/scratch/iMatch:settings"))
        #expect(!SHELLRoutes.owns("project:"))
        #expect(!SHELLRoutes.owns("tasks"))
        #expect(SHELLRoutes.resolve("servers:add") == "servers")
        // "devices:pair" now asks AppModel.shared for the Devices window; AppModel cannot start inside a test bundle.
        #expect(SHELLRoutes.resolve("tasks") == "tasks")
        #expect(AppModel.nativeOnly("receiver"))
        #expect(AppModel.nativeOnly("agents-org"))
        #expect(AppModel.nativeOnly("servers"))
        #expect(AppModel.nativeOnly("project:/scratch/CRM"))
        #expect(!AppModel.nativeOnly("tasks"))
        #expect(!AppModel.nativeOnly(nil))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["L1_RENDER_OUT"] != nil))
    func lightAndDarkRenders() async throws {
        try await L1Fixture.prepare()
        if !SIDEBARPins.shared.isPinned("l1-crm") { SIDEBARPins.shared.toggle("l1-crm") } // show the Pinned section
        let out = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["L1_RENDER_OUT"]))
        #expect(out.path.contains(".noindex"))
        let projects = [PROJProject(id: "imatch", name: "iMatch", folders: ["/scratch/iMatch"], colour: "blue"),
                        PROJProject(id: "crm", name: "CRM", folders: ["/scratch/CRM"], colour: "purple"),
                        PROJProject(id: PROJProjects.independentID, name: "Independent", colour: "graphite")]
        let views: [(String, CGSize, AnyView)] = [
            ("deckpage", CGSize(width: 1100, height: 720), AnyView(L1DummyPage(projects: projects))),
            ("deckpage-narrow", CGSize(width: 640, height: 520), AnyView(L1DummyPage(projects: projects))),
            ("settings-frame", CGSize(width: 560, height: 520), AnyView(L1DummySettings())),
            ("multi-actions", CGSize(width: 1100, height: 120), AnyView(
                DeckPage(title: "MCP servers", subtitle: "3 servers", actions: {
                    Button("Browse Store") {}.buttonStyle(.bordered)
                    Button("Add server") {}.buttonStyle(.borderedProminent)
                }) { EmptyView() })),
            ("side-panel", CGSize(width: 264, height: 820), AnyView(L1DummySidePanel(projects: projects))),
            ("side-footer", CGSize(width: 264, height: 44), AnyView(L1FooterReplica().frame(width: 264, height: 44))),
            ("row-icons", CGSize(width: 260, height: 300), AnyView(L1RowIcons().frame(width: 260, height: 300).background(DeckTokens.card))),
            ("mention-picker", CGSize(width: 360, height: 380), AnyView(L1MentionPicker().background(DeckTokens.card))),
            ("project-settings", CGSize(width: 560, height: 360), AnyView(PROJPAGEProjectSettings(
                project: PROJProject(id: "imatch", name: "iMatch", folders: ["/scratch/iMatch"]),
                model: PROJPAGESettingsModel(values: [:])).frame(width: 560, height: 360).background(DeckTokens.page))),
        ]
        for (scheme, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for (name, size, view) in views {
                try await Self.render(view, size: size, appearance: scheme,
                                      to: out.appendingPathComponent("L1-\(name)-\(label).png"))
            }
        }
        if let app = NSApp { #expect(app.windows.allSatisfy { !$0.isVisible }) }
    }

    /// Glass only draws in a real window: a borderless, never-activated window placed off the
    /// screens, captured with screencapture -l (10 Oct: switch labels were ghosted under glass).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["L1_REAL_WINDOW"]?.isEmpty == false))
    func realWindowSwitch() async throws {
        let out = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["L1_RENDER_OUT"]))
        NSApplication.shared.setActivationPolicy(.accessory)
        for (name, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let view = L1SwitchSampler().environment(\.colorScheme, name == .darkAqua ? .dark : .light)
            let host = NSHostingView(rootView: view)
            // On a screen (off-screen windows have no image), under every normal window, never key.
            let origin = NSScreen.screens.first?.visibleFrame.origin ?? .zero
            let window = NSWindow(contentRect: NSRect(x: origin.x, y: origin.y, width: 760, height: 220),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: name)
            window.contentView = host
            window.orderBack(nil)
            for _ in 0..<10 {
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
                Self.spin(0.1)
            }
            let url = out.appendingPathComponent("L1-switch-window-\(label).png")
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-l\(window.windowNumber)", "-o", "-x", url.path]
            try capture.run(); capture.waitUntilExit()
            window.orderOut(nil); window.close()
            #expect(capture.terminationStatus == 0)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(NSApp.isActive == false)
    }

    /// One hidden real window (under every normal window, never key), captured with screencapture -l.
    static func captureInWindow<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, to url: URL,
                                         titled: Bool = false, settle: Int = 10) throws -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
        let origin = NSScreen.screens.first?.visibleFrame.origin ?? .zero
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                              styleMask: titled ? [.titled, .fullSizeContentView] : [.borderless],
                              backing: .buffered, defer: false)
        if titled { window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden }
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<settle {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
            spin(0.1)
        }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-l\(window.windowNumber)", "-o", "-x", url.path]
        try capture.run(); capture.waitUntilExit()
        window.orderOut(nil); window.close()
        return capture.terminationStatus == 0
    }

    /// The window frame as Asad sees it: a colourful window behind (standing in for his desktop)
    /// and the test window over it, both under every normal window, composited by ScreenCaptureKit
    /// so behind-window materials show what is really behind them.
    static func captureOverBackdrop(_ make: () -> NSWindow, appearance: NSAppearance.Name, to url: URL) async throws -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = make()
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        let origin = NSScreen.screens.first?.visibleFrame.origin ?? .zero
        window.setFrameOrigin(NSPoint(x: origin.x + 40, y: origin.y + 40))
        let backdrop = NSWindow(contentRect: window.frame.insetBy(dx: -40, dy: -40), styleMask: [.borderless],
                                backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.ignoresMouseEvents = true
        backdrop.contentView = NSHostingView(rootView: L1ColourfulDesktop())
        backdrop.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 2)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        backdrop.orderBack(nil)
        window.orderBack(nil)
        window.order(.above, relativeTo: backdrop.windowNumber)
        // The window is never made key (no activation); show materials as they look in front.
        func activate(_ view: NSView) {
            (view as? NSVisualEffectView)?.state = .active
            view.subviews.forEach(activate)
        }
        for _ in 0..<15 {
            if let frameView = window.contentView?.superview { activate(frameView) }
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); backdrop.displayIfNeeded()
            CATransaction.flush(); spin(0.1)
        }
        defer { window.orderOut(nil); backdrop.orderOut(nil); window.close(); backdrop.close() }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let ids: Set<CGWindowID> = [CGWindowID(window.windowNumber), CGWindowID(backdrop.windowNumber)]
        let windows = content.windows.filter { ids.contains($0.windowID) }
        guard windows.count == 2, let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = backdrop.frame
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: frame.minX - display.frame.minX, y: primaryHeight - frame.maxY - display.frame.minY,
                                   width: frame.width, height: frame.height)
        config.width = Int(frame.width * 2); config.height = Int(frame.height * 2)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, including: windows),
                                                               configuration: config)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        try png.write(to: url)
        return true
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["L1_MATERIAL_PROBE"]?.isEmpty == false))
    func materialProbe() async throws {
        let out = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["L1_RENDER_OUT"]))
        for (variant, clear) in [("clear", true), ("opaque", false)] {
            let ok = try await Self.captureOverBackdrop({
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                if clear { window.isOpaque = false; window.backgroundColor = .clear }
                let effect = NSVisualEffectView()
                effect.material = .sidebar; effect.blendingMode = .behindWindow; effect.state = .active
                window.contentView = effect
                return window
            }, appearance: .aqua, to: out.appendingPathComponent("L1-probe-\(variant).png"))
            #expect(ok)
        }
    }

    /// Main window frame: Apple sidebar material + blue selection, tab meeting the page,
    /// rounded page corner; also with the side panel hidden; and the Settings sidebar.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["L1_REAL_WINDOW"]?.isEmpty == false))
    func realWindowFrame() async throws {
        let out = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["L1_RENDER_OUT"]))
        try await L1Fixture.prepare()
        for (name, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for (variant, sidebar) in [("main", true), ("main-nosidebar", false)] {
                let ok = try await Self.captureOverBackdrop({ L1ShellReplica.window(sidebar: sidebar) }, appearance: name,
                                                            to: out.appendingPathComponent("L1-frame-\(variant)-\(label).png"))
                #expect(ok)
            }
            let ok = try await Self.captureOverBackdrop({ L1ShellReplica.settingsWindow() }, appearance: name,
                                                        to: out.appendingPathComponent("L1-frame-settings-\(label).png"))
            #expect(ok)
        }
        #expect(NSApp.isActive == false)
    }

    /// Asad 10 Oct: windows show see-through glass (not white) while opening/loading.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["L1_REAL_WINDOW"]?.isEmpty == false))
    func realWindowLoadingGlass() async throws {
        let out = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["L1_RENDER_OUT"]))
        for (name, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            // Launching main window: everything hidden, glass + the loading line.
            let launching = Color.white.deckLoadingGlass(true)
                .overlay { LoadingView(message: "Starting Terminal Deck…") }
            #expect(try Self.captureInWindow(launching, size: CGSize(width: 640, height: 400), appearance: name,
                                             to: out.appendingPathComponent("L1-loading-launch-\(label).png"), titled: true))
            // A web page before its first paint.
            #expect(try Self.captureInWindow(L1WebBeforePaint(), size: CGSize(width: 640, height: 400), appearance: name,
                                             to: out.appendingPathComponent("L1-loading-web-\(label).png"), titled: true))
            // A native window after its first layout: content faded in over the glass.
            let ready = L1DummySettings().deckWindowAppear()
            #expect(try Self.captureInWindow(ready, size: CGSize(width: 560, height: 400), appearance: name,
                                             to: out.appendingPathComponent("L1-loading-ready-\(label).png"), titled: true))
        }
        #expect(NSApp.isActive == false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["L1_REAL_WINDOW"]?.isEmpty == false))
    func realWindowGlassAudit() async throws {
        let out = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["L1_RENDER_OUT"]))
        for (name, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let ok = try Self.captureInWindow(L1GlassAudit(), size: CGSize(width: 900, height: 860), appearance: name,
                                              to: out.appendingPathComponent("L1-glass-audit-\(label).png"))
            #expect(ok)
        }
        #expect(NSApp.isActive == false)
    }

    static func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    static func render(_ view: AnyView, size: CGSize, appearance: NSAppearance.Name, to url: URL) async throws {
        let hosted = NSHostingView(rootView: view.environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
        hosted.sizingOptions = []
        hosted.appearance = NSAppearance(named: appearance)
        hosted.frame = NSRect(origin: .zero, size: size)
        hosted.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        hosted.layoutSubtreeIfNeeded()
        var png: Data?
        hosted.appearance?.performAsCurrentDrawingAppearance {
            if let rep = hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds) {
                hosted.cacheDisplay(in: hosted.bounds, to: rep)
                png = rep.representation(using: .png, properties: [:])
            }
        }
        try #require(png).write(to: url)
        // Window frame stays put: the hosting view is never resized by its content.
        #expect(hosted.frame.size == size)
    }
}

private struct L1DummyPage: View {
    let projects: [PROJProject]
    @State private var view = "Overview"
    @State private var project: String? = nil

    var body: some View {
        DeckPage(title: "iMatch", subtitle: "~/ClaudeiMatch · main · 19 changed",
                 project: $project, projects: projects, openProject: {},
                 switcher: {
                     GlassSwitch(selection: $view, items: ["Overview", "Files", "Code", "Readiness", "Stays Fixed"]
                        .map { DeckSwitchItem(id: $0, title: $0) })
                 }, actions: {
                     Button {} label: { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("Project settings")
                     Button("New session") {}.buttonStyle(.borderedProminent)
                 }) {
            Text("Sessions").font(DeckTokens.Typography.section)
            HStack(spacing: DeckTokens.Metrics.cardGap) {
                DeckCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Commander").font(DeckTokens.Typography.rowTitle)
                        Text("Claude · Opus · 2 h").font(DeckTokens.Typography.callout).foregroundStyle(.secondary)
                        HStack(spacing: 6) { Circle().fill(DeckTokens.good).frame(width: 6, height: 6); Text("Working") }
                            .font(DeckTokens.Typography.caption)
                    }
                }
                DeckCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Usage").font(DeckTokens.Typography.rowTitle)
                        Text("1.2M").font(DeckTokens.Typography.metric)
                        Capsule().fill(DeckTokens.meter).frame(width: 120, height: 6)
                    }
                }
            }
            DeckCard(padding: 4) {
                VStack(spacing: 0) {
                    ForEach(["Review changes", "Open Tasks", "Linked server"], id: \.self) { row in
                        Button {} label: {
                            HStack { Image(systemName: "chevron.right").foregroundStyle(.secondary); Text(row); Spacer() }
                                .padding(.horizontal, DeckTokens.Metrics.rowHorizontal)
                        }.buttonStyle(DeckRowStyle())
                    }
                }
            }
            DeckEmpty(title: "No artifacts yet", message: "Things your sessions make show up here.", symbol: "doc.richtext")
        }
    }
}

private struct L1DummySettings: View {
    @State private var tab = "General"
    @State private var on = true
    var body: some View {
        DeckSettingsFrame(title: "iMatch", subtitle: "Project settings", switcher: {
            GlassSwitch(selection: $tab, items: ["General", "Server", "Tasks"].map { DeckSwitchItem(id: $0, title: $0) })
        }) {
            Form {
                Section("General") {
                    TextField("Name", text: .constant("iMatch"))
                    Toggle("Show in side panel", isOn: $on)
                }
            }.formStyle(.grouped)
        }
    }
}

private struct L1DummySidePanel: View {
    let projects: [PROJProject]
    var body: some View {
        let commander = SidebarItem(id: "l1-command", title: "Commander", kind: .session, status: "working")
        let crm = SidebarItem(id: "l1-crm", title: "CRM session", kind: .session, status: "input")
        let state = SidebarState(groups: [], projects: [
            .init(id: "/scratch/iMatch", title: "iMatch", expanded: false, sessions: [commander]),
            .init(id: "/scratch/CRM", title: "CRM", expanded: false, sessions: [crm]),
            .init(id: "/scratch/Daftar", title: "Daftar", expanded: false, sessions: []),
        ], selectedId: "project:/scratch/iMatch")
        let store = SIDEBARProjectStore()
        store.projects = projects
        store.liveIDs = [commander.id, crm.id]
        store.started = [commander.id: 2, crm.id: 1]
        return SIDEBARPanel(state: state, selected: state.selectedId, store: store,
                            choose: { _ in }, openProject: {}, newSession: { _ in }, closeProject: { _ in },
                            openWindow: { _ in }, rename: { _ in }, close: { _ in }, stop: { _ in }) {
            HStack { Label("Settings", systemImage: "gearshape"); Spacer(); Image(systemName: "laptopcomputer.and.iphone") }
                .font(.system(size: 13)).foregroundStyle(.secondary)
        } hostFailure: { EmptyView() }
    }
}

private struct L1SwitchSampler: View {
    @State private var agents = "All agents"
    @State private var receiver = "Sources"
    var body: some View {
        VStack(spacing: 24) {
            GlassSwitch(selection: $agents, items: ["All agents", "Org chart", "At work", "Routines", "Skills"]
                .map { DeckSwitchItem(id: $0, title: $0) })
            GlassSwitch(selection: $receiver, items: ["Flow", "Events", "Sources", "Rules"]
                .map { DeckSwitchItem(id: $0, title: $0) })
        }
        .padding(32)
        .frame(width: 760, height: 220)
        .background(DeckTokens.page)
    }
}

/// Every glass pattern in the app, side by side, labelled with its file.
private struct L1GlassAudit: View {
    @State private var agents = "all"
    @State private var devices = "General"
    @State private var server = "Access"
    @State private var tab = "General"
    @State private var machine = "Apps"
    @State private var project: String? = nil
    @Namespace private var ns

    private func row<V: View>(_ name: String, @ViewBuilder _ content: () -> V) -> some View {
        HStack(spacing: 16) {
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 190, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("AGFRAMEPageKit switch") {
                GlassSwitch(selection: $agents, items: [DeckSwitchItem(id: "all", title: "All agents"), DeckSwitchItem(id: "org", title: "Org chart"), DeckSwitchItem(id: "work", title: "At work")])
            }
            row("AGFRAMEPageKit picker") {
                Menu { Button("A") {} } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Color.blue).frame(width: 8, height: 8)
                        Text("All projects").lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 30)
                }.menuStyle(.borderlessButton).fixedSize().glassEffect(.regular, in: .capsule)
            }
            row("ProjectPicker") {
                ProjectPicker(projects: [PROJProject(id: "imatch", name: "iMatch", colour: "blue")], selection: $project, openProject: {})
            }
            row("NativeMACHINESKit fallback") {
                GlassEffectContainer(spacing: 2) {
                    HStack(spacing: 2) {
                        ForEach(["Apps", "Coding AIs", "Health"], id: \.self) { item in
                            Button { machine = item } label: {
                                Text(item).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 14).frame(height: 30).contentShape(Capsule())
                            }.buttonStyle(.plain).foregroundStyle(Color.primary)
                            .background(machine == item ? DeckTokens.card.opacity(0.7) : .clear, in: Capsule())
                            .glassEffectID(item, in: ns)
                        }
                    }.padding(3).glassEffect(.regular, in: .capsule)
                }
            }
            row("SendTargetButton bar") {
                HStack(spacing: 10) { Image(systemName: "paperplane"); Text("Send to Hoot"); Text("⌘↩").foregroundStyle(.secondary) }
                    .padding(.horizontal, 14).frame(height: 34)
                    .modifier(NativeHOOTSIMGlassBar())
            }
            row("MACHINESDevicesScreen tabs") { MACHINESDevicesSettingsTabs(selection: $devices).frame(width: 450) }
            row("ObjectWindows+Machines tabs") { MACHINESServerSettingsTabs(selection: $server).frame(width: 450) }
            row("NativeBrowserScreen notice") {
                Text("Saved to Downloads").font(.callout).padding(.horizontal, 14).padding(.vertical, 7)
                    .glassEffect(.regular, in: .capsule)
            }
            row("NativeCatalogMcpSettings tabs") {
                GlassEffectContainer(spacing: 2) {
                    HStack(spacing: 2) {
                        ForEach(["General", "Tools", "Access"], id: \.self) { t in
                            Button { tab = t } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "gearshape").font(.system(size: 18))
                                    Text(t).font(.system(size: 11, weight: tab == t ? .semibold : .regular))
                                }.frame(width: 72, height: 52).contentShape(.rect)
                            }.buttonStyle(.plain).foregroundStyle(tab == t ? .primary : .secondary)
                            .background(tab == t ? DeckTokens.card.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .glassEffectID(t, in: ns)
                        }
                    }.padding(4).glassEffect(.regular, in: .rect(cornerRadius: 14))
                }
            }
            row("HootComposer") {
                GlassEffectContainer {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ask Hoot anything…").font(.system(size: 14)).foregroundStyle(.tertiary)
                        HStack { Image(systemName: "plus"); Text("Claude · Opus"); Spacer(); Image(systemName: "mic") }
                    }
                    .padding(16).foregroundStyle(.primary)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                }.frame(width: 420)
            }
        }
        .padding(24)
        .frame(width: 900, height: 860, alignment: .topLeading)
        .background {
            // A busy backdrop so glass has something to refract, plus the page colour.
            ZStack {
                DeckTokens.page
                HStack(spacing: 40) { ForEach(0..<12, id: \.self) { _ in Rectangle().fill(Color.accentColor.opacity(0.18)).frame(width: 14) } }
            }
        }
    }
}

private struct L1WebBeforePaint: NSViewRepresentable {
    func makeNSView(context: Context) -> DeckWebPaintHost {
        let host = DeckWebPaintHost(frame: .zero)
        host.show(WKWebView(frame: .zero)) // nothing loaded yet: glass, never white
        return host
    }
    func updateNSView(_ view: DeckWebPaintHost, context: Context) {}
}

private struct L1ColourfulDesktop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [.orange, .pink, .purple, .blue, .green], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 60) { ForEach(0..<14, id: \.self) { i in Circle().fill(i.isMultiple(of: 2) ? Color.yellow : Color.teal).frame(width: 70) } }
        }
    }
}

@MainActor
private struct L1ShellReplica: View {
    let sidebar: Bool
    @State private var anchor = StripAnchorBox()
    @State private var width: CGFloat = 0
    @State private var detailMinX: CGFloat = 0

    static func window(sidebar: Bool) -> NSWindow {
        let controller = NSHostingController(rootView: L1ShellReplica(sidebar: sidebar))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        window.toolbarStyle = .unifiedCompact
        window.setContentSize(NSSize(width: 1100, height: 640))
        return window
    }

    static func settingsWindow() -> NSWindow {
        let host = NSHostingController(rootView: NativeSettingsShell(selection: .constant("appearance")) { _ in
            Text("Appearance").frame(maxWidth: .infinity, maxHeight: .infinity).background(DeckTokens.page)
        }.environment(\.appearsActive, true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentViewController = host
        window.setContentSize(NSSize(width: 760, height: 520))
        return window
    }

    var body: some View {
        let projects = [PROJProject(id: "imatch", name: "iMatch", folders: ["/scratch/iMatch"], colour: "blue"),
                        PROJProject(id: "crm", name: "CRM", folders: ["/scratch/CRM"], colour: "purple")]
        let tabs = TabsState(tabs: [TabItem(id: "hoot", title: "Hoot", kind: "hoot", active: true),
                                    TabItem(id: "l1-browser", title: "Instagram", symbol: "globe", kind: "browser", closable: true)],
                             canNewTerminal: true, canNewBrowser: true)
        NavigationSplitView(columnVisibility: .constant(sidebar ? .all : .detailOnly)) {
            L1DummySidePanel(projects: projects)
                .navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 340)
        } detail: {
            DeckPage(deckContent: AnyView(ZStack {
                L1DummyPage(projects: projects)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .background(NativeChrome.page(paper: false), ignoresSafeAreaEdges: [.horizontal, .bottom])
            }))
            .deckContentCorner()
            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minX }) { x in detailMinX = x; anchor.remeasureSoon() }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    TabStrip(state: tabs,
                             width: TabStripLayout.width(windowWidth: width, detailMinX: detailMinX,
                                                         anchorMinX: anchor.minX, leadingFloor: anchor.leadingFloor),
                             anchor: anchor, select: { _ in }, close: { _ in }, newTerminal: {}, newBrowser: {},
                             openInNewWindow: { _ in })
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { w in width = w; anchor.remeasureSoon() }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background(NativeChromeWindow(paper: false))
        .toolbar(removing: .title)
        .environment(\.appearsActive, true) // as when the window is in front
    }
}

/// An inert AppModel (scratch home/data, no engine, no OS wiring) for views that read it.
@MainActor
private enum L1Fixture {
    static var root: BackendCompositionRoot?
    static func prepare() async throws {
        guard root == nil else { return }
        let env = ProcessInfo.processInfo.environment
        let data = try #require(env["TD_NATIVE_DATA_DIR"])
        let made = try BackendCompositionRoot(dataRoot: URL(fileURLWithPath: data), state: NativeStateStore(),
                                              environment: [:], home: NSHomeDirectory())
        for channel in ["session:list", "machines:list"] {
            try await made.registry.register(channel, ownerID: "l1-fixture") { _, _ in .array([]) }
        }
        try await EngineBridge.shared.configure(native: made)
        let assets = try NativeWebAssets.discover(resources: URL(fileURLWithPath: try #require(env["L1_TEST_RESOURCES"])))
        try AppModel.prepareForUITests(configuration: EngineConfiguration(source: .nativeOnly(assets),
                                                                          dataRoot: URL(fileURLWithPath: data)))
        #expect(AppModel.shared.isUITestFixture)
        root = made
    }
}

/// SidebarSettingsLine's layout without its approvals task (needs a real app bundle).
private struct L1FooterReplica: View {
    var body: some View {
        HStack(spacing: 8) {
            Button {} label: {
                Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(.rect)
            }.buttonStyle(DeckSidebarRowStyle())
            Button {} label: {
                Image(systemName: "laptopcomputer.and.iphone").frame(width: 28, height: 28)
            }.buttonStyle(DeckSidebarIconStyle()).fixedSize()
        }
        .foregroundStyle(.secondary).padding(.horizontal, 12)
    }
}

/// The shared menu/picker row pictures, one of each kind.
private struct L1RowIcons: View {
    var body: some View {
        let project = PROJProject(id: "imatch", name: "iMatch", folders: ["/scratch/iMatch"])
        VStack(alignment: .leading, spacing: 8) {
            DeckRowLabel.allProjects
            DeckRowLabel.independent
            DeckRowLabel.project(project)
            DeckRowLabel("Hoot", image: DeckRowIcon.hoot)
            DeckRowLabel("ios-engineer", image: DeckRowIcon.agent(id: "ios-engineer", icon: "sf:iphone@blue"))
            DeckRowLabel("design-keeper", image: DeckRowIcon.agent(id: "design-keeper", icon: "sf:paintpalette@pink"))
            DeckRowLabel.provider("Claude Code")
            DeckRowLabel.provider("Codex")
            DeckRowLabel.provider("Gemini")
            DeckRowLabel("You", image: DeckRowIcon.assignee("me"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The @ list with one of every kind of row (fixed rows; no live stores).
private struct L1MentionPicker: View {
    var body: some View {
        let imatch = PROJProject(id: "imatch", name: "iMatch", folders: ["/scratch/iMatch"])
        func agent(_ id: String, _ name: String, _ icon: String, _ detail: String, lead: Bool = false, hands: Int = 1,
                   _ state: DeckMentionRow.State) -> DeckMentionRow {
            DeckMentionRow(mention: HootMention(id: id, kind: .agent, name: name), section: .agents,
                           picture: .agent(id: id, icon: AGTIcon.parse(icon) ?? .symbol("person"), colour: AGTIcon.colour(icon)),
                           title: name, detail: detail, isLead: lead, hands: hands, state: state)
        }
        let rows: [DeckMentionRow] = [
            DeckMentionRow(mention: HootMention(id: "hoot", kind: .agent, name: "Hoot"), section: .agents, picture: .hoot,
                           title: "Hoot", detail: "Every project · Orchestrator", state: .awake),
            agent("commander", "Commander", "sf:star@orange", "iMatch · Lead", lead: true, .working),
            agent("db-surgeon", "db-surgeon", "sf:cylinder.split.1x2@blue", "iMatch · Database fixer", hands: 3, .working),
            agent("design-keeper", "design-keeper", "sf:paintpalette@pink", "iMatch · Design keeper", .asleep),
            DeckMentionRow(mention: HootMention(id: "seat:role:imatch/ios", kind: .agent, name: "iOS"), section: .agents, picture: .vacantSeat,
                           title: "iMatch · iOS engineer", detail: "Vacant, has memory", hands: 0, state: .vacant),
            DeckMentionRow(mention: HootMention(id: "s1", kind: .session, name: "Session 1"), section: .sessions,
                           picture: .project(imatch, name: "iMatch"), title: "Session 1", detail: "iMatch · Session", state: .waiting),
            DeckMentionRow(mention: HootMention(id: "tasks", kind: .page, name: "Tasks"), section: .pages, picture: .symbol("list.bullet"),
                           title: "Tasks", detail: "Page"),
        ]
        return DeckMentionPicker(candidates: [], query: "", onPick: { _ in }, fixtureRows: rows)
    }
}

/// Hoot's kind of draft: a property of its model.
@MainActor @Observable final class L1MentionDraftModel {
    var draft = HootComposerDraft(text: "ask @cri")
}
private struct L1HootDraftBox: View {
    @Bindable var model: L1MentionDraftModel
    var body: some View {
        HootComposer(draft: $model.draft, showMeta: false, microphoneAvailable: false, onSend: { _ in }, onStop: {})
            .environment(\.agkitOffscreenSolid, true)
    }
}
/// The task comment box's kind of draft: the view's own state.
@MainActor final class L1MentionDraftSeen { var binding: Binding<HootComposerDraft>? }
private struct L1TaskDraftBox: View {
    let seen: L1MentionDraftSeen
    @State private var draft = HootComposerDraft(text: "ask @cri")
    var body: some View {
        let _ = seen.binding = $draft
        HootComposer(draft: $draft, showMeta: false, microphoneAvailable: false, onSend: { _ in }, onStop: {})
            .environment(\.agkitOffscreenSolid, true)
    }
}
@MainActor final class L1TextChangeListener: NSObject, NSTextViewDelegate {
    var changes = 0
    func textDidChange(_ notification: Notification) { changes += 1 }
}
