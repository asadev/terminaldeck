import AppKit
import SwiftUI
import WebKit

// Asad, 10 Oct: "when any window is opening and loading or not showing anything yet till then
// show it transparent liquid glass overall … instead of white". One look for every window:
// a soft behind-window blur of the desktop, no white fill, until the content is ready; then the
// content fades in over 0.15 s. Reduce Transparency shows the page colour instead.

@MainActor
enum DeckWindowGlass {
    /// The fade from glass to content.
    static let fade: Double = 0.15

    /// A behind-window glass view for AppKit hosts (borderless pop-outs, web hosts).
    /// Under Reduce Transparency it is a plain page-coloured view.
    static func makeBackdrop() -> NSView {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let view = DeckSolidBackdropView()
            return view
        }
        let effect = NSVisualEffectView()
        effect.material = .fullScreenUI
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.isEmphasized = false
        return effect
    }

    /// For an AppKit window created by hand (e.g. a borderless simulator pop-out): clear
    /// background so the glass shows through, and a glass view behind its content until
    /// `reveal` is called. SwiftUI windows use `.deckLoadingGlass(_:)` instead.
    @discardableResult
    static func cover(_ window: NSWindow) -> NSView? {
        guard let content = window.contentView else { return nil }
        window.isOpaque = false
        window.backgroundColor = .clear
        let backdrop = makeBackdrop()
        backdrop.frame = content.bounds
        backdrop.autoresizingMask = [.width, .height]
        backdrop.identifier = NSUserInterfaceItemIdentifier("deck-window-glass")
        content.addSubview(backdrop, positioned: .below, relativeTo: nil)
        return backdrop
    }

    /// Fades the glass from `cover(_:)` out once the window's content has drawn.
    static func reveal(_ window: NSWindow, opaqueAfter: Bool = true) {
        guard let backdrop = window.contentView?.subviews.first(where: {
            $0.identifier?.rawValue == "deck-window-glass"
        }) else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fade
            backdrop.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                backdrop.removeFromSuperview()
                if opaqueAfter { window.isOpaque = true; window.backgroundColor = .windowBackgroundColor }
            }
        })
    }
}

private final class DeckSolidBackdropView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = DeckTokens.pageNS.cgColor }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// The glass itself, for SwiftUI: behind-window blur, or the page colour under Reduce Transparency.
struct DeckGlassBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            DeckTokens.page
        } else {
            DeckGlassEffectView()
        }
    }
}

private struct DeckGlassEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = .fullScreenUI
        effect.blendingMode = .behindWindow
        effect.state = .active
        return effect
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
    /// Glass while `loading`, then this content fades in over 0.15 s.
    func deckLoadingGlass(_ loading: Bool) -> some View {
        modifier(DeckLoadingGlass(loading: loading))
    }

    /// A native window's root: glass from the moment it opens until its first layout,
    /// then the content fades in.
    func deckWindowAppear() -> some View {
        modifier(DeckWindowAppear())
    }
}

private struct DeckLoadingGlass: ViewModifier {
    let loading: Bool

