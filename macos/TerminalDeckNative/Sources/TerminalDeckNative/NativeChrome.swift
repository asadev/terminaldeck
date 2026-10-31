import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// The window's two surfaces, defined once (Asad, 2026-10-08: "selected tab mixing with the
/// page, same colour; the other tabs and the side panel a different shade", as in Chrome).
///
///  * PAGE  — what the screen on show is drawn on. The selected tab is exactly this colour
///            and runs into it with no line between.
///  * FRAME — the tab bar (the window's title area), every unselected tab and the side panel.
///            It uses the shared frame token for the window's appearance, so changing
///            pages never changes the side panel or title area's brightness.
///
/// A terminal or browser screen is drawn on the terminal paper; every other native screen on
/// the shared page token. Only the page and selected tab follow the terminal paper.
@MainActor
enum NativeChrome {
    /// Terminal and browser screens sit on session paper; other screens use the page token.
    static func usesPaper(kind: String?, id: String?) -> Bool {
        if kind == "browser" { return true }
        guard let id else { return false }
        return NativeTerminalScreen.handles(id) && !NativeTerminalSessions.shared.isChat(id)
    }

    static func paper(_ screen: (kind: String, id: String)?) -> Bool {
        usesPaper(kind: screen?.kind, id: screen?.id)
    }

    // MARK: Colours

    static func pageNS(paper: Bool) -> NSColor {
        paper ? DeckTokens.paperNS : DeckTokens.pageNS
    }

    /// Keep the argument for existing callers; the frame is independent of the selected page.
    static func frameNS(paper: Bool) -> NSColor {
        DeckTokens.frameNS
    }

    /// The subtle fill under a hovered, unselected tab: the frame, a good way toward the page.
    static func hoverNS(paper: Bool) -> NSColor {
        let page = pageNS(paper: paper)
        return NSColor(name: nil) { appearance in
            resolve(page, in: appearance) { page in
                blend(derivedFrame(from: page), toward: page, 0.55)
            }
        }
    }

    static func page(paper: Bool) -> Color { Color(nsColor: pageNS(paper: paper)) }
    static func frame(paper: Bool) -> Color { Color(nsColor: frameNS(paper: paper)) }
    static func hover(paper: Bool) -> Color { Color(nsColor: hoverNS(paper: paper)) }

    /// The page behind the screen on show, for the places that draw it (`.background(.background)`).
    static func page(kind: String?, id: String?) -> Color {
        if let id, NativeTerminalScreen.handles(id), NativeTerminalSessions.shared.isChat(id) { return DeckTokens.chatPage }
        return page(paper: usesPaper(kind: kind, id: id))
    }
    static func page(_ screen: (kind: String, id: String)?) -> Color { page(kind: screen?.kind, id: screen?.id) }
    static func frame(_ screen: (kind: String, id: String)?) -> Color { frame(paper: paper(screen)) }

    // MARK: The maths (pure, tested)

    /// Light page: a light grey a step darker (a white page gives about #e8e8e8, Chrome's
    /// #dee1e6 relation). Dark page: noticeably darker. A near-black page goes a touch lighter.
    nonisolated static func derivedFrame(from page: NSColor) -> NSColor {
        let l = luminance(page)
        if l > 0.5 { return blend(page, toward: .black, 0.09) }
        if l > 0.04 { return blend(page, toward: .black, 0.34) }
        return blend(page, toward: .white, 0.07)
    }

    nonisolated static func luminance(_ colour: NSColor) -> Double {
        guard let c = colour.usingColorSpace(.sRGB) else { return 0.5 }
        return 0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)
    }

    nonisolated static func blend(_ colour: NSColor, toward other: NSColor, _ fraction: CGFloat) -> NSColor {
        guard let a = colour.usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return colour }
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * fraction,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * fraction,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * fraction,
                       alpha: 1)
    }

    nonisolated private static func resolve(_ colour: NSColor, in appearance: NSAppearance, _ make: (NSColor) -> NSColor) -> NSColor {
        var out = colour
        appearance.performAsCurrentDrawingAppearance {
            out = make(colour.usingColorSpace(.sRGB) ?? colour)
        }
        return out
    }
}

/// The selected tab: top corners rounded, and Chrome's small outward curves at the bottom
/// corners so it flows into the page. Drawn `flare` wider than the tab on each side.
struct NativeChromeTabShape: Shape {
    var corner: CGFloat = 8
    var flare: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let f = flare, c = corner
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.minX + f, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.minX + f, y: rect.maxY - f), radius: f)
        p.addLine(to: CGPoint(x: rect.minX + f, y: rect.minY + c))
        p.addArc(tangent1End: CGPoint(x: rect.minX + f, y: rect.minY),
                 tangent2End: CGPoint(x: rect.minX + f + c, y: rect.minY), radius: c)
        p.addLine(to: CGPoint(x: rect.maxX - f - c, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX - f, y: rect.minY),
                 tangent2End: CGPoint(x: rect.maxX - f, y: rect.minY + c), radius: c)
        p.addLine(to: CGPoint(x: rect.maxX - f, y: rect.maxY - f))
        p.addArc(tangent1End: CGPoint(x: rect.maxX - f, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: f)
        p.closeSubpath()
        return p
    }
}

/// Paints a window's own background (and clears its title bar) in the frame colour, so the
/// strip behind the tabs and everything not covered by the page is one shade.
struct NativeChromeWindow: NSViewRepresentable {
    let paper: Bool

    func makeNSView(context: Context) -> ChromeView { ChromeView() }

    func updateNSView(_ view: ChromeView, context: Context) {
        view.frameColour = NativeChrome.frameNS(paper: paper)
        view.apply()
    }

    final class ChromeView: NSView {
        var frameColour: NSColor?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }

        func apply() {
            guard let window, let frameColour else { return }
            window.titlebarAppearsTransparent = true
            // The glass covers the frame; an opaque backing leaks at its antialiased outer corner.
            let solid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            window.isOpaque = solid
            window.backgroundColor = solid ? frameColour : .clear
            window.titlebarSeparatorStyle = .none
        }
    }
}

/// One frame treatment for the main scene and separately opened page windows.
struct NativeWindowChrome: ViewModifier {
    var paper = false
    var enabled = true
    func body(content: Content) -> some View {
        if enabled {
            content
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .background(DeckSidebarMaterial().ignoresSafeArea())
                .background(NativeChromeWindow(paper: paper))
        } else { content }
    }
}
