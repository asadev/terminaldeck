import AppKit
import SwiftUI
import TerminalDeckNativeCore

// The window's arrangement drawn in Swift (`layout/SplitView.tsx`, `SwarmGrid.tsx`,
// `shell/ModeSwitch.tsx`): the page decides what is where and publishes it in its
// `tabs` state (`WindowLayout`); native buttons now change the native window store.

/// `ModeSwitch`: one glyph — show two side by side (sessions or browser tabs), or one on its own again.
/// It sits at the end of the bar of what is on show: a session's header, or a browser's toolbar.
struct NativeModeSwitch: View {
    let layout: WindowLayout

    var body: some View {
        let split = layout.mode == "split"
        let label = PaneRules.modeSwitchLabel(split: split, offer: layout.splitOffer)
        Button {
            AppModel.shared.runButton(.setMode(split ? "terminal" : "split"))
        } label: {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 14))
                .foregroundStyle(split ? NativeSessionChrome.accent : (layout.splitOffer ? Color.secondary.opacity(0.6) : Color.secondary))
                .padding(4)
                .background(split ? NativeSessionChrome.accent.opacity(0.15) : .clear, in: .rect(cornerRadius: 5))
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(split ? .isSelected : [])
        .accessibilityElement(children: .contain)
    }
}

/// Split or swarm, when the page is showing one of them over a tab.
struct NativeLayoutScreen: View {
    /// Whether the main window's detail for this kind is the arrangement rather than one screen.
    @MainActor
    static func wants(kind: String, id: String) -> Bool {
        guard kind == "session" || kind == "browser" || kind == "hoot", let layout = AppModel.shared.tabs?.layout else { return false }
        // A native browser tab is the split while a pane holds it (Asad, 28 Oct: "browser in other side too");
        // otherwise it shows on its own, the split kept ready to return to.
        // A tab out in a window of its own is that window's page alone.
        if kind == "browser", BrowserTabsHook.provider?.browserTabs.contains(where: { $0.id == id }) == true {
            return layout.splitting && !layout.swarm && !AppModel.shared.poppedBrowserTabs.contains(id)
                && layout.root?.leaves.contains { $0.tabId == id } == true
        }
        return layout.swarm || layout.splitting
    }

    /// The main window is showing the split or swarm now (a pane's press may focus it only then).
    @MainActor
    static var isOnShow: Bool {
        let model = AppModel.shared
        guard let layout = model.tabs?.layout, layout.splitting || layout.swarm else { return false }
        guard let screen = model.currentScreen else { return true } // an empty focused pane keeps the split on show
        return wants(kind: screen.kind, id: screen.id)
    }

    /// The screen that would be shown on its own — what a window of its own shows.
    let kind: String
    let id: String
    @State private var inMainWindow = true

    var body: some View {
        Group {
            if !inMainWindow {
                // A pop-out window shows its one screen; the arrangement is the main window's.
                if kind == "browser" { NativeBrowserScreen(tabId: id) } else if kind == "hoot" { NativeHootScreen() } else { NativeTerminalScreen(sessionId: id) }
            } else if let layout = AppModel.shared.tabs?.layout {
                if layout.swarm {
                    NativeSwarmScreen(layout: layout)
                } else if let root = layout.root {
                    NativeSplitScreen(layout: layout, root: root)
                }
            }
        }
        .background(NativeWindowReader { window in
            inMainWindow = window == nil || window === AppModel.shared.web.webView.window
        })
    }
}

// MARK: - Split

private struct NativeSplitScreen: View {
    let layout: WindowLayout
    let root: PaneNode
    @Environment(\.paneDragSpace) private var dragSpace
    private let arrangement = NativePaneArrangement.shared

    /// Which pane shows in which slot: the page's tree, with the panes in the order the person dragged them to.
    private var arranged: (order: [String], slots: [String: (paneId: String, tabId: String?)]) {
        let tabLeaves = root.leaves.filter { $0.tabId != nil }
        let order = arrangement.arranged(tabLeaves.map { $0.tabId! })
        let byTab = Dictionary(tabLeaves.map { ($0.tabId!, $0.id) }, uniquingKeysWith: { first, _ in first })
        var slots: [String: (paneId: String, tabId: String?)] = [:]
        for (leaf, tabId) in zip(tabLeaves, order) { slots[leaf.id] = (byTab[tabId] ?? leaf.id, tabId) }
        return (order, slots)
    }