    func body(content: Content) -> some View {
        content
            .opacity(loading ? 0 : 1)
            .allowsHitTesting(!loading)
            .background {
                if loading {
                    DeckGlassBackdrop()
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            .animation(.easeOut(duration: DeckWindowGlass.fade), value: loading)
    }
}

private struct DeckWindowAppear: ViewModifier {
    @State private var ready = false

    func body(content: Content) -> some View {
        content
            .deckLoadingGlass(!ready)
            .task {
                // One frame of layout first, so the content is drawn when it fades in.
                try? await Task.sleep(for: .milliseconds(40))
                ready = true
            }
    }
}

/// Hosts a WKWebView: glass until the page has painted something (a committed load that is
/// well under way, or finished), then the page fades in. A page already shown is never hidden
/// again by a later reload.
///
/// A page is in one place only, and a host can outlive its place for a moment (a screen being replaced is updated once
/// more as it goes): only a host in a window takes the page, and a host leaving its window with the page hands it to the
/// host that shows that page now (28 Oct: a browser moved into the split came out blank).
final class DeckWebPaintHost: NSView {
    private weak var webView: WKWebView?
    private var backdrop: NSView?
    private var observations: [NSKeyValueObservation] = []
    private var painted = false
    private static let hosts = NSHashTable<DeckWebPaintHost>.weakObjects()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        Self.hosts.add(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ webView: WKWebView?) {
        if webView === self.webView, webView?.superview === self { return }
        self.webView = webView
        // Never taken from a host that is on screen; this host takes it when it reaches a window.
        guard window != nil || webView?.window == nil else { return }
        attach()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let webView else { return }
        if window != nil {
            if webView.superview !== self { attach() }
        } else if webView.superview === self {
            Self.hosts.allObjects.last { $0 !== self && $0.webView === webView && $0.window != nil }?.attach()
        }
    }

    private func attach() {
        observations.removeAll()
        subviews.forEach { $0.removeFromSuperview() }
        backdrop = nil
        guard let webView else { return }
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        painted = DeckWebPaintHost.hasPainted(webView)
        if !painted {
            let glass = DeckWindowGlass.makeBackdrop()
            glass.frame = bounds
            glass.autoresizingMask = [.width, .height]
            addSubview(glass)
            backdrop = glass
            webView.alphaValue = 0
            observations = [
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.check() }
                },
                webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.check() }
                },
            ]
        } else {
            webView.alphaValue = 1
        }
        addSubview(webView)
        check()
    }

    private func check() {
        guard !painted, let webView else { return }
        let started = webView.url != nil
        guard started, webView.estimatedProgress >= 0.5 || !webView.isLoading else { return }
        painted = true
        DeckWebPaintHost.markPainted(webView)
        observations.removeAll()
        let glass = backdrop
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DeckWindowGlass.fade
            webView.animator().alphaValue = 1
            glass?.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { glass?.removeFromSuperview() }
        })
        backdrop = nil
    }

    private static let paintedViews = NSHashTable<WKWebView>.weakObjects()
    static func hasPainted(_ webView: WKWebView) -> Bool { paintedViews.contains(webView) }
    static func markPainted(_ webView: WKWebView) { paintedViews.add(webView) }
}

// MARK: - Apple sidebar look (Asad, 10 Oct: "for all side panels use this apple native glossy
// same transparency as apple and color" — System Settings). One behind-window sidebar material
// for every side panel: the desktop shows through softly, and it never changes with the page.

/// The system sidebar material, behind the window. Reduce Transparency: the solid frame colour.
struct DeckSidebarMaterial: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            DeckTokens.frame
        } else {
            DeckSidebarEffectView()
        }
    }
}

private struct DeckSidebarEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        return effect
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Apple's selected sidebar row: a blue pill (grey when the window is in the background),
/// white text and icon.
enum DeckSidebar {
    static let rowHeight: CGFloat = 32
    static let rowRadius: CGFloat = 8

    static func selectionFill(active: Bool) -> Color {
        active ? Color.accentColor : Color.primary.opacity(0.12)
    }
    /// Ink for a row: white on the blue pill, else the given colour.
    static func ink(selected: Bool, active: Bool, otherwise: Color = .primary) -> Color {
        selected && active ? .white : otherwise
    }
}

/// Hover/press for a row on the sidebar material: a light ink wash, never an opaque card fill.
struct DeckSidebarRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DeckSidebarRowBody(configuration: configuration)
    }

    private struct DeckSidebarRowBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, minHeight: DeckTokens.Metrics.rowMin, alignment: .leading)
                .contentShape(Rectangle())
                .background(isEnabled && (configuration.isPressed || hovering)
                                ? Color.primary.opacity(configuration.isPressed ? 0.1 : 0.05) : .clear,
                            in: RoundedRectangle(cornerRadius: DeckSidebar.rowRadius))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Content corner (Asad, 10 Oct: "round corner inside each window on left top corner
// like artifact"). The page is a card set into the frame: rounded where it meets the side
// panel and the tab strip.

extension View {
    func deckContentCorner() -> some View {
        clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, style: .continuous))
    }
}

/// A 28 pt icon button on the sidebar material (hover wash, its own size, never stretched).
struct DeckSidebarIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DeckSidebarIconBody(configuration: configuration)
    }

    private struct DeckSidebarIconBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(width: DeckTokens.Metrics.iconHit, height: DeckTokens.Metrics.iconHit)
                .contentShape(Rectangle())
                .background(isEnabled && (configuration.isPressed || hovering)
                                ? Color.primary.opacity(configuration.isPressed ? 0.1 : 0.05) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .onHover { hovering = $0 }
        }
    }
}
