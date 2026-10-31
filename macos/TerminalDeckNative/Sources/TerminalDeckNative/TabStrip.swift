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
// is given an explicit width: from where it actually starts in the window (read by
// a tiny AppKit anchor, because that moves when the sidebar is shown or hidden) to
// just before the New Session / Settings buttons. Measured on macOS 27: those two
// glass buttons need 100 pt at the right edge; 104 keeps a little air.

enum TabStripLayout {
    /// Room kept at the window's right edge for the New Session + Settings buttons.
    static let trailingReserve: CGFloat = 104
    static let minimumWidth: CGFloat = 0
    /// The toolbar's own height: the selected tab runs the full way down, into the page.
    static let height: CGFloat = 36
    /// Air above the tabs, as Chrome leaves.
    static let topInset: CGFloat = 5
    /// The selected tab's outward curves at its foot reach this far past each side.
    static let flare: CGFloat = 8
    static let buttonWidth: CGFloat = 28

    /// The strip never starts left of the page column (4 pt in from it); the anchor's
    /// reading counts only when it is further right than that — e.g. after the traffic
    /// lights when the sidebar is hidden. (While the strip sits in the toolbar's overflow
    /// menu the anchor reads nonsense such as -80, which this ignores.)
    /// `leadingFloor` is the first x the strip may start at: right of the traffic lights and the sidebar toggle,
    /// whatever the anchor last read (a resize, a sidebar collapse or full screen can leave that stale).
    static func width(windowWidth: CGFloat, detailMinX: CGFloat, anchorMinX: CGFloat?, leadingFloor: CGFloat = 0) -> CGFloat {
        let stripMinX = max(detailMinX + 4, anchorMinX ?? 0, leadingFloor)
        return max(minimumWidth, (windowWidth - stripMinX - trailingReserve).rounded(.down))
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
    /// Space between the strip's foot and the top of the page (the toolbar is taller than the
    /// strip). The selected tab reaches down across it, so it meets the page with no line.
    var footGap: CGFloat = 0

    func remeasure() {
        guard let view, let window = view.window else { return }
        let x = view.convert(view.bounds, to: nil).minX.rounded()
        if x != minX { minX = x }
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

    var body: some View {
        let buttons = (state.canNewTerminal ? 1 : 0) + (state.canNewBrowser ? 1 : 0)
        let buttonsWidth = CGFloat(buttons) * TabStripLayout.buttonWidth + (buttons > 0 ? 4 : 0)
        // The selected tab joins the page; the other tabs stay on the header glass.
        let activeTab = state.tabs.first(where: \.active)
        let paper = activeTab.map { NativeChrome.usesPaper(kind: $0.kind, id: $0.id) } ?? false
        let flare = TabStripLayout.flare
        let available = max(0, width - buttonsWidth - 2 * flare)
        let tabWidth = CGFloat(TabStripMetrics.tabWidth(count: state.tabs.count, available: Double(available)))
        let content = CGFloat(TabStripMetrics.contentWidth(count: state.tabs.count, tabWidth: Double(tabWidth)))
        let viewportWidth = min(content, available) + 2 * flare

        // The tabs in the order the person arranged them; while one is held, the others have already moved aside.
        let reorder = NativeTabReorder.shared
        let ids = state.tabs.map(\.id)
        let order = reorder.dragID != nil ? TabOrderRules.arranged(ids, saved: reorder.order) : NativeSessionRailContinuity.shared.arrangedHeader(NativePaneArrangement.shared.arrangedTabs(ids))
        let tabs = order.compactMap { id in state.tabs.first { $0.id == id } }
        let step = tabWidth + CGFloat(TabStripMetrics.spacing)

        HStack(spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: CGFloat(TabStripMetrics.spacing)) {
                        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                            TabChip(tab: tab,
                                    availableWidth: tabWidth,
                                    paper: paper,
                                    footGap: anchor.footGap,
                                    separatorAfter: index < tabs.count - 1 && !tab.active && !tabs[index + 1].active && reorder.dragID == nil,
                                    favicon: favicons[tab.id],
                                    select: { select(tab.id) },
                                    close: { close(tab.id) },
                                    openInNewWindow: { openInNewWindow(tab) },
                                    openInSplit: splitOffered(tab) ? { openInSplit(tab) } : nil)
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

            if state.canNewTerminal {
                StripButton(symbol: "terminal", help: "New terminal tab", action: newTerminal)
            }
            if state.canNewBrowser {
                StripButton(symbol: "globe", help: "New browser tab", action: newBrowser)
            }
            Spacer(minLength: 0)
        }
        // No tabs: just the two buttons, so the window title (shown then) and the
        // glass buttons keep their room — a full-width empty strip pushed them into
        // the toolbar's overflow menu.
        .frame(width: state.tabs.isEmpty ? buttonsWidth + 8 : width, height: TabStripLayout.height)
        .coordinateSpace(name: "tabstrip")
        .onAppear { reorder.step = step; reorder.stripHeight = TabStripLayout.height }
        .onChange(of: step) { _, next in reorder.step = next }
        // No fill: the strip sits on the window's sidebar glass, like the side panel.
        .background(StripAnchor(box: anchor))
    }
}

private struct StripButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                // A small + on the icon's top-right corner says "new" (Asad, 2026-10-07:
                // this replaces the separate + in the toolbar).
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "plus")
                        .font(.system(size: 8.5, weight: .heavy))
                        .offset(x: 5, y: -5) // its first spot, a little higher (Asad, 2026-10-07)
                }
                .frame(width: TabStripLayout.buttonWidth, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One compact tab: the active one is emphasised; ✕ replaces the icon on hover.
/// The tab is a real Button (clicks, keyboard and VoiceOver all select it); the ✕
/// is a separate button laid over the icon spot, so the two never nest.
struct TabChip: View {
    let tab: TabItem
    var availableWidth: CGFloat = 220
    private var iconOnly: Bool { availableWidth < 64 }
    private var showsDetails: Bool { availableWidth >= 140 }
    /// The page on show is the terminal paper (else the plain window background).
    var paper = false
    /// How far the selected tab reaches below the strip to meet the page (see StripAnchorBox).
    var footGap: CGFloat = 0
    /// A thin line after this tab (between two unselected tabs, as Chrome draws them).
    var separatorAfter = false
    var favicon: NSImage? = nil
    let select: () -> Void
    let close: () -> Void
    let openInNewWindow: () -> Void
    /// "Open in Split View": this tab beside the one on show (nil: not offered for this tab).
    var openInSplit: (() -> Void)? = nil
    @State private var hovering = false

    private var showsClose: Bool { hovering && tab.closable }
    /// The selected tab's ink is the page's: terminal ink on the paper, the system's otherwise.
    private var activeInk: Color { paper ? NativeSessionChrome.ink : Color.primary }
    private var activeAccent: Color { paper ? NativeSessionChrome.accent : Color.accentColor }

    /// The selected tab flows into the page; only unselected tabs have a hover wash.
    @ViewBuilder private var chipBackground: some View {
        if tab.active {
            NativeChromeTabShape(corner: 8, flare: TabStripLayout.flare)
                .fill(NativeChrome.page(kind: tab.kind, id: tab.id))
                .padding(.top, TabStripLayout.topInset)
                .padding(.bottom, -footGap)
                .padding(.horizontal, -TabStripLayout.flare)
        } else if hovering {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .padding(.top, TabStripLayout.topInset + 3)
                .padding(.bottom, 4)
        }
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
                    Text(tab.title)
                        .font(.system(size: 12, weight: tab.active ? .medium : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
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
            .padding(.horizontal, showsDetails ? 10 : 8)
            .padding(.top, TabStripLayout.topInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(tab.active ? activeInk : Color.secondary)
            .clipped()
            .background { chipBackground }
            .overlay(alignment: .trailing) {
                // Between two unselected tabs: a thin line, in the gap.
                if separatorAfter && !hovering {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 1, height: 14)
                        .offset(x: CGFloat(TabStripMetrics.spacing) / 2 + 0.5)
                }
            }
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
                .padding(.leading, iconOnly ? max(0, (availableWidth - 28) / 2) : (showsDetails ? 4 : 2))
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