    var body: some View {
        let arranged = arranged
        VStack(spacing: 0) {
            hostBar
            PaneTree(node: root, layout: layout, slots: arranged.slots)
                .padding(4)
        }
        .onAppear { dragSpace?.leafOrder = arranged.order }
        .onChange(of: arranged.order) { _, order in dragSpace?.leafOrder = order }
    }

    /// The window's own bar describes the host pane — the one drawn flush, with no bar of its own.
    /// A browser host has its own toolbar (the split switch at its end), so nothing is drawn over it.
    @ViewBuilder private var hostBar: some View {
        let hostTab = root.leaves.first { $0.id == layout.primaryPaneId }?.tabId
        let model = AppModel.shared
        if let hostTab, model.paneHoldsBrowser(hostTab) {
            if !model.stripBrowserTabs.contains(where: { $0.id == hostTab }) { switchBar }
        } else if let hostTab, SessionTarget(tabId: hostTab) != nil {
            NativeSplitSessionHeader(sessionID: hostTab) {
                NativeSessionHeader(session: NativeTerminalSessions.shared.session(for: hostTab))
            }
        } else {
            switchBar
        }
    }

    private var switchBar: some View {
        HStack {
            Spacer()
            if layout.modeSwitch { NativeModeSwitch(layout: layout) }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }
}

/// The split's top bar is outside the pane body. Its owner boundary must travel with
/// the header itself, so an open rename client can never be rebound to another session.
struct NativeSplitSessionHeader<Header: View>: View {
    let sessionID: String
    @ViewBuilder var header: Header

    var body: some View {
        header.id(sessionID).nativeSessionInputScope(ownerID: sessionID)
    }
}

private struct PaneTree: View {
    let node: PaneNode
    let layout: WindowLayout
    var slots: [String: (paneId: String, tabId: String?)] = [:]

    private func shownTab(_ leaf: (id: String, tabId: String?)) -> String? { (slots[leaf.id]?.tabId) ?? leaf.tabId }

    /// The width the simulators docked inside this subtree want (they ride with their sessions).
    private func simulators(in node: PaneNode) -> (width: Double, count: Int) {
        node.leaves.reduce((0.0, 0)) { sum, leaf in
            guard let docked = shownTab(leaf).flatMap({ NativePaneArrangement.shared.dockedSimulators[$0] }) else { return sum }
            return (sum.0 + docked.width, sum.1 + docked.count)
        }
    }

    /// Two single panes whose places were swapped by dragging: the person's divider position goes with the panes.
    private func swapped(_ first: PaneNode, _ second: PaneNode) -> Bool {
        guard case .leaf(let a, let ownA) = first, case .leaf = second, ownA != nil else { return false }
        return slots[a]?.tabId != ownA
    }

    var body: some View {
        switch node {
        case .leaf(let id, let tabId):
            let shown = slots[id] ?? (id, tabId)
            PaneLeafView(paneId: shown.paneId, tabId: shown.tabId, layout: layout)
                .id(shown.paneId)
        case .split(let id, let horizontal, let ratio, let first, let second):
            SplitNodeView(splitId: id, horizontal: horizontal, ratio: ratio,
                          firstSimulators: simulators(in: first).width, secondSimulators: simulators(in: second).width,
                          firstCount: simulators(in: first).count, secondCount: simulators(in: second).count,
                          mirrored: swapped(first, second)) {
                PaneTree(node: first, layout: layout, slots: slots)
            } second: {
                PaneTree(node: second, layout: layout, slots: slots)
            }
        }
    }
}

/// Two panes and the divider between them: drag it (the new ratio goes to the page
/// when the drag ends), use the arrow keys, Home/End, or double-click / Return for half.
private struct SplitNodeView<First: View, Second: View>: View {
    let splitId: String
    let horizontal: Bool
    let ratio: Double
    var firstSimulators = 0.0
    var secondSimulators = 0.0
    var firstCount = 0
    var secondCount = 0
    var mirrored = false
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second
    @State private var dragging: Double?
    @FocusState private var focused: Bool
    static var bar: CGFloat { 8 }

