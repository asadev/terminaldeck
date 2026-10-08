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
    static let minimumWidth: CGFloat = 160
    static let height: CGFloat = 28
    static let buttonWidth: CGFloat = 28

    /// The strip never starts left of the page column (4 pt in from it); the anchor's
    /// reading counts only when it is further right than that — e.g. after the traffic
    /// lights when the sidebar is hidden. (While the strip sits in the toolbar's overflow
    /// menu the anchor reads nonsense such as -80, which this ignores.)
    static func width(windowWidth: CGFloat, detailMinX: CGFloat, anchorMinX: CGFloat?) -> CGFloat {
        let stripMinX = max(detailMinX + 4, anchorMinX ?? 0)
        return max(minimumWidth, (windowWidth - stripMinX - trailingReserve).rounded(.down))
    }
}

/// Knows where the strip starts in window coordinates.
@MainActor
@Observable
final class StripAnchorBox {
    var minX: CGFloat?
    @ObservationIgnored weak var view: NSView?

    func remeasure() {
        guard let view, view.window != nil else { return }
        let x = view.convert(view.bounds, to: nil).minX.rounded()
        if x != minX { minX = x }
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
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?()
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

    var body: some View {
        let buttons = (state.canNewTerminal ? 1 : 0) + (state.canNewBrowser ? 1 : 0)
        let buttonsWidth = CGFloat(buttons) * TabStripLayout.buttonWidth + (buttons > 0 ? 4 : 0)
        let available = max(0, width - buttonsWidth)
        let tabWidth = CGFloat(TabStripMetrics.tabWidth(count: state.tabs.count, available: Double(available)))
        let content = CGFloat(TabStripMetrics.contentWidth(count: state.tabs.count, tabWidth: Double(tabWidth)))

        HStack(spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: CGFloat(TabStripMetrics.spacing)) {
                        ForEach(state.tabs) { tab in
                            TabChip(tab: tab,
                                    favicon: favicons[tab.id],
                                    select: { select(tab.id) },
                                    close: { close(tab.id) },
                                    openInNewWindow: { openInNewWindow(tab) })
                                .frame(width: tabWidth)
                                .id(tab.id)
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(width: min(content, available))
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
                .frame(width: TabStripLayout.buttonWidth, height: 24)
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
    var favicon: NSImage? = nil
    let select: () -> Void
    let close: () -> Void
    let openInNewWindow: () -> Void
    @State private var hovering = false

    private var showsClose: Bool { hovering && tab.closable }

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
                        Image(systemName: SymbolName.resolve(tab.symbol, fallback: TabItem.defaultSymbol(kind: tab.kind)))
                            .font(.system(size: 11.5))
                            .foregroundStyle(tab.active ? NativeSessionChrome.accent : Color.secondary)
                    }
                }
                .frame(width: 16, height: 16)

                Text(tab.title)
                    .font(.system(size: 12, weight: tab.active ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                StatusMark(status: tab.status)
                NativeBRBindChips(kind: tab.kind, id: tab.id, server: tab.server, name: tab.title) // lane BR: B1 chips (WorkspaceTabStrip.tsx)
                if tab.unread {
                    Circle()
                        .fill(.tint)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Unread")
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .foregroundStyle(tab.active ? NativeSessionChrome.ink : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tab.active ? NativeSessionChrome.ground : Color.primary.opacity(hovering ? 0.05 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            if showsClose {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill((tab.active ? NativeSessionChrome.ink : Color.primary).opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab.active ? NativeSessionChrome.ink : Color.secondary)
                .padding(.leading, 7)
                .help("Close Tab")
                .accessibilityLabel("Close \(tab.title)")
            }
        }
        .onHover { hovering = $0 }
        .help([tab.title, tab.status.map { StatusMeaning($0).label }].compactMap { $0 }.joined(separator: " — "))
        .contextMenu {
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
