import AppKit
import SwiftUI
import TerminalDeckNativeCore

// The built-in browser's chrome, 18 Nov 2026 (owner, on his recording: "This is very ugly profile. Look how Google
// Chrome looks like ... very nicely box opens. We have three dots for all the rest of the settings"; "make all of
// these as pill"; "all of these pop-ups should be our own style"). Design: notes/review-20261118/DESIGN-browser.md.
//
// Everything in this file is drawn from plain values (no tab, no store, no engine), so the pictures in
// BrowserChromePictures show exactly what the app draws. NativeBrowserScreen.swift gives them the live values.
// The menus are the app's shared DeckMenu (DeckMenu.swift): this file only fills them.

/// The toolbar's cards. One at a time.
enum BrowserChromeMenu: Hashable, Sendable { case connect, profile, more }

// MARK: - Menu pieces the browser adds to DeckMenu

/// What a row ends in: a value, a shortcut hint, an arrow into the card's next page.
struct BrowserMenuTrail: View {
    var detail = ""
    var shortcut = ""
    var opensPage = false

    var body: some View {
        HStack(spacing: 6) {
            if !detail.isEmpty {
                Text(detail).font(.system(size: DeckMenuMetrics.detailText)).foregroundStyle(.secondary).lineLimit(1)
            }
            if !shortcut.isEmpty {
                Text(shortcut).font(.system(size: DeckMenuMetrics.detailText)).foregroundStyle(.tertiary)
            }
            if opensPage {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// The head of a page inside a card: its name, and the way back to the card's first page.
struct BrowserMenuBack: View {
    let title: String
    let back: () -> Void

    var body: some View {
        DeckMenuRow(title, symbol: "chevron.left", keepsOpen: true, action: back)
            .fontWeight(.semibold)
            .accessibilityLabel("Back from \(title)")
        DeckMenuDivider()
    }
}

extension View {
    /// The menu's look for a list that is not a DeckMenu (the address field's suggestions, which hang in the window).
    func browserMenuCard() -> some View {
        background(DeckMenuColours.surface, in: .rect(cornerRadius: DeckMenuMetrics.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DeckMenuMetrics.radius, style: .continuous)
                    .strokeBorder(DeckMenuColours.border, lineWidth: 0.5)
            }
            .clipShape(.rect(cornerRadius: DeckMenuMetrics.radius, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}

// MARK: - Toolbar pieces

enum BrowserToolbarMetrics {
    static let height: CGFloat = 40
    static let button: CGFloat = 28
    static let addressHeight: CGFloat = 30
    static let pillHeight: CGFloat = 26
    /// Narrower than this the Connect pill drops its word.
    static let compactUnder: CGFloat = 620
    static let moreWidth: CGFloat = 264
    static let profileWidth: CGFloat = 280
    static let connectWidth: CGFloat = 264
    /// The downloads list is 360 wide inside the menu's 5 pt padding.
    static let downloadsWidth: CGFloat = 370
}

/// The toolbar's row: navigation, the address (it takes the room), then the short right group.
struct BrowserToolbarFrame<Navigation: View, Address: View, Trailing: View>: View {
    @ViewBuilder var navigation: Navigation
    @ViewBuilder var address: Address
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) { navigation }
            address.frame(minWidth: 120).layoutPriority(1)
            // Its own size, always: the address takes what is left, never a piece of a button.
            HStack(spacing: 4) { trailing }.fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: BrowserToolbarMetrics.height)
    }
}

/// A round, quiet toolbar button: back, forward, reload, downloads, more.
struct BrowserToolbarButton<Glyph: View>: View {
    let label: String
    let help: String
    var active = false
    let action: () -> Void
    @ViewBuilder var glyph: Glyph
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        NativeSessionButton(action: action) {
            glyph
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isEnabled ? Color.primary.opacity(0.72) : Color.primary.opacity(0.26))
                .frame(width: BrowserToolbarMetrics.button, height: BrowserToolbarMetrics.button)
                .background(Color.primary.opacity(active ? 0.12 : (hovering && isEnabled ? 0.08 : 0)), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}

extension BrowserToolbarButton where Glyph == Image {
    init(_ label: String, _ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) {
        self.init(label: label, help: help, active: active, action: action) { Image(systemName: symbol) }
    }
}

/// The address field's pill: what sits in it is the caller's (the served word, the field, the zoom, the star).
struct BrowserAddressPill<Content: View>: View {
    var focused = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .padding(.leading, 14)
            .padding(.trailing, 5)
            .frame(height: BrowserToolbarMetrics.addressHeight)
            .background(Color.primary.opacity(0.06), in: .capsule)
            .overlay { Capsule().strokeBorder(NativeSessionChrome.accent.opacity(focused ? 0.7 : 0), lineWidth: 1.5) }
            .frame(maxWidth: .infinity)
    }
}

/// The bookmark star at the end of the address field.
struct BrowserBookmarkStar: View {
    let saved: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        NativeSessionButton(action: toggle) {
            Image(systemName: saved ? "star.fill" : "star")
                .font(.system(size: 12))
                .foregroundStyle(saved ? NativeSessionChrome.accent : Color.secondary)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(hovering ? 0.08 : 0), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(saved ? "Remove this bookmark" : "Bookmark this page")
        .accessibilityLabel(saved ? "Remove bookmark" : "Bookmark this page")
    }
}

/// A mode that is on, shown in the toolbar while it is: the pill is its own off switch.
struct BrowserModePill: View {
    let text: String
    let symbol: String
    var tint: Color = NativeSessionChrome.accent
    let help: String
    let stop: () -> Void
    @State private var hovering = false

    var body: some View {
        NativeSessionButton(action: stop) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).opacity(0.7)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(tint.opacity(hovering ? 0.22 : 0.14), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Connect: one control (owner: "keep one icon only, disconnect and connect, not two")

struct BrowserConnectState: Equatable {
    /// "B1" while a session holds this page, else nil.
    var slot: String?
    var sessionName = ""
    /// The session's colour slot (NativeBRBindColour).
    var colour = 0
}

struct BrowserConnectPill: View {
    let state: BrowserConnectState
    /// A narrow toolbar: the glyph alone (connected: the chip alone).
    var compact = false
    var open = false
    let showMenu: () -> Void
    let disconnect: () -> Void
    @State private var hovering = false
    @State private var hoveringClose = false

    var body: some View {
        if let slot = state.slot {
            let tint = NativeBRBindColour.color(state.colour)
            HStack(spacing: 0) {
                NativeSessionButton(action: showMenu) {
                    HStack(spacing: 6) {
                        Text(slot)
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 20, minHeight: 15)
                            .fixedSize()
                            .background(tint, in: .rect(cornerRadius: 4))
                        if !compact && !state.sessionName.isEmpty {
                            Text(state.sessionName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                .truncationMode(.tail).frame(maxWidth: 150, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                                .foregroundStyle(tint)
                        }
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 2)
                    .frame(height: BrowserToolbarMetrics.pillHeight)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(state.sessionName.isEmpty ? "Connected to a session" : "Connected to \(state.sessionName). Click to change.")
                .accessibilityLabel(state.sessionName.isEmpty ? "Connected as \(slot)" : "Connected to \(state.sessionName) as \(slot)")

                NativeSessionButton(action: disconnect) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 18, height: 18)
                        .background(tint.opacity(hoveringClose ? 0.22 : 0), in: .circle)
                        .frame(width: 24, height: BrowserToolbarMetrics.pillHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hoveringClose = $0 }
                .help("Disconnect")
                .accessibilityLabel("Disconnect \(slot)")
            }
            .background(tint.opacity(hovering || open ? 0.24 : 0.16), in: .capsule)
            .onHover { hovering = $0 }
        } else {
            NativeSessionButton(action: showMenu) {
                HStack(spacing: 5) {
                    Image(systemName: "link").font(.system(size: 11, weight: .medium))
                    if !compact { Text("Connect").font(.system(size: 12, weight: .medium)).fixedSize() }
                }
                .foregroundStyle(Color.primary.opacity(0.78))
                .padding(.horizontal, compact ? 0 : 10)
                .frame(minWidth: BrowserToolbarMetrics.pillHeight, minHeight: BrowserToolbarMetrics.pillHeight)
                .fixedSize()
                .background(Color.primary.opacity(hovering || open ? 0.08 : 0), in: .capsule)
                .overlay { Capsule().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1) }
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Connect this page to a session, so its AI can see and use it")
            .accessibilityLabel(BRBindChips.connectLabel(slot: nil))
        }
    }
}

/// The Connect card's rows: the open sessions; the connected one has the check; Disconnect comes first.
struct BrowserConnectMenu: View {
    /// nil while the sessions are being read.
    let rows: [BRConnectRow]?
    let press: (BRConnectRow.Act) -> Void

    var body: some View {
        DeckMenuSection("Connect this page to")
        if let rows {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                switch row.kind {
                case .separator:
                    DeckMenuDivider()
                case .header:
                    DeckMenuSection(row.label)
                case .item where row.act == .detach:
                    DeckMenuRow("Disconnect", symbol: "xmark.circle", action: { press(.detach) })
                case .item:
                    DeckMenuNote(row.label) // "No sessions are open."
                case .checkbox:
                    DeckMenuRow(row.label, symbol: "link", checked: row.checked, enabled: row.enabled,
                                action: { if let act = row.act { press(act) } })
                }
            }
        } else {
            DeckMenuNote("Reading…")
        }
    }
}

// MARK: - Downloads button

struct BrowserDownloadsGlyph: View {
    var badge: (label: String, tone: String)?
    var running = false
    var fraction: Double?

    var body: some View {
        ZStack {
            Image(systemName: "arrow.down.to.line")
            if running {
                Circle()
                    .trim(from: 0, to: fraction ?? 0.15)
                    .stroke(NativeSessionChrome.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 24, height: 24)
            }
        }
        .overlay(alignment: .topTrailing) {
            // How many are moving, "!" when the newest failed, else how many there are.
            if let badge {
                Text(badge.label)
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3.5)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(badge.tone == "bad" ? Color.red : badge.tone == "busy" ? NativeSessionChrome.accent : Color.secondary,
                                in: .capsule)
                    .offset(x: 9, y: -8)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Profile: an avatar and a card (owner: "look how Google Chrome looks like ... very nicely box opens")

enum BrowserProfileLook {
    /// Six quiet colours: the default profile is the first, the others take the next ones in the order they were made.
    private static let palette: [UInt32] = [0x4C7CF0, 0xD9654F, 0x3F9D78, 0x9A6BD6, 0xC98A2B, 0x3D97AB]

    static func colour(_ profile: BrowserProfile?, among all: [BrowserProfile]) -> Color {
        var index = 0
        if let profile, !profile.isDefault,
           let place = all.filter({ !$0.isDefault }).firstIndex(where: { $0.id == profile.id }) {
            index = 1 + place % (palette.count - 1)
        }
        let hex = palette[index]
        return Color(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

struct BrowserProfileAvatar: View {
    let badge: String
    let colour: Color
    var size: CGFloat = 24
    /// An isolated tab: a small lock on the avatar (nothing is kept).
    var isolated = false

    var body: some View {
        Text(badge.isEmpty ? "·" : badge)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(colour, in: .circle)
            .overlay(alignment: .bottomTrailing) {
                if isolated {
                    Image(systemName: "lock.fill")
                        .font(.system(size: max(7, size * 0.3), weight: .bold))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .frame(width: max(12, size * 0.5), height: max(12, size * 0.5))
                        .background(DeckMenuColours.surface, in: .circle)
                        .offset(x: 3, y: 3)
                }
            }
    }
}

struct BrowserProfileCardModel: Equatable {
    var current: BrowserProfile?
    /// Every profile, in the engine's order (the card lists the ones that are not `current`).
    var all: [BrowserProfile] = []
    var isolated = false
    var canCreate = true

    var others: [BrowserProfile] { all.filter { $0.id != current?.id } }
}

enum BrowserProfileAction: Equatable { case choose(String), newProfile, passwords, history }

/// The profile card's content: who you are, the other profiles, then what belongs to the profile.
struct BrowserProfileCard: View {
    let model: BrowserProfileCardModel
    let act: (BrowserProfileAction) -> Void

    private func colour(_ profile: BrowserProfile?) -> Color { BrowserProfileLook.colour(profile, among: model.all) }

    var body: some View {
        VStack(spacing: 6) {
            BrowserProfileAvatar(badge: model.current?.badge ?? "", colour: colour(model.current), size: 44,
                                 isolated: model.isolated)
            Text(model.current?.name.isEmpty == false ? model.current!.name : "Profile")
                .font(.system(size: 15, weight: .semibold)).lineLimit(1)
            if model.isolated {
                Text("Isolated tab: nothing is kept").font(.system(size: DeckMenuMetrics.detailText)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 13)
        .padding(.bottom, 9)

        DeckMenuDivider()
        if !model.others.isEmpty {
            DeckMenuSection("Other profiles")
            ForEach(model.others) { profile in
                DeckMenuRow(profile.name.isEmpty ? "Profile" : profile.name, action: { act(.choose(profile.id)) }, icon: {
                    BrowserProfileAvatar(badge: profile.badge, colour: colour(profile), size: DeckMenuMetrics.icon + 2)
                })
            }
        }
        DeckMenuRow("New profile…", symbol: "plus", enabled: model.canCreate, action: { act(.newProfile) })
        if !model.isolated {
            DeckMenuDivider()
            DeckMenuRow("Passwords", symbol: "key", action: { act(.passwords) })
            DeckMenuRow("History", symbol: "clock", action: { act(.history) })
        }
    }
}

// MARK: - More (three dots): everything else, as labelled rows

struct BrowserMoreModel: Equatable {
    /// A web page is on show (not the New Tab page).
    var hasPage = false
    /// The tab has an address (it may be the failed one).
    var hasAddress = false
    var annotating = false
    var drawing = false
    var recording = false
    /// Steps kept from a recording that has stopped (the flow can be shown again).
    var recordedSteps = 0
    var zoom = "100%"
    var isolated = false
    /// nil: this window offers no split.
    var split: Bool?
    var bookmarksAlways = false
    var bookmarks: [BrowserBookmark] = []
    var size = BrowserSizeModel()
    /// Empty: no other machine is paired, so the row is absent.
    var machines: [BrowserMachineRow] = []
}

struct BrowserSizeModel: Equatable {
    /// nil: the page fills the window.
    var deviceID: String?
    var landscape = false
    var phoneUserAgent = false
    var custom = "390 × 844"

    var label: String {
        guard let deviceID else { return "" }
        if deviceID == BRDeviceSize.customID { return "Custom" }
        return BrowserDevicePreset.all.first { $0.id == deviceID }?.label ?? ""
    }
}

struct BrowserMachineRow: Equatable, Identifiable {
    let id: String
    let name: String
    var detail = ""
    var enabled = true
    var chosen = false
}

enum BrowserMoreAction: Equatable {
    case newTab, newIsolatedTab
    case annotate, screenshot, draw, record, showFlow, devtools
    case zoomOut, zoomReset, zoomIn, find, print, copyAddress, openInBrowser
    case toggleIsolated, toggleSplit
    case home, setStartPage, store, settings
    case size(String?), landscape(Bool), phoneUserAgent(Bool)
    case bookmarksAlways(Bool), openBookmark(String)
    case machine(String)
}

/// The More card's content. Three of its rows open a page inside the card (sizes, bookmarks, machines).
struct BrowserMoreMenu: View {
    enum Page: Equatable { case main, size, bookmarks, machines }
    let model: BrowserMoreModel
    var startPage = Page.main
    let act: (BrowserMoreAction) -> Void
    @State private var page: Page?

    var body: some View {
        switch page ?? startPage {
        case .main: main
        case .size: sizePage
        case .bookmarks: bookmarksPage
        case .machines: machinesPage
        }
    }

    private func hint(_ shortcut: String) -> BrowserMenuTrail { BrowserMenuTrail(shortcut: shortcut) }

    @ViewBuilder private var main: some View {
        DeckMenuRow("New tab", symbol: "plus", action: { act(.newTab) }, trailing: { hint("⌘T") })
        DeckMenuRow("New isolated tab", symbol: "lock", action: { act(.newIsolatedTab) }, trailing: { hint("⇧⌘N") })
        DeckMenuDivider()

        DeckMenuRow("Annotate page", symbol: "cursorarrow.rays", checked: model.annotating, enabled: model.hasPage,
                    action: { act(.annotate) })
        DeckMenuRow("Screenshot", symbol: "camera", enabled: model.hasPage, action: { act(.screenshot) })
        DeckMenuRow("Draw on a screenshot", symbol: "pencil.tip", checked: model.drawing, enabled: model.hasPage,
                    action: { act(.draw) })
        if model.recording {
            DeckMenuRow("Stop recording", symbol: "stop.circle.fill", role: .destructive, action: { act(.record) })
        } else {
            DeckMenuRow("Record steps", symbol: "record.circle", enabled: model.hasPage, action: { act(.record) })
            if model.recordedSteps > 0 {
                DeckMenuRow("Recorded flow", symbol: "list.bullet", action: { act(.showFlow) },
                            trailing: { BrowserMenuTrail(detail: "\(model.recordedSteps)") })
            }
        }
        DeckMenuRow("Page size", symbol: "iphone", enabled: model.hasPage, keepsOpen: true, action: { page = .size },
                    trailing: { BrowserMenuTrail(detail: model.size.label, opensPage: true) })
        DeckMenuRow("Developer tools", symbol: "chevron.left.forwardslash.chevron.right", enabled: model.hasPage,
                    action: { act(.devtools) }, trailing: { hint("⌥⌘I") })
        DeckMenuDivider()

        BrowserZoomRow(percent: model.zoom, enabled: model.hasAddress) { act($0) }
        DeckMenuRow("Find in page", symbol: "magnifyingglass", enabled: model.hasPage, action: { act(.find) },
                    trailing: { hint("⌘F") })
        DeckMenuRow("Print…", symbol: "printer", enabled: model.hasPage, action: { act(.print) }, trailing: { hint("⌘P") })
        DeckMenuRow("Copy address", symbol: "doc.on.doc", enabled: model.hasAddress, action: { act(.copyAddress) })
        DeckMenuRow("Open in your browser", symbol: "arrow.up.forward.app", enabled: model.hasAddress,
                    action: { act(.openInBrowser) })
        DeckMenuDivider()

        DeckMenuRow("Bookmarks", symbol: "star", keepsOpen: true, action: { page = .bookmarks },
                    trailing: { BrowserMenuTrail(opensPage: true) })
        DeckMenuRow("Isolated tab", symbol: "lock.shield", checked: model.isolated, action: { act(.toggleIsolated) })
        if let split = model.split {
            DeckMenuRow("Split view", symbol: "rectangle.split.2x1", checked: split, action: { act(.toggleSplit) })
        }
        if !model.machines.isEmpty {
            DeckMenuRow("Open localhost on", symbol: "display", keepsOpen: true, action: { page = .machines },
                        trailing: { BrowserMenuTrail(detail: model.machines.first(where: \.chosen)?.name ?? "", opensPage: true) })
        }
        DeckMenuDivider()

        DeckMenuRow("Home", symbol: "house", action: { act(.home) }, trailing: { hint("⇧⌘H") })
        DeckMenuRow("Set as start page", symbol: "flag", enabled: model.hasAddress, action: { act(.setStartPage) })
        DeckMenuRow("Store", symbol: "bag", action: { act(.store) })
        DeckMenuRow("Browser settings…", symbol: "gearshape", action: { act(.settings) })
    }

    @ViewBuilder private var sizePage: some View {
        BrowserMenuBack(title: "Page size") { page = .main }
        DeckMenuRow("Fill the window", symbol: "macwindow", checked: model.size.deviceID == nil, action: { act(.size(nil)) })
        ForEach(BrowserDevicePreset.all) { preset in
            DeckMenuRow(preset.label, symbol: preset.group == "phone" ? "iphone" : preset.group == "tablet" ? "ipad" : "laptopcomputer",
                        checked: model.size.deviceID == preset.id, action: { act(.size(preset.id)) },
                        trailing: { BrowserMenuTrail(detail: "\(preset.width) × \(preset.height)") })
        }
        DeckMenuRow("Custom", symbol: "ruler", checked: model.size.deviceID == BRDeviceSize.customID,
                    action: { act(.size(BRDeviceSize.customID)) }, trailing: { BrowserMenuTrail(detail: model.size.custom) })
        DeckMenuDivider()
        DeckMenuRow("Landscape", symbol: "rectangle.landscape.rotate", checked: model.size.landscape,
                    enabled: model.size.deviceID != nil, keepsOpen: true, action: { act(.landscape(!model.size.landscape)) })
        DeckMenuRow("Phone user agent", symbol: "antenna.radiowaves.left.and.right", checked: model.size.phoneUserAgent,
                    keepsOpen: true, action: { act(.phoneUserAgent(!model.size.phoneUserAgent)) })
    }

    @ViewBuilder private var bookmarksPage: some View {
        BrowserMenuBack(title: "Bookmarks") { page = .main }
        DeckMenuRow("Always show the bookmarks bar", symbol: "menubar.rectangle", checked: model.bookmarksAlways,
                    keepsOpen: true, action: { act(.bookmarksAlways(!model.bookmarksAlways)) })
        if !model.bookmarks.isEmpty {
            DeckMenuDivider()
            ForEach(model.bookmarks) { mark in
                DeckMenuRow(mark.label, action: { act(.openBookmark(mark.url)) },
                            icon: { BrowserBookmarkIcon(mark: mark, size: DeckMenuMetrics.icon) })
                    .help(mark.url)
            }
        }
    }

    @ViewBuilder private var machinesPage: some View {
        BrowserMenuBack(title: "Open localhost on") { page = .main }
        ForEach(model.machines) { machine in
            DeckMenuRow(machine.name, symbol: "display", checked: machine.chosen, enabled: machine.enabled,
                        action: { act(.machine(machine.id)) }, trailing: { BrowserMenuTrail(detail: machine.detail) })
        }
    }
}

/// "Zoom  −  100%  +" in one row, as the Chrome menu he showed has it. The card stays open.
struct BrowserZoomRow: View {
    let percent: String
    var enabled = true
    let act: (BrowserMoreAction) -> Void

    var body: some View {
        HStack(spacing: DeckMenuMetrics.iconGap) {
            Image(systemName: "plus.magnifyingglass").font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(width: DeckMenuMetrics.icon, height: DeckMenuMetrics.icon)
            Text("Zoom").font(.system(size: DeckMenuMetrics.text))
            Spacer(minLength: 8)
            BrowserZoomStep(symbol: "minus", label: "Zoom out") { if enabled { act(.zoomOut) } }
            Button { if enabled { act(.zoomReset) } } label: {
                Text(percent).font(.system(size: 12).monospacedDigit()).frame(minWidth: 40).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Actual size")
            BrowserZoomStep(symbol: "plus", label: "Zoom in") { if enabled { act(.zoomIn) } }
        }
        .padding(.horizontal, DeckMenuMetrics.rowHorizontal)
        .frame(height: DeckMenuMetrics.rowHeight)
        .opacity(enabled ? 1 : 0.45)
    }
}

private struct BrowserZoomStep: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(hovering ? 0.12 : 0.06), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Bookmarks bar (owner: "We can have bookmarks over here")

/// A bookmark's site icon, or its letter on a quiet tile when the page had none.
struct BrowserBookmarkIcon: View {
    let mark: BrowserBookmark
    var size: CGFloat = 14

    var body: some View {
        if let data = mark.icon, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: 3, style: .continuous))
        } else {
            Text(String(mark.label.first.map { String($0).uppercased() } ?? "·"))
                .font(.system(size: size * 0.62, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(Color.primary.opacity(0.1), in: .rect(cornerRadius: 3, style: .continuous))
        }
    }
}

@MainActor
enum BrowserBookmarksBarMetrics {
    static let height: CGFloat = 30
    static let itemHeight: CGFloat = 24
    static let maxLabel: CGFloat = 150
    static let gap: CGFloat = 2
    static let overflowWidth: CGFloat = 26

    /// What one item needs: 8 + icon 14 + 6 + its name (at most `maxLabel`) + 8.
    static func width(of label: String) -> CGFloat {
        let text = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width.rounded(.up)
        return 8 + 14 + 6 + min(text, maxLabel) + 8
    }
}

struct BrowserBookmarksBar: View {
    let items: [BrowserBookmark]
    /// The bar's own room (the caller measures it; the bar never guesses).
    let width: CGFloat
    /// "»" is open (its menu lists what did not fit).
    @Binding var overflowOpen: Bool
    /// `newTab`: ⌘-click, or "Open in New Tab".
    let open: (BrowserBookmark, _ newTab: Bool) -> Void
    let copy: (BrowserBookmark) -> Void
    let remove: (BrowserBookmark) -> Void

    /// How many of `items` the bar shows; the rest sit behind "»".
    static func shown(_ items: [BrowserBookmark], width: CGFloat) -> Int {
        BrowserBookmarks.fitting(widths: items.map { Double(BrowserBookmarksBarMetrics.width(of: $0.label)) },
                                 available: Double(max(0, width - 16)), gap: Double(BrowserBookmarksBarMetrics.gap),
                                 overflowWidth: Double(BrowserBookmarksBarMetrics.overflowWidth))
    }

    var body: some View {
        let shown = Self.shown(items, width: width)
        let rest = Array(items.dropFirst(shown))
        HStack(spacing: BrowserBookmarksBarMetrics.gap) {
            ForEach(items.prefix(shown)) { mark in
                BrowserBookmarkChip(mark: mark, open: { open(mark, $0) }, copy: { copy(mark) }, remove: { remove(mark) })
            }
            Spacer(minLength: 0)
            if !rest.isEmpty {
                BrowserToolbarButton("More bookmarks", "chevron.right.2", help: "More bookmarks", active: overflowOpen,
                                     action: { overflowOpen.toggle() })
                    .frame(width: BrowserBookmarksBarMetrics.overflowWidth, height: BrowserBookmarksBarMetrics.itemHeight)
                    .deckMenu(isPresented: $overflowOpen, alignment: .trailing, width: BrowserToolbarMetrics.moreWidth) {
                        BrowserBookmarksOverflowMenu(items: rest, open: open)
                    }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: BrowserBookmarksBarMetrics.height)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BrowserBookmarkChip: View {
    let mark: BrowserBookmark
    let open: (_ newTab: Bool) -> Void
    let copy: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        NativeSessionButton(action: { open(NSEvent.modifierFlags.contains(.command)) }) {
            HStack(spacing: 6) {
                BrowserBookmarkIcon(mark: mark)
                Text(mark.label).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: BrowserBookmarksBarMetrics.maxLabel, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(Color.primary.opacity(0.82))
            .padding(.horizontal, 8)
            .frame(height: BrowserBookmarksBarMetrics.itemHeight)
            .background(Color.primary.opacity(hovering ? 0.07 : 0), in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(mark.url)
        .contextMenu {
            Button("Open in New Tab") { open(true) }
            Button("Copy Address", action: copy)
            Divider()
            Button("Remove", action: remove)
        }
        .accessibilityLabel(mark.label)
    }
}

/// What "»" opens: the bookmarks that did not fit on the bar.
struct BrowserBookmarksOverflowMenu: View {
    let items: [BrowserBookmark]
    let open: (BrowserBookmark, _ newTab: Bool) -> Void

    var body: some View {
        ForEach(items) { mark in
            DeckMenuRow(mark.label, action: { open(mark, NSEvent.modifierFlags.contains(.command)) },
                        icon: { BrowserBookmarkIcon(mark: mark, size: DeckMenuMetrics.icon) })
                .help(mark.url)
        }
    }
}
