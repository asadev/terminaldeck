import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Shared session paper and ink. The renderer's selected tab and terminal use
/// the same ground (tokens.css); selection glyphs share its one accent.
@MainActor
enum NativeSessionChrome {
    static var scheme: TerminalScheme { NativeTerminalSettings.shared.scheme }
    static var ground: Color { Color(nsColor: scheme.colour(scheme.background, fallback: .textBackgroundColor)) }
    static var ink: Color { Color(nsColor: scheme.colour(scheme.foreground, fallback: .labelColor)) }
    static var secondaryInk: Color { ink.opacity(0.65) }
    static var accent: Color {
        Color(nsColor: (TerminalColour(hex: scheme.isLight ? "#1a66c4" : "#3b8fee")!).nsColor)
    }
    static var edge: Color { border(light: scheme.isLight) }
    static func border(light: Bool) -> Color { light ? Color(red: 56 / 255, green: 56 / 255, blue: 56 / 255).opacity(0.18) : .white.opacity(0.17) }
    static var focusEdge: Color { accent.opacity(scheme.isLight ? 0.62 : 1) }
    static func cardGround(emphasized: Bool, light: Bool) -> Color {
        let hex = light ? (emphasized ? "#ededed" : "#f5f5f5") : (emphasized ? "#252525" : "#202020")
        return Color(nsColor: TerminalColour(hex: hex)!.nsColor)
    }
}

// The session tabs, inside the toolbar row itself (one slim 40 pt header).
//
// SwiftUI toolbar items take their ideal width and will not stretch, so the strip
// is given an explicit width: from where it starts in the window to the window's
// right edge, less only the room a toolbar button there needs while one shows.
//
// 18 Nov 2026 (owner: "it should spread in overall the space in the header, but it is keep squeezing here, and we
// have a lot of empty space"): 17 tabs were 68 pt each beside an empty third of the bar. Two causes. The strip's
// start was taken from an AppKit reading that is made only on a resize and stayed stale after the toolbar moved the
// strip; a stale reading can no longer shorten the strip (see `start`). And 104 pt were always kept free at the
// right for two toolbar buttons that left the app on 7 Oct; now only what shows there is given room.

enum TabStripLayout {
    // Room kept free at the window's right edge, for what shows there and only that. Measured in a real toolbar on
    // macOS 27.3 (18 Nov, BrowserHeaderRoomProbe): with less, the toolbar pushes the button or the Cloud word (or, when
    // the side panel is hidden, the whole strip) into its overflow menu.
    /// The side panel is hidden: the Cloud line's short form sits there (its longest word needs 104).
    static let trailingReserve: CGFloat = 104
    /// A page's "Move to new window" button shows there (it needs 40).
    static let trailingButton: CGFloat = 48
    /// Both (they need 140 together; with 104 the toolbar dropped both).
    static let trailingReserveAndButton: CGFloat = 140
    /// Nothing shows there (a session, a browser or a device tab is on show): the window's own margin (the toolbar
    /// needs 4; 12 is the margin the rest of the frame uses).
    static let trailingMargin: CGFloat = 12
    static let minimumWidth: CGFloat = 0
    /// The toolbar's own height: the selected tab runs the full way down, into the page.
    static let height: CGFloat = 36
    /// Air above the tabs, as Chrome leaves.
    static let topInset: CGFloat = 5
    /// The selected tab's outward curves at its foot reach this far past each side.
    static let flare: CGFloat = 8
    /// The one "+" at the strip's right end (a new browser tab).
    static let plusWidth: CGFloat = 30
    /// How far right of its expected start a reading of the strip's own position may be and still count.
    static let anchorTolerance: CGFloat = 40

    /// Where the strip starts in the window. Never left of the page column (4 pt in from it) nor of `leadingFloor`
    /// (right of the traffic lights and the sidebar toggle when the side panel is hidden). The strip's own reading
    /// (`anchorMinX`) refines that only when it is a little further right: while the strip sits in the toolbar's
    /// overflow menu it reads nonsense such as -80, and after the toolbar has moved the strip it can be hundreds of
    /// points stale, which squeezed the tabs.
    static func start(detailMinX: CGFloat, anchorMinX: CGFloat?, leadingFloor: CGFloat = 0) -> CGFloat {
        let expected = max(detailMinX + 4, leadingFloor)
        guard let anchorMinX, anchorMinX > expected, anchorMinX <= expected + anchorTolerance else { return expected }
        return anchorMinX
    }

    /// `trailing`: the room kept free at the window's right edge (one of the four above).
    static func width(windowWidth: CGFloat, detailMinX: CGFloat, anchorMinX: CGFloat?, leadingFloor: CGFloat = 0,
                      trailing: CGFloat = trailingReserve) -> CGFloat {
        let stripMinX = start(detailMinX: detailMinX, anchorMinX: anchorMinX, leadingFloor: leadingFloor)
        return max(minimumWidth, (windowWidth - stripMinX - trailing).rounded(.down))
    }
}

