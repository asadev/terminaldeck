import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// The built-in browser's chrome after the 18 Nov 2026 review (notes/review-20261118/DESIGN-browser.md, items 1-8):
/// the header's tabs, the toolbar, its cards (More, Profile, Connect) and the bookmarks bar, light and dark, drawn
/// offscreen (never in a window on screen) from made-up names. Every piece is the app's own view; only the values are
/// made up, so no tab, store, engine or app model is started. A card is drawn in `DeckMenuSurface` (the menu's own
/// look) at the place the app's menu opens it.
@MainActor
final class BrowserChromePictures: XCTestCase {
    private var output: URL {
        if let path = ProcessInfo.processInfo.environment["UI_BROWSER_PICTURES"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("night/ui-browser-evidence")
    }

    // MARK: Made-up values

    static let bookmarks: [BrowserBookmark] = ([
        ("https://web.whatsapp.com/", "WhatsApp", 0x25D366), ("https://terminaldeck.dev/", "Terminal Deck", 0x1A66C4),
        ("https://www.forexfactory.com/", "Forex Factory", 0x2B4C7E), ("https://wordpress.com/", "WordPress", 0x3858E9),
        ("https://www.canva.com/", "Canva", 0x7D2AE8), ("https://docs.google.com/spreadsheets", "Sheets", 0x188038),
        ("https://www.youtube.com/", "YouTube", 0xFF0000), ("https://www.facebook.com/", "Facebook", 0x1877F2),
        ("https://business.facebook.com/settings", "business settings", 0x0668E1), ("https://adsmanager.facebook.com/", "Ads Manager", 0x0668E1),
        ("http://localhost:5173/", "", 0x888888),
    ] as [(String, String, UInt32)]).enumerated().map { index, row in
        BrowserBookmark(profileID: "default", url: row.0, title: row.1, icon: index == 10 ? nil : icon(row.2, letter: String(row.1.prefix(1))),
                        addedAt: Double(index))
    }

    /// A small round site icon, drawn here (no file, no network).
    static func icon(_ hex: UInt32, letter: String) -> Data? {
        NativeBrowserBookmarksStore.png(image(hex, letter: letter))
    }

    static func image(_ hex: UInt32, letter: String) -> NSImage {
        NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let text = NSAttributedString(string: letter, attributes: [.font: NSFont.systemFont(ofSize: 18, weight: .bold), .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
    }

    static let profiles = [BrowserProfile(id: "default", name: "Default", isDefault: true), BrowserProfile(id: "work", name: "Work"),
                           BrowserProfile(id: "imza", name: "Imza")]

    static let sessions = [BrowserSessionChoice(id: "s-crm", label: "CRM · Session 1"), BrowserSessionChoice(id: "s-deck", label: "Deck Dev · Session 1"),
                           BrowserSessionChoice(id: "s-imatch", label: "iMatch"), BrowserSessionChoice(id: "s-ipresent", label: "iPresent · Session 1")]

    static func binding(connected: Bool) -> BRBindingView {
        connected ? BRBindingView(sessions: [BRBoundSession(sessionId: "s-deck", colour: 1, windows: [BRBoundWindow(n: 1, tabId: "tab")])]) : BRBindingView()
    }

    // MARK: A browser screen made of the app's pieces

    struct Screen: View {
        var address = ""
        var website = false
        var saved = false
        var connected = false
        var compact = false
        var recording = false
        var menu: BrowserChromeMenu?
        var morePage = BrowserMoreMenu.Page.main
        var isolated = false
        var marks = BrowserChromePictures.bookmarks
        var bar = true
        /// The bookmarks bar's "»" is open (its menu is drawn where the app puts it).
        var overflow = false
        var overflowBarWidth: CGFloat = 760

        var body: some View {
            VStack(spacing: 0) {
                BrowserToolbarFrame {
                    BrowserToolbarButton("Back", "chevron.left", help: "Back") {}.disabled(!website)
                    BrowserToolbarButton("Forward", "chevron.right", help: "Forward") {}.disabled(true)
                    BrowserToolbarButton("Reload", "arrow.clockwise", help: "Reload") {}.disabled(!website)
                } address: {
                    BrowserAddressPill(focused: false) {
                        Text(address.isEmpty ? "Enter a URL, or search" : address)
                            .foregroundStyle(address.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                            .font(.system(size: 13)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if website { BrowserBookmarkStar(saved: saved) {} }
                    }
                } trailing: {
                    if !compact {
                        BrowserToolbarButton("Annotate", "cursorarrow.rays", help: "Annotate") {}.disabled(!website)
                        BrowserToolbarButton("Screenshot", "camera", help: "Screenshot") {}.disabled(!website)
                        if !recording { BrowserToolbarButton("Record", "record.circle", help: "Record") {}.disabled(!website) }
                    }
                    if recording {
                        BrowserModePill(text: "Recording · 3", symbol: "record.circle.fill", tint: .red, help: "Stop recording") {}
                    }
                    BrowserConnectPill(state: BrowserConnectState(slot: connected ? "B1" : nil, sessionName: connected ? "Deck Dev" : "", colour: 1),
                                       compact: compact, open: menu == .connect, showMenu: {}, disconnect: {})
                    BrowserToolbarButton(label: "Downloads", help: "Downloads", active: false, action: {}) {
                        BrowserDownloadsGlyph(badge: website ? (label: "5", tone: "") : nil)
                    }
                    BrowserProfileAvatar(badge: "D", colour: BrowserProfileLook.colour(BrowserChromePictures.profiles[0], among: BrowserChromePictures.profiles), size: 22, isolated: isolated)
                        .frame(width: BrowserToolbarMetrics.button, height: BrowserToolbarMetrics.button)
                        .background(Color.primary.opacity(menu == .profile ? 0.14 : 0), in: .circle)
                    BrowserToolbarButton(label: "More", help: "More", active: menu == .more, action: {}) {
                        Image(systemName: "ellipsis").rotationEffect(.degrees(90))
                    }
                }
                .background(NativeSessionChrome.ground)

                if bar && !marks.isEmpty {
                    GeometryReader { proxy in
                        BrowserBookmarksBar(items: marks, width: proxy.size.width, overflowOpen: .constant(overflow),
                                            open: { _, _ in }, copy: { _ in }, remove: { _ in })
                    }
                    .frame(height: BrowserBookmarksBarMetrics.height)
                    .background(NativeSessionChrome.ground)
                }
                page
            }
            // The open card, where the app's menu puts it: under its button, right edges in line, 6 pt below.
            .overlay(alignment: .topTrailing) {
                if let menu {
                    DeckMenuSurface(width: width(menu)) { card(menu) }
                        .padding(.top, BrowserToolbarMetrics.height - (BrowserToolbarMetrics.height - BrowserToolbarMetrics.button) / 2 + DeckMenuMetrics.gap)
                        .padding(.trailing, trailing(menu))
                } else if overflow {
                    DeckMenuSurface(width: BrowserToolbarMetrics.moreWidth) {
                        BrowserBookmarksOverflowMenu(items: Array(marks.dropFirst(BrowserBookmarksBar.shown(marks, width: overflowBarWidth)))) { _, _ in }
                    }
                    .padding(.top, BrowserToolbarMetrics.height + BrowserBookmarksBarMetrics.height + 3)
                    .padding(.trailing, 8)
                }
            }
        }

        private func width(_ menu: BrowserChromeMenu) -> CGFloat {
            switch menu {
            case .connect: BrowserToolbarMetrics.connectWidth
            case .profile: BrowserToolbarMetrics.profileWidth
            case .more: BrowserToolbarMetrics.moreWidth
            }
        }

        /// The button's right edge from the screen's: More is last, Profile before it, Connect before Downloads.
        private func trailing(_ menu: BrowserChromeMenu) -> CGFloat {
            let step = BrowserToolbarMetrics.button + 4
            switch menu {
            case .more: return 8
            case .profile: return 8 + step
            case .connect: return 8 + step * 3
            }
        }

        /// A stand-in page: the New Tab page's heading, or grey lines for a website. It takes the room that is left
        /// (its lines are cut at the picture's foot, they never push the toolbar out).
        private var page: some View {
            DeckTokens.page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(website ? "Terminal Deck" : "Open a page").font(.title2.weight(.semibold))
                        ForEach(0..<7, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)).frame(width: index.isMultiple(of: 3) ? 420 : 520, height: 34)
                        }
                    }
                    .padding(.horizontal, 32).padding(.vertical, 36)
                    .fixedSize()
                }
                .clipped()
        }

        @ViewBuilder private func card(_ menu: BrowserChromeMenu) -> some View {
            switch menu {
            case .connect:
                BrowserConnectMenu(rows: BRConnectMenu.rows(tabId: "tab", sessions: BrowserChromePictures.sessions,
                                                            view: BrowserChromePictures.binding(connected: connected))) { _ in }
            case .profile:
                BrowserProfileCard(model: BrowserProfileCardModel(current: BrowserChromePictures.profiles[0],
                                                                  all: BrowserChromePictures.profiles, isolated: isolated)) { _ in }
            case .more:
                BrowserMoreMenu(model: BrowserMoreModel(hasPage: website, hasAddress: website, recording: recording, zoom: "100%",
                                                        isolated: isolated, split: false, bookmarksAlways: false, bookmarks: marks,
                                                        size: BrowserSizeModel(deviceID: morePage == .size ? "phone" : nil)),
                                startPage: morePage) { _ in }
            }
        }
    }

    // MARK: Pictures

    func testToolbarCardsAndBookmarksBothThemes() throws {
        let wide = CGSize(width: 1180, height: 840)
        let shots: [(String, Screen, CGSize)] = [
            ("1-new-tab", Screen(), CGSize(width: 1180, height: 300)),
            ("2-website-connected", Screen(address: "terminaldeck.dev", website: true, saved: true, connected: true, bar: false),
             CGSize(width: 1180, height: 300)),
            ("3-recording", Screen(address: "localhost:5173/checkout", website: true, recording: true, bar: false), CGSize(width: 1180, height: 200)),
            ("4-more", Screen(address: "terminaldeck.dev", website: true, saved: true, connected: true, menu: .more, bar: false), wide),
            ("5-more-page-size", Screen(address: "terminaldeck.dev", website: true, menu: .more, morePage: .size, bar: false), wide),
            ("6-more-bookmarks", Screen(address: "terminaldeck.dev", website: true, menu: .more, morePage: .bookmarks, bar: false), wide),
            ("7-profile", Screen(menu: .profile), CGSize(width: 1180, height: 520)),
            ("8-profile-isolated", Screen(menu: .profile, isolated: true), CGSize(width: 1180, height: 520)),
            ("9-connect", Screen(menu: .connect), CGSize(width: 1180, height: 420)),
            ("10-connect-connected", Screen(address: "terminaldeck.dev", website: true, connected: true, menu: .connect, bar: false),
             CGSize(width: 1180, height: 420)),
            ("11-bookmarks-overflow", Screen(overflow: true), CGSize(width: 760, height: 420)),
            ("12-narrow-pane", Screen(address: "terminaldeck.dev", website: true, connected: true, compact: true, bar: false),
             CGSize(width: 560, height: 200)),
        ]
        for dark in [false, true] {
            NativeTerminalSettings.shared.preview(TerminalSchemes.app(dark: dark))
            for (name, screen, size) in shots { try render(screen, "browser-\(name)", dark, size: size) }
        }
        NativeTerminalSettings.shared.preview(nil)
        // What the pictures stand on: the bar keeps room for "»" and never shows a cut item.
        let shown = BrowserBookmarksBar.shown(Self.bookmarks, width: 760)
        XCTAssertGreaterThan(shown, 2)
        XCTAssertLessThan(shown, Self.bookmarks.count)
        XCTAssertEqual(BrowserBookmarksBar.shown(Self.bookmarks, width: 4000), Self.bookmarks.count)
    }

    /// The header: as many tabs as his recording had (17) and a few, at his window's width and a small one.
    func testHeaderTabsBothThemes() throws {
        func tabs(_ count: Int, active: Int) -> (TabsState, [String: NSImage]) {
            let names = ["1 new message", "Deck Dev", "iMatch", "iPresent", "Deck Dev", "iLoop · Dubai", "New Tab", "New Tab", "New Tab",
                         "New Tab", "New Tab", "New Tab", "New Tab", "New Tab", "New Tab", "New Tab", "Sign In - Apple"]
            let colours: [UInt32] = [0x1A66C4, 0x222222, 0x7D2AE8, 0xD9654F, 0x222222, 0x3F9D78, 0x888888]
            var icons: [String: NSImage] = [:]
            let items = (0..<count).map { index -> TabItem in
                let name = count == 17 ? names[index] : names[index % names.count]
                icons["t\(index)"] = Self.image(colours[min(index, colours.count - 1)], letter: String(name.prefix(1)))
                return TabItem(id: "t\(index)", title: name, symbol: "globe", kind: "browser", active: index == active, closable: true)
            }
            return (TabsState(tabs: items, canNewTerminal: true, canNewBrowser: true), icons)
        }
        func strip(_ count: Int, active: Int, width: CGFloat) -> some View {
            let made = tabs(count, active: active)
            return TabStrip(state: made.0, favicons: made.1, width: width - 16, anchor: StripAnchorBox(), select: { _ in }, close: { _ in },
                            newTerminal: {}, newBrowser: {}, openInNewWindow: { _ in }, details: false)
                .padding(.horizontal, 8)
                .frame(width: width, height: 40, alignment: .bottom)
                .background(DeckTokens.frame)
        }
        for dark in [false, true] {
            NativeTerminalSettings.shared.preview(TerminalSchemes.app(dark: dark))
            // His window: 1916 wide, side panel 278: the strip gets about 1,620 pt.
            try render(VStack(spacing: 0) {
                strip(17, active: 15, width: 1620)
                strip(7, active: 5, width: 1620)
                strip(3, active: 0, width: 1620)
                strip(30, active: 2, width: 1620)
                strip(17, active: 15, width: 820)
            }, "header-tabs", dark, size: CGSize(width: 1620, height: 200))
        }
        NativeTerminalSettings.shared.preview(nil)
        // The strip's start: a stale reading far to the right no longer shortens it (the fault in his recording).
        XCTAssertEqual(TabStripLayout.start(detailMinX: 278, anchorMinX: 556, leadingFloor: 126), 282)
        XCTAssertEqual(TabStripLayout.start(detailMinX: 278, anchorMinX: 290, leadingFloor: 126), 290)
        XCTAssertEqual(TabStripLayout.start(detailMinX: 278, anchorMinX: -80, leadingFloor: 126), 282)
        XCTAssertEqual(TabStripLayout.start(detailMinX: 0, anchorMinX: nil, leadingFloor: 126), 126)
        XCTAssertEqual(TabStripLayout.width(windowWidth: 1916, detailMinX: 278, anchorMinX: 556, leadingFloor: 126,
                                            trailing: TabStripLayout.trailingMargin), 1622)
        // What the probe measured (header-room-probe.txt): 4 with nothing there, 40 for the button, 104 for the Cloud
        // word, 140 for both. Less, and the toolbar drops what sits there (or the strip) into its overflow menu.
        XCTAssertGreaterThanOrEqual(TabStripLayout.trailingMargin, 4)
        XCTAssertGreaterThanOrEqual(TabStripLayout.trailingButton, 40)
        XCTAssertGreaterThanOrEqual(TabStripLayout.trailingReserve, 104)
        XCTAssertGreaterThanOrEqual(TabStripLayout.trailingReserveAndButton, 140)
    }

    /// The tab on show is wider than the others (it keeps its title), so a held tab passes a neighbour when its edge
    /// crosses that neighbour's middle, and stays under the pointer while the others move aside.
    func testAHeldTabStaysUnderThePointerPastTheWiderTabOnShow() {
        var saved: [[String]] = []
        let reorder = NativeTabReorder(popOut: { _ in }, setTabOrder: { saved.append($0) })
        reorder.step = 72; reorder.stripHeight = 36
        reorder.widths = ["a": 70, "b": 120, "c": 70] // slots: a 0…70, b 72…192, c 194…264
        reorder.begin("a", in: ["a", "b", "c"])
        reorder.update(translation: 50, pointerY: 18, outsideWindow: false)
        XCTAssertEqual(reorder.order, ["a", "b", "c"], "its right edge (120) has not reached b's middle (132)")
        XCTAssertEqual(reorder.offset(for: "a"), 50)
        reorder.update(translation: 70, pointerY: 18, outsideWindow: false)
        XCTAssertEqual(reorder.order, ["b", "a", "c"])
        XCTAssertEqual(reorder.offset(for: "a"), 70 - 122, "its slot moved 122 right, so it is drawn 52 left of it: still 70 from where it began")
        reorder.update(translation: 130, pointerY: 18, outsideWindow: false)
        XCTAssertEqual(reorder.order, ["b", "a", "c"], "one step of 72 twice over would have jumped c too early")
        reorder.update(translation: 165, pointerY: 18, outsideWindow: false)
        XCTAssertEqual(reorder.order, ["b", "c", "a"])
        XCTAssertEqual(reorder.offset(for: "a"), 165 - 194)
        XCTAssertEqual(reorder.offset(for: "b"), 0)
        // Back to the left past both.
        reorder.update(translation: 20, pointerY: 18, outsideWindow: false)
        XCTAssertEqual(reorder.order, ["a", "b", "c"])
        reorder.update(translation: 70, pointerY: 18, outsideWindow: false)
        reorder.end()
        XCTAssertEqual(saved, [["b", "a", "c"]])
        // Without widths (every tab one width) the old rule holds: a step at a time.
        let plain = NativeTabReorder(popOut: { _ in }, setTabOrder: { _ in })
        plain.step = 120; plain.stripHeight = 36
        plain.begin("a", in: ["a", "b"])
        plain.update(translation: 70, pointerY: 18, outsideWindow: false)
        XCTAssertEqual(plain.order, ["b", "a"])
        XCTAssertEqual(plain.offset(for: "a"), 70 - 120)
    }

    private func render<V: View>(_ view: V, _ name: String, _ dark: Bool, size: CGSize) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
}

/// A measurement, not a check: how much room the window's toolbar needs at its right edge, read from a real toolbar
/// (the window is transparent and far off screen; nothing is shown). Run by hand with UI_BROWSER_TOOLBAR_PROBE=1.
@MainActor
final class BrowserHeaderRoomProbe: XCTestCase {
    @MainActor final class MarkBox { weak var view: NSView? }