    var body: some View {
        GeometryReader { box in
            let size = horizontal ? box.size.width : box.size.height
            // The ratio the page keeps is for the panes in the page's order; `mirrored` draws it the other way round.
            let own = mirrored ? 1 - ratio : ratio
            let shown = dragging ?? own
            let free = max(0, size - Self.bar)
            // Not dragged by the person (the page's default half): the sessions share the room equally,
            // each simulator riding with its session. Dragged: his sizes.
            let balanced = horizontal && dragging == nil && abs(ratio - 0.5) < 0.005 && (firstSimulators + secondSimulators) > 0
            let a = balanced ? NativePaneArrangement.balancedFirst(free: free, firstSimulators: firstSimulators, secondSimulators: secondSimulators,
                                                                   firstCount: max(1, firstCount), secondCount: max(1, secondCount))
                             : free * shown
            Group {
                if horizontal {
                    HStack(spacing: 0) {
                        first().frame(width: a)
                        divider(size: size)
                        second().frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        first().frame(height: a)
                        divider(size: size)
                        second().frame(maxHeight: .infinity)
                    }
                }
            }
            // The drag reads the pointer across the whole split, not inside the 8-pt bar.
            .coordinateSpace(name: splitId)
        }
    }

    private func divider(size: Double) -> some View {
        Rectangle()
            .fill(focused || dragging != nil ? Color.accentColor.opacity(0.35) : Color.clear)
            .frame(width: horizontal ? Self.bar : nil, height: horizontal ? nil : Self.bar)
            .overlay(Rectangle().fill(.separator).frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1))
            .contentShape(.rect)
            .nativeHoverCursor(horizontal ? .resizeLeftRight : .resizeUpDown)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(splitId))
                .onChanged { value in
                    let offset = horizontal ? value.location.x : value.location.y
                    dragging = PaneRules.dividerRatio(size: size, offset: offset, dividerPx: Self.bar,
                                                      minPanePx: PaneRules.minPanePx, fallback: ratio)
                }
                .onEnded { _ in
                    if let next = dragging { send(next) }
                    dragging = nil
                })
            .onTapGesture(count: 2) { send(0.5) }
            .focusable()
            .focused($focused)
            .onKeyPress { press in
                let back: KeyEquivalent = horizontal ? .leftArrow : .upArrow
                let forward: KeyEquivalent = horizontal ? .rightArrow : .downArrow
                let own = mirrored ? 1 - ratio : ratio
                switch press.key {
                case back: send(own - PaneRules.keyStep)
                case forward: send(own + PaneRules.keyStep)
                case .home: send(0)
                case .end: send(1)
                case .return, .space: send(0.5)
                default: return .ignored
                }
                return .handled
            }
            .accessibilityLabel("Resize panes")
            .accessibilityValue("\(Int((ratio * 100).rounded()))%")
    }

    /// `value` is the share of the pane drawn first; the page keeps it for its own first pane.
    private func send(_ value: Double) {
        AppModel.shared.runButton(.resizeSplit(splitId, ratio: PaneRules.clamp(mirrored ? 1 - value : value)))
    }
}

/// One pane: a guest gets its bar (name, folder, account, its own controls, close),
/// the host is drawn flush; pressing anywhere in it focuses it.
private struct PaneLeafView: View {
    let paneId: String
    let tabId: String?
    let layout: WindowLayout