/// Knows where the strip starts in window coordinates.
@MainActor
@Observable
final class StripAnchorBox {
    var minX: CGFloat?
    @ObservationIgnored weak var view: NSView?

    /// Where the window's traffic lights and the sidebar toggle end: the strip never starts left of this.
    var leadingFloor: CGFloat = 0
    /// The window's own width, read from the window (nil until the strip is in one).
    var windowWidth: CGFloat?
    /// Space between the strip's foot and the top of the page (the toolbar is taller than the
    /// strip). The selected tab reaches down across it, so it meets the page with no line.
    var footGap: CGFloat = 0

    func remeasure() {
        guard let view, let window = view.window else { return }
        let x = view.convert(view.bounds, to: nil).minX.rounded()
        if x != minX { minX = x }
        let width = window.frame.width.rounded()
        if width != windowWidth { windowWidth = width }
        // The three lights (not there in full screen), then the system's sidebar toggle (~34 pt) and a little air.
        var floor: CGFloat = 0
        if !window.styleMask.contains(.fullScreen), let zoom = window.standardWindowButton(.zoomButton) {
            floor = zoom.convert(zoom.bounds, to: nil).maxX + 12
        }
        let next = (floor + 34 + 8).rounded()
        if next != leadingFloor { leadingFloor = next }
        let strip = view.convert(view.bounds, to: nil)
        let gap = min(12, max(0, (strip.minY - window.contentLayoutRect.maxY).rounded()))
        if gap != footGap { footGap = gap }
    }

    /// Now, and again once a sidebar animation has settled.
    func remeasureSoon() {
        remeasure()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            self?.remeasure()
            try? await Task.sleep(for: .milliseconds(340))
            self?.remeasure()
        }
    }
}

private struct StripAnchor: NSViewRepresentable {
    let box: StripAnchorBox

    final class AnchorView: NSView {
        var onWindow: (() -> Void)?
        /// A press and drag on the tabs must move the tab, never the window (the strip sits in the title area).
        override var mouseDownCanMoveWindow: Bool { false }
        private var observers: [any NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?()
            // Read the start again after every resize, full-screen change and sidebar change.
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                         NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onWindow?() }
                })
            }
        }
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        box.view = view
        view.onWindow = { [weak box] in
            MainActor.assumeIsolated { box?.remeasureSoon() }
        }
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        box.view = nsView
    }
}

struct TabStrip: View {
    let state: TabsState
    /// Native browser tabs show their site's icon.
    var favicons: [String: NSImage] = [:]
    let width: CGFloat
    let anchor: StripAnchorBox
    let select: (String) -> Void
    let close: (String) -> Void
    let newTerminal: () -> Void
    let newBrowser: () -> Void
    let openInNewWindow: (TabItem) -> Void
    /// Whether a tab's menu offers "Open in Split View" (a session or browser tab not on show, not in a pane yet).
    var splitOffered: (TabItem) -> Bool = { _ in false }
    var openInSplit: (TabItem) -> Void = { _ in }
    /// Wide tabs show their project picture, status mark and browser chips (false only in pictures drawn without the app).
    var details = true

