import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Shared surfaces and dimensions. The window frame never depends on its selected page.
/// Projects and terminal preferences keep their existing owners; these tokens only draw them.
@MainActor
enum DeckTokens {
    static let frameNS = dynamic("frame", light: 0xE9E9EE, dark: 0x121212)
    static let pageNS = dynamic("page", light: 0xFFFFFF, dark: 0x151515)
    static let cardNS = dynamic("card", light: 0xFFFFFF, dark: 0x2A2A2E)
    static let cardHoverNS = dynamic("card-hover", light: 0xF8F8F8, dark: 0x323237)
    /// Quiet avatar fill, matched to the phone without changing selected controls.
    static let avatarTileNS = dynamic("avatar-tile", light: 0xECECEC, dark: 0x3A3A3A)
    static let avatarTile = Color(nsColor: avatarTileNS)
    static let selectionNS = dynamic("selection", light: 0xFFFFFF, dark: 0x2A2A2E)
    static let hairlineNS = dynamic("hairline", light: 0xE7E7E7, dark: 0x333337)
    static let taskCardNS = dynamic("task-card", light: 0xFAFAFA, dark: 0x232326)
    static let taskDoneNS = dynamic("task-done", light: 0x555555, dark: 0x737373)
    static let taskDoneInkNS = dynamic("task-done-ink", light: 0xFFFFFF, dark: 0xFFFFFF)
    // Approved v1: accent switches and blue chart/usage meters. No page-wide tint override.
    static let switchOnNS = NSColor.controlAccentColor
    static let meterNS = NSColor.controlAccentColor
    /// GlassSwitch's selected pill (mockup 01): white on light, a raised grey on dark.
    static let switchPillNS = dynamic("switch-pill", light: 0xFFFFFF, dark: 0x6A6A70)
    static let hootNS = dynamic("hoot", light: 0xC8742B, dark: 0xE09450)

    /// Re-read the existing scheme so a preference preview or saved change is reflected immediately.
    static var paperNS: NSColor {
        let scheme = NativeSessionChrome.scheme
        return scheme.colour(scheme.background, fallback: .textBackgroundColor)
    }
    static var chatPageNS: NSColor {
        let darkPaper = paperNS
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkPaper : .white
        }
    }
    static let chatBodyNS = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .clear : .white
    }

    static let frame = Color(nsColor: frameNS)
    static let page = Color(nsColor: pageNS)
    static let card = Color(nsColor: cardNS)
    static let cardHover = Color(nsColor: cardHoverNS)
    static let selection = Color(nsColor: selectionNS)
    static let hairline = Color(nsColor: hairlineNS)
    static let taskCard = Color(nsColor: taskCardNS)
    static let taskDone = Color(nsColor: taskDoneNS)
    static let taskDoneInk = Color(nsColor: taskDoneInkNS)
    /// Apply to controls themselves, never a page ancestor which also contains other actions.
    static let switchOn = Color.accentColor
    /// Approved v1 blue chart bars/lines and usage meter fills.
    static let meter = Color.accentColor
    static let hoot = Color(nsColor: hootNS)
    static let switchPill = Color(nsColor: switchPillNS)
    static var paper: Color { Color(nsColor: paperNS) }
    static var chatPage: Color { Color(nsColor: chatPageNS) }
    static var chatBody: Color { Color(nsColor: chatBodyNS) }

    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    /// Approved v1 accent actions, links, focus rings, switches, charts and usage bars.
    static let accent = Color.accentColor
    /// Existing status colours. Pair a status dot with its word; never communicate by colour alone.
    static let good = Color(nsColor: .systemGreen)
    static let warn = Color(nsColor: .systemOrange)
    static let bad = Color(nsColor: .systemRed)

    enum Spacing {
        static let s4: CGFloat = 4
        static let s8: CGFloat = 8
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s20: CGFloat = 20
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32
        static let s40: CGFloat = 40
    }

    enum Metrics {
        static let sidebarMin: CGFloat = 240
        static let sidebarIdeal: CGFloat = 264
        static let sidebarMax: CGFloat = 340
        static let tabHeight: CGFloat = 36
        static let tabMin: CGFloat = 120
        static let tabMax: CGFloat = 220
        static let pageHeader: CGFloat = 52
        static let rowMin: CGFloat = 28
        static let iconHit: CGFloat = 28
        static let iconColumn: CGFloat = 18
        static let projectDot: CGFloat = 8
        static let cardRadius: CGFloat = 12
        static let rowRadius: CGFloat = 8
        static let chipRadius: CGFloat = 6
        static let groupedSectionRadius: CGFloat = 10
        static let pageHorizontal: CGFloat = 24
        static let pageTop: CGFloat = 20
        static let pageBottom: CGFloat = 32
        static let sectionGap: CGFloat = 28
        static let cardGap: CGFloat = 12
        static let cardPadding: CGFloat = 16
        static let rowHorizontal: CGFloat = 12
        static let rowVertical: CGFloat = 10
        static let objectSize = CGSize(width: 560, height: 520)
        static let settingsSize = CGSize(width: 760, height: 560)
    }

    enum Typography {
        static let title = Font.system(size: 20, weight: .semibold)
        static let section = Font.system(size: 15, weight: .semibold)
        static let rowTitle = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13)
        static let callout = Font.system(size: 12)
        static let caption = Font.system(size: 11)
        static let micro = Font.system(size: 10, weight: .semibold)
        static let metric = Font.system(size: 22, weight: .semibold).monospacedDigit()
        static let mono = Font.system(size: 12, design: .monospaced)
        static let microTracking: CGFloat = 0.4

        /// Suggested text line boxes, applied by the owning layout rather than fixed text heights.
        enum LineHeight {
            static let title: CGFloat = 24
            static let section: CGFloat = 20
            static let rowTitle: CGFloat = 16
            static let body: CGFloat = 17
            static let callout: CGFloat = 16
            static let caption: CGFloat = 14
            static let micro: CGFloat = 12
            static let metric: CGFloat = 26
        }
    }

    /// Approved v1 project dots (8 pt) and project tile. Never assign agent tile backgrounds.
    /// The existing project registry owns its saved colour/identity; this adapter never writes it.
    static func projectColour(_ project: PROJProject) -> Color {
        Color(nsColor: projectColourNS(project))
    }

    static func projectColourNS(_ project: PROJProject) -> NSColor {
        projectColourNS(project.colour)
    }

    static func projectColourNS(_ value: String) -> NSColor {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        // Original approved project palette, read from the existing saved colour.
        case "blue", "slate": return rgb(0x0A84FF)
        case "purple", "lavender": return rgb(0x8E5CF7)
        case "pink", "rose": return rgb(0xE8508A)
        case "orange", "sand": return rgb(0xF08A24)
        case "yellow", "olive": return rgb(0xD9B200)
        case "green", "sage": return rgb(0x34A853)
        case "teal": return rgb(0x1AA6B7)
        case "graphite": return rgb(0x8E8E93)
        default:
            // Read a saved custom swatch using the existing parser; never rewrite the saved value.
            if let colour = TerminalColour(hex: value) { return colour.nsColor }
            return rgb(0x8E8E93)
        }
    }

    private static func dynamic(_ name: String, light: UInt32, dark: UInt32,
                                lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: NSColor.Name("TerminalDeck." + name)) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }

    nonisolated private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}