    var body: some View {
        let focused = paneId == layout.focusedPaneId
        let primary = paneId == layout.primaryPaneId
        let tab = tabId.flatMap { id in AppModel.shared.tabs?.tabs.first { $0.id == id } }
        let target = tabId.flatMap(SessionTarget.init(tabId:))
        Group {
            // First: a browser tab's id is a UUID, like a local session's.
            if let tabId, AppModel.shared.paneHoldsBrowser(tabId) {
                browserPane(tabId: tabId, primary: primary, focused: focused)
            } else if let tabId, let target {
                let session = NativeTerminalSessions.shared.session(for: tabId)
                NativeSessionBody(session: session) {
                    if !primary {
                        guestBar(session: session, target: target, title: tab?.title ?? "", focused: focused)
                            .nativePaneDrag(.pane(tabId: tabId), title: tab?.title ?? "")
                    }
                }
                .environment(\.nativeTerminalSelected, focused)
            } else if let tabId, tab?.kind == "browser" {
                VStack(spacing: 0) {
                    if !primary {
                        NativePaneBar(paneId: paneId, subject: .page(title: tab?.title ?? ""), focused: focused,
                                      onClose: close) { EmptyView() } controls: { EmptyView() }
                            .nativePaneDrag(.pane(tabId: tabId), title: tab?.title ?? "")
                    }
                    NativeBrowserScreen(tabId: tabId)
                }
            } else if tab?.kind == "hoot" {
                NativeHootScreen()
            } else {
                VStack(spacing: 0) {
                    NativePaneBar(paneId: paneId, subject: .empty, focused: focused, onClose: close) { EmptyView() } controls: { EmptyView() }
                    // What fills it, and how (the strip's tabs; the next one chosen lands in the focused pane).
                    NativePageEmpty(symbol: "rectangle.split.2x1", title: "Nothing here yet") {
                        Text(focused ? "Choose a session or a browser tab in the tab bar to show it here."
                                     : "Click here, then choose a session or a browser tab in the tab bar.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NativeSessionChrome.ground)
                    .environment(\.colorScheme, NativeSessionChrome.scheme.isLight ? .light : .dark)
                }
            }
        }
        .modifier(PaneLeafZone(tabId: tabId))
        .clipShape(.rect(cornerRadius: 12))
        // Every session is a box, including the host and an unfocused duplicate.
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
            focused ? NativeSessionChrome.focusEdge : NativeSessionChrome.edge, lineWidth: 1))
        // A press anywhere in the pane focuses it — over a terminal or a web page too, whose own views take the
        // click before a SwiftUI gesture could see it.
        .background(NativePanePressWatcher {
            if !focused, NativeLayoutScreen.isOnShow { AppModel.shared.runButton(.focusPane(paneId)) }
        })
    }

    /// A browser tab in a pane: its full toolbar and page, as on its own. A guest pane has the pane bar over it
    /// (its picture, title, close, the handle to move it); the host's toolbar carries the split switch instead.
    @ViewBuilder
    private func browserPane(tabId: String, primary: Bool, focused: Bool) -> some View {
        let model = AppModel.shared
        let info = BrowserTabsHook.provider?.browserTabs.first { $0.id == tabId }
        let title = info?.title ?? "Browser"
        VStack(spacing: 0) {
            if !primary {
                NativePaneBar(paneId: paneId, subject: .browser(title: title, favicon: info?.favicon), focused: focused,
                              onClose: close) { EmptyView() } controls: { EmptyView() }
                    .nativePaneDrag(.pane(tabId: tabId), title: title)
            }
            if info != nil, model.poppedBrowserTabs.contains(tabId) {
                NativePageEmpty(symbol: "arrow.up.forward.square", title: "Open in its own window",
                                action: PageEmptyAction(label: "Show window", primary: true) {
                                    model.openScreenWindow(ScreenRef(kind: .browser, id: tabId), title: title)
                                }) { Text(title) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NativeSessionChrome.ground)
                    .environment(\.colorScheme, NativeSessionChrome.scheme.isLight ? .light : .dark)
            } else {
                NativeBrowserScreen(tabId: tabId, keyboard: focused, modeSwitch: primary)
            }
        }
    }

    @ViewBuilder
    private func guestBar(session: NativeTerminalSession, target: SessionTarget, title: String, focused: Bool) -> some View {
        let status = session.status ?? .idle
        switch target {
        case .local(let id):
            NativePaneBar(paneId: paneId,
                          subject: .session(id: id, title: title, status: session.ended ? .exited : status, isCopilot: false,
                                            folder: session.info?.cwd),
                          focused: focused, onClose: close, rename: { session.rename(to: $0) }) {
                NativeLocalAccountChip(session: session)
            } controls: {
                NativeSessionControls(session: session)
            }
        case .machine(let machineId, _):
            NativePaneBar(paneId: paneId,
                          subject: .elsewhere(title: title, where: "on \(NativeMachineLinks.shared.snapshot.names[machineId] ?? "that machine")", status: status),
                          focused: focused, onClose: close) { EmptyView() } controls: {
                NativeSessionControls(session: session)
            }
        case .server:
            NativePaneBar(paneId: paneId,
                          subject: .elsewhere(title: title, where: "on \(session.serverInfo?.serverName ?? "that server")", status: status),
                          focused: focused, onClose: close) { EmptyView() } controls: {
                NativeSessionControls(session: session)
            }
        }
    }