    var body: some View {
        // ONE "+" (owner, 18 Nov: "remove this terminal icon from the header ... one plus icon in this right corner").
        let plusWidth = state.canNewBrowser ? TabStripLayout.plusWidth : 0
        // The selected tab's pill wears the page's colour; the other pills stay quiet on the header glass.
        let activeTab = state.tabs.first(where: \.active)
        let paper = activeTab.map { NativeChrome.usesPaper(kind: $0.kind, id: $0.id) } ?? false
        let flare = TabStripLayout.flare
        let available = max(0, width - plusWidth - 2 * flare)

        // The tabs in the order the person arranged them; while one is held, the others have already moved aside.
        let reorder = NativeTabReorder.shared
        let ids = state.tabs.map(\.id)
        let order = reorder.dragID != nil ? TabOrderRules.arranged(ids, saved: reorder.order) : NativeSessionRailContinuity.shared.arrangedHeader(NativePaneArrangement.shared.arrangedTabs(ids))
        let tabs = order.compactMap { id in state.tabs.first { $0.id == id } }
        // Every tab's width: the room shared out, the tab on show never too narrow for its title.
        let widths = TabStripMetrics.widths(count: tabs.count, activeIndex: tabs.firstIndex(where: \.active),
                                            available: Double(available)).map { CGFloat($0) }
        let content = CGFloat(TabStripMetrics.contentWidth(widths.map { Double($0) }))
        let viewportWidth = min(content, available) + 2 * flare
        let common = widths.min() ?? 0
        let step = common + CGFloat(TabStripMetrics.spacing)
        let widthByID = Dictionary(zip(tabs.map(\.id), widths), uniquingKeysWith: { first, _ in first })

        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: CGFloat(TabStripMetrics.spacing)) {
                        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                            let tabWidth = index < widths.count ? widths[index] : common
                            TabChip(tab: tab,
                                    availableWidth: tabWidth,
                                    paper: paper,
                                    favicon: favicons[tab.id],
                                    select: { select(tab.id) },
                                    close: { close(tab.id) },
                                    openInNewWindow: { openInNewWindow(tab) },
                                    openInSplit: splitOffered(tab) ? { openInSplit(tab) } : nil,
                                    details: details)
                                .frame(width: tabWidth)
                                .offset(x: reorder.offset(for: tab.id))
                                .zIndex(reorder.dragID == tab.id ? 1 : 0)
                                .opacity(reorder.dragID == tab.id && reorder.popping ? 0.55 : 1)
                                // Grab a tab and slide it: the others move aside; far out of the strip it pops out.
                                .simultaneousGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("tabstrip"))
                                    .onChanged { value in
                                        reorder.begin(tab.id, in: order)
                                        reorder.update(translation: value.translation.width, pointerY: value.location.y,
                                                       outsideWindow: NativePaneDragSpace.pointerOutsideWindow())
                                    }
                                    .onEnded { value in
                                        reorder.update(translation: value.translation.width, pointerY: value.location.y,
                                                       outsideWindow: NativePaneDragSpace.pointerOutsideWindow())
                                        reorder.end()
                                    })
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, flare)
                }
                .frame(width: viewportWidth)
                .scrollClipDisabled()
                .mask(alignment: .top) {
                    Rectangle().frame(width: viewportWidth, height: TabStripLayout.height + anchor.footGap)
                }
                .onAppear {
                    if let active = state.activeID { proxy.scrollTo(active) }
                }
                .onChange(of: state.activeID) { _, active in
                    guard let active else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(active) }
                }
            }

            // The "+" keeps the header's right corner, however few tabs there are.
            Spacer(minLength: 0)
            if state.canNewBrowser {
                StripNewTabButton(newBrowser: newBrowser, newTerminal: state.canNewTerminal ? newTerminal : nil)
            }
        }
        // No tabs: just the "+", so the window title (shown then) keeps its room: a full-width empty strip pushed
        // it into the toolbar's overflow menu.
        .frame(width: state.tabs.isEmpty ? plusWidth + 8 : width, height: TabStripLayout.height)
        .coordinateSpace(name: "tabstrip")
        .onAppear { reorder.step = step; reorder.widths = widthByID; reorder.stripHeight = TabStripLayout.height }
        .onChange(of: step) { _, next in reorder.step = next }
        .onChange(of: widthByID) { _, next in reorder.widths = next }
        // The toolbar may move the strip when its width changes: read where it starts again.
        .onChange(of: width) { _, _ in anchor.remeasureSoon() }
        // No fill: the strip sits on the window's sidebar glass, like the side panel.
        .background(StripAnchor(box: anchor))
    }
}

/// The header's one "+": a new browser tab (a new session starts from the side panel). A right-click still offers
/// the terminal tab the old second button made, so nothing that worked is lost.
struct StripNewTabButton: View {
    let newBrowser: () -> Void
    var newTerminal: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        Button(action: newBrowser) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .frame(width: TabStripLayout.plusWidth, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help("New browser tab")
        .accessibilityLabel("New browser tab")
        .contextMenu {
            Button("New Browser Tab", action: newBrowser)
            if let newTerminal { Button("New Terminal Tab", action: newTerminal) }
        }
    }
}

/// A tab's name: whole when it fits, else cut at the tab's edge with a short fade (never "N…").
struct TabChipTitle: View {
    let text: String
    let weight: Font.Weight
    static let fade: CGFloat = 14

    private var label: some View {
        Text(text).font(.system(size: 12, weight: weight)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            label
            label
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                .mask {
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: Self.fade)
                    }
                }
        }
        .accessibilityLabel(text)
    }
}

/// One compact tab: the active one is emphasised; ✕ replaces the icon on hover.
/// The tab is a real Button (clicks, keyboard and VoiceOver all select it); the ✕
/// is a separate button laid over the icon spot, so the two never nest.
struct TabChip: View {
    let tab: TabItem
    var availableWidth: CGFloat = 220
    private var iconOnly: Bool { availableWidth < CGFloat(TabStripMetrics.titleFrom) }
    private var wide: Bool { availableWidth >= 140 }
    private var showsDetails: Bool { details && wide }
    /// The page on show is the terminal paper (else the plain window background).
    var paper = false
    var favicon: NSImage? = nil
    let select: () -> Void
    let close: () -> Void
    let openInNewWindow: () -> Void
    /// "Open in Split View": this tab beside the one on show (nil: not offered for this tab).
    var openInSplit: (() -> Void)? = nil
    /// From 140 pt a tab shows its project picture, status mark and browser chips.
    var details = true
    @State private var hovering = false