    /// Marks a toolbar item's own view, so the probe can ask whether the toolbar kept it in the window.
    private struct Mark: NSViewRepresentable {
        let box: MarkBox
        func makeNSView(context: Context) -> NSView { let view = NSView(); box.view = view; return view }
        func updateNSView(_ view: NSView, context: Context) { box.view = view }
    }

    private struct Shell: View {
        let tabs: TabsState
        let icons: [String: NSImage]
        let trailing: CGFloat
        let popout: Bool
        let sidebar: Bool
        let box: StripAnchorBox
        let cloud: MarkBox
        let button: MarkBox
        @State private var width: CGFloat = 0
        @State private var detailMinX: CGFloat = 0

        var body: some View {
            NavigationSplitView(columnVisibility: .constant(sidebar ? .all : .detailOnly)) {
                Color.clear.navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 340)
            } detail: {
                Color.white
                    .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minX }) { x in detailMinX = x; box.remeasureSoon() }
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            TabStrip(state: tabs, favicons: icons,
                                     width: TabStripLayout.width(windowWidth: box.windowWidth ?? width, detailMinX: detailMinX,
                                                                 anchorMinX: box.minX, leadingFloor: box.leadingFloor, trailing: trailing),
                                     anchor: box, select: { _ in }, close: { _ in }, newTerminal: {}, newBrowser: {},
                                     openInNewWindow: { _ in }, details: false)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { w in width = w; box.remeasureSoon() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if !sidebar { Label("Needs you", systemImage: "cloud").labelStyle(.titleAndIcon).background(Mark(box: cloud)) }
                }
                ToolbarItem(placement: .primaryAction) {
                    if popout {
                        Button {} label: { Image(systemName: "arrow.up.forward.square").font(.system(size: 14)).frame(width: 28, height: 28) }
                            .buttonStyle(.borderless)
                            .background(Mark(box: button))
                    }
                }
            }
            .toolbar(removing: .title)
            .environment(\.appearsActive, true)
        }
    }

    func testMeasureTheRoomTheToolbarNeedsAtTheRight() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UI_BROWSER_TOOLBAR_PROBE"] == "1", "a measurement, run by hand")
        NSApplication.shared.setActivationPolicy(.accessory)
        var lines: [String] = []
        let icon = BrowserChromePictures.image(0x1A66C4, letter: "N")
        let items = (0..<17).map { TabItem(id: "t\($0)", title: "New Tab", symbol: "globe", kind: "browser", active: $0 == 15, closable: true) }
        let tabs = TabsState(tabs: items, canNewTerminal: true, canNewBrowser: true)
        let icons = Dictionary(uniqueKeysWithValues: items.map { ($0.id, icon) })
        for (label, popout, sidebar) in [("nothing at the right", false, true), ("move-to-window button", true, true),
                                         ("side panel hidden + cloud word", false, false), ("side panel hidden + cloud word + button", true, false)] {
            for trailing in [140, 120, 104, 96, 88, 80, 72, 64, 56, 48, 40, 32, 24, 16, 12, 8, 4] as [CGFloat] {
                let box = StripAnchorBox(), cloud = MarkBox(), button = MarkBox()
                let controller = NSHostingController(rootView: Shell(tabs: tabs, icons: icons, trailing: trailing, popout: popout,
                                                                     sidebar: sidebar, box: box, cloud: cloud, button: button))
                controller.sceneBridgingOptions = [.toolbars, .title]
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 600),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.ignoresMouseEvents = true
                window.alphaValue = 0
                window.contentViewController = controller
                window.toolbarStyle = .unifiedCompact
                window.setContentSize(NSSize(width: 1500, height: 600))
                window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
                window.orderBack(nil)
                for _ in 0..<12 {
                    window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                }
                box.remeasure()
                let view = box.view
                let inWindow = view?.window === window
                let frame = view.map { $0.convert($0.bounds, to: nil) } ?? .zero
                func shown(_ mark: MarkBox) -> String {
                    guard let view = mark.view else { return "absent" }
                    guard view.window === window else { return "PUSHED OUT" }
                    let at = view.convert(view.bounds, to: nil)
                    return at.maxX <= window.frame.width + 0.5 && at.minX >= frame.maxX - 0.5 ? "shown x \(Int(at.minX))…\(Int(at.maxX))" : "OVERLAPS x \(Int(at.minX))…\(Int(at.maxX))"
                }
                let fits = inWindow && frame.minX >= 0 && frame.maxX <= window.frame.width + 0.5 && frame.width > 600
                lines.append("\(label) | reserve \(Int(trailing)) | strip \(fits ? "FITS" : "does not fit") x \(Int(frame.minX))…\(Int(frame.maxX)) of \(Int(window.frame.width)) | cloud \(sidebar ? "-" : shown(cloud)) | button \(popout ? shown(button) : "-") | start read \(box.minX.map { String(Int($0)) } ?? "-") floor \(Int(box.leadingFloor))")
                window.orderOut(nil)
                window.contentViewController = nil
                window.close()
            }
        }
        let text = lines.joined(separator: "\n")
        print("BROWSER-HEADER-ROOM\n" + text)
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("night/ui-browser-evidence")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appendingPathComponent("header-room-probe.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(NSApp.isActive)
    }
}
