import SwiftUI
import TerminalDeckNativeCore

// The window's arrangement drawn in Swift (`layout/SplitView.tsx`, `SwarmGrid.tsx`,
// `shell/ModeSwitch.tsx`): the page decides what is where and publishes it in its
// `tabs` state (`WindowLayout`); every press goes back to it as a command.

/// `ModeSwitch`: one glyph — show two sessions side by side, or one on its own again.
struct NativeModeSwitch: View {
    let layout: WindowLayout

    var body: some View {
        let split = layout.mode == "split"
        let label = PaneRules.modeSwitchLabel(split: split, offer: layout.splitOffer)
        Button {
            AppModel.shared.web.run(.setMode(split ? "terminal" : "split"))
        } label: {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 14))
                .foregroundStyle(split ? Color.accentColor : (layout.splitOffer ? Color.secondary.opacity(0.6) : Color.secondary))
                .padding(4)
                .background(split ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 5))
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
    static func wants(kind: String) -> Bool {
        guard kind == "session" || kind == "browser", let layout = AppModel.shared.tabs?.layout else { return false }
        return layout.swarm || layout.splitting
    }

    /// The screen that would be shown on its own — what a window of its own shows.
    let kind: String
    let id: String
    @State private var inMainWindow = true

    var body: some View {
        Group {
            if !inMainWindow {
                // A pop-out window shows its one screen; the arrangement is the main window's.
                if kind == "browser" { NativeBrowserScreen(tabId: id) } else { NativeTerminalScreen(sessionId: id) }
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

    var body: some View {
        VStack(spacing: 0) {
            hostBar
            PaneTree(node: root, layout: layout)
                .padding(4)
        }
    }

    /// The window's own bar describes the host pane — the one drawn flush, with no bar of its own.
    @ViewBuilder private var hostBar: some View {
        let hostTab = root.leaves.first { $0.id == layout.primaryPaneId }?.tabId
        if let hostTab, SessionTarget(tabId: hostTab) != nil {
            NativeSessionHeader(session: NativeTerminalSessions.shared.session(for: hostTab))
        } else {
            HStack {
                Spacer()
                if layout.modeSwitch { NativeModeSwitch(layout: layout) }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
        }
    }
}

private struct PaneTree: View {
    let node: PaneNode
    let layout: WindowLayout

    var body: some View {
        switch node {
        case .leaf(let id, let tabId):
            PaneLeafView(paneId: id, tabId: tabId, layout: layout)
        case .split(let id, let horizontal, let ratio, let first, let second):
            SplitNodeView(splitId: id, horizontal: horizontal, ratio: ratio) {
                PaneTree(node: first, layout: layout)
            } second: {
                PaneTree(node: second, layout: layout)
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
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second
    @State private var dragging: Double?
    @FocusState private var focused: Bool
    static var bar: CGFloat { 8 }

    var body: some View {
        GeometryReader { box in
            let size = horizontal ? box.size.width : box.size.height
            let shown = dragging ?? ratio
            let free = max(0, size - Self.bar)
            let a = free * shown
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
        }
    }

    private func divider(size: Double) -> some View {
        Rectangle()
            .fill(focused || dragging != nil ? Color.accentColor.opacity(0.35) : Color.clear)
            .frame(width: horizontal ? Self.bar : nil, height: horizontal ? nil : Self.bar)
            .overlay(Rectangle().fill(.separator).frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1))
            .contentShape(.rect)
            .onHover { inside in
                if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
            }
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
                switch press.key {
                case back: send(ratio - PaneRules.keyStep)
                case forward: send(ratio + PaneRules.keyStep)
                case .home: send(0)
                case .end: send(1)
                case .return, .space: send(0.5)
                default: return .ignored
                }
                return .handled
            }
            .accessibilityLabel("Resize panes")
            .accessibilityValue("\(Int((ratio * 100).rounded()))%")
            .coordinateSpace(name: splitId)
    }

    private func send(_ value: Double) {
        AppModel.shared.web.run(.resizeSplit(splitId, ratio: PaneRules.clamp(value)))
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
            if let tabId, let target {
                let session = NativeTerminalSessions.shared.session(for: tabId)
                NativeSessionBody(session: session) {
                    if !primary { guestBar(session: session, target: target, title: tab?.title ?? "", focused: focused) }
                }
            } else if let tabId, tab?.kind == "browser" {
                VStack(spacing: 0) {
                    if !primary {
                        NativePaneBar(paneId: paneId, subject: .page(title: tab?.title ?? ""), focused: focused,
                                      onClose: close) { EmptyView() } controls: { EmptyView() }
                    }
                    NativeBrowserScreen(tabId: tabId)
                }
            } else {
                VStack(spacing: 0) {
                    NativePaneBar(paneId: paneId, subject: .empty, focused: focused, onClose: close) { EmptyView() } controls: { EmptyView() }
                    Color.clear
                }
            }
        }
        .clipShape(.rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused && !primary ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1.5))
        .simultaneousGesture(TapGesture().onEnded { if !focused { AppModel.shared.web.run(.focusPane(paneId)) } })
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
        AppModel.shared.web.run(.closePane(id))
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
                                action: PageEmptyAction(label: "New session", primary: true) { AppModel.shared.web.run(.newTerminalTab) })
            } else {
                let height = max(120, (box.size.height - 16 - gap * CGFloat(max(0, rows - 1))) / CGFloat(max(1, rows)))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: columns), spacing: gap) {
                    ForEach(sessions) { row in
                        cell(row, focused: row.id == active).frame(height: height)
                    }
                    ForEach(0..<spare, id: \.self) { _ in
                        Button { AppModel.shared.web.run(.newTerminalTab) } label: {
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
                if !focused { AppModel.shared.web.run(.selectTab(row.id)) }
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
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25),
                                                               lineWidth: focused ? 1.5 : 1))
        .simultaneousGesture(TapGesture().onEnded { if !focused { AppModel.shared.web.run(.selectTab(row.id)) } })
    }
}