    private var showsClose: Bool { hovering && tab.closable }
    /// The selected tab's ink is the page's: terminal ink on the paper, the system's otherwise.
    private var activeInk: Color { paper ? NativeSessionChrome.ink : Color.primary }
    private var activeAccent: Color { paper ? NativeSessionChrome.accent : Color.accentColor }

    /// Every tab is a pill (owner, 18 Nov, with the tab row on screen: "make all of these as pill"): 26 pt high, a
    /// quiet fill; the one on show wears the page's colour and a hairline, so it reads as the raised one.
    private var chipBackground: some View {
        Capsule(style: .continuous)
            .fill(tab.active ? AnyShapeStyle(NativeChrome.page(kind: tab.kind, id: tab.id))
                             : AnyShapeStyle(Color.primary.opacity(hovering ? 0.10 : 0.055)))
            .overlay {
                if tab.active { Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.16), lineWidth: 1) }
            }
            .shadow(color: .black.opacity(tab.active ? 0.10 : 0), radius: 1.5, y: 0.5)
            .padding(.top, TabStripLayout.topInset + 2)
            .padding(.bottom, 3)
            .padding(.horizontal, 1)
    }

    var body: some View {
        Button {
            if !tab.active { select() }
        } label: {
            HStack(spacing: 5) {
                Group {
                    if showsClose {
                        Color.clear // the ✕ overlay sits here
                    } else if tab.isHoot {
                        HootMark(size: 15)
                    } else if let favicon {
                        Image(nsImage: favicon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 14, height: 14)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    } else {
                        // AGT: a shell tab with an AI typed into it shows that AI's icon.
                        Image(systemName: AGTShellAgentBadges.shared.symbol(for: tab.id) ?? SymbolName.resolve(tab.symbol, fallback: TabItem.defaultSymbol(kind: tab.kind)))
                            .font(.system(size: 11.5))
                            .foregroundStyle(tab.active ? activeAccent : Color.secondary)
                    }
                }
                .frame(width: 16, height: 16)

                if showsDetails && (tab.kind == "session" || tab.kind == "terminal") {
                    let state = AppModel.shared.visibleSidebar
                    let project = state.flatMap { SIDEBARLayout.project(for: tab.id, in: $0) }
                    if let project {
                        ProjectLogoView(project: SHELLRoutes.project(forPath: project.id), name: project.title, size: 13)
                    }
                }

                if !iconOnly {
                    TabChipTitle(text: tab.title, weight: tab.active ? .medium : .regular)
                        .layoutPriority(1) // the name takes the room first; the marks after it keep their own size
                    Spacer(minLength: 0)
                    if showsDetails {
                        StatusMark(status: tab.status)
                        NativeBRBindChips(kind: tab.kind, id: tab.id, server: tab.server, name: tab.title)
                    }
                    if tab.unread {
                        Circle().fill(.tint).frame(width: 6, height: 6).accessibilityLabel("Unread")
                    }
                }
            }
            .padding(.horizontal, wide ? 10 : 8)
            .padding(.top, TabStripLayout.topInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(tab.active ? activeInk : Color.secondary)
            .clipped()
            .background { chipBackground }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            if showsClose {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill((tab.active ? activeInk : Color.primary).opacity(0.12)).frame(width: 16, height: 16))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab.active ? activeInk : Color.secondary)
                .padding(.leading, iconOnly ? max(0, (availableWidth - 28) / 2) : (wide ? 4 : 2))
                .help("Close Tab")
                .accessibilityLabel("Close \(tab.title)")
            }
        }
        .overlay(alignment: .topTrailing) {
            if iconOnly && tab.unread {
                Circle().fill(.tint).frame(width: 5, height: 5).padding(.top, 8).padding(.trailing, 5)
                    .accessibilityLabel("Unread")
            }
        }
        .onHover { hovering = $0 }
        .help([tab.title, tab.status.map { StatusMeaning($0).label }].compactMap { $0 }.joined(separator: " — "))
        .contextMenu {
            if let openInSplit { Button("Open in Split View", action: openInSplit) }
            Button("Open in New Window", action: openInNewWindow)
            if tab.closable {
                Divider()
                Button("Close Tab", action: close)
            }
        }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(tab.active ? .isSelected : [])
    }
}