    private func close(_ id: String) {
        AppModel.shared.runButton(.closePane(id))
    }
}

/// Reports a mouse press inside this view's frame, without taking it: the terminal or web page under it still gets
/// the click. Only in its own window, never while a sheet is up or the view is hidden.
private struct NativePanePressWatcher: NSViewRepresentable {
    let pressed: @MainActor () -> Void

    func makeNSView(context: Context) -> WatchView {
        let view = WatchView()
        view.pressed = pressed
        return view
    }
    func updateNSView(_ view: WatchView, context: Context) { view.pressed = pressed }
    static func dismantleNSView(_ view: WatchView, coordinator: ()) { view.stop() }

    final class WatchView: NSView {
        var pressed: (@MainActor () -> Void)?
        private var monitor: Any?

        isolated deinit { stop() }

        /// Never the target of a click itself.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window, window.attachedSheet == nil,
                          !self.isHiddenOrHasHiddenAncestor,
                          self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return }
                    self.pressed?()
                }
                return event
            }
        }
    }
}

/// A pane is a place another pane can be dropped (left or right half).
private struct PaneLeafZone: ViewModifier {
    let tabId: String?
    func body(content: Content) -> some View {
        if let tabId { content.nativePaneDropZone("leaf:\(tabId)") } else { content }
    }
}

// MARK: - Swarm

/// `SwarmGrid`: every session at once, as square as the window allows, each with a
/// head (its dot and name) that brings it to the front; spare cells offer a new session.
private struct NativeSwarmScreen: View {
    let layout: WindowLayout

    var body: some View {
        let sessions = layout.swarmSessions
        let active = AppModel.shared.tabs?.activeID
        VStack(spacing: 0) {
            if let active, SessionTarget(tabId: active) != nil {
                NativeSessionHeader(session: NativeTerminalSessions.shared.session(for: active))
            }
            grid(sessions: sessions, active: active)
        }
    }

    private func grid(sessions: [SwarmSession], active: String?) -> some View {
        GeometryReader { box in
            let gap: CGFloat = 8
            let columns = PaneRules.swarmColumns(count: sessions.count, width: box.size.width - 16, gap: gap)
            let rows = PaneRules.swarmRows(count: sessions.count, columns: columns)
            let spare = columns * rows - sessions.count
            if sessions.isEmpty {
                NativePageEmpty(symbol: "square.grid.2x2", title: "No sessions",
                                action: PageEmptyAction(label: "New session", primary: true) { AppModel.shared.runButton(.newTerminalTab) })
            } else {
                let height = max(120, (box.size.height - 16 - gap * CGFloat(max(0, rows - 1))) / CGFloat(max(1, rows)))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: columns), spacing: gap) {
                    ForEach(sessions) { row in
                        cell(row, focused: row.id == active).frame(height: height)
                    }
                    ForEach(0..<spare, id: \.self) { _ in
                        Button { AppModel.shared.runButton(.newTerminalTab) } label: {
                            Image(systemName: "plus").font(.system(size: 16)).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .buttonStyle(.plain)
                        .frame(height: height)
                        .background(.quaternary.opacity(0.2), in: .rect(cornerRadius: 8))
                        .help("New session")
                        .accessibilityLabel("New session")
                    }
                }
                .padding(8)
            }
        }
    }

    private func cell(_ row: SwarmSession, focused: Bool) -> some View {
        let status = TerminalStatus.parse(row.status) ?? .idle
        let session = NativeTerminalSessions.shared.session(for: row.id)
        return NativeSessionBody(session: session) {
            Button {
                if !focused { AppModel.shared.runButton(.selectTab(row.id)) }
            } label: {
                HStack(spacing: 6) {
                    NativeSessionStatusDot(status: status)
                    Text(row.title).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(row.title)
            .accessibilityAddTraits(focused ? .isSelected : [])
        }
        .environment(\.nativeTerminalSelected, focused)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? NativeSessionChrome.focusEdge : NativeSessionChrome.edge,
                                                               lineWidth: 1))
        .simultaneousGesture(TapGesture().onEnded { if !focused { AppModel.shared.runButton(.selectTab(row.id)) } })
    }
}
