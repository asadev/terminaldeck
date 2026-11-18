import AppKit
import SwiftUI
import TerminalDeckNativeCore

// Lane BR (browser parity): the browser window's Connect pill (attach this
// window to a session, or disconnect it — BindChip.tsx ConnectSessionButton over
// browser-binding-ipc.ts connectMenuItems), the Bn chips on session and browser
// rows (SessionBindChips / WindowBindChip), Annotate's first click on the live
// page (`browser:element`) and the one instruction line under the toolbar.

// MARK: - The bindings, kept current

/// The engine's `browser:bindings` view for the whole window, read once and then
/// followed through its own event. Every chip and the Session button draw from it.
@MainActor @Observable
final class NativeBRBindings {
    static let shared = NativeBRBindings()
    fileprivate(set) var view = BRBindingView()
    /// The one drive the band shows (`browser:drive-state`, browser-driver.ts showing()).
    fileprivate(set) var drive: DriveNow?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []

    func start() {
        guard !started else { return }
        started = true
        subscriptions = [
            EngineBridge.shared.on("browser:bindings") { [weak self] args in self?.view = BRBindingView.read(args.first) },
            // Annotate's first click, and the page saying its picker went off (Esc in the page, a new document).
            EngineBridge.shared.on("browser:element") { args in
                guard let capture = BRInspectCapture.read(args.first) else { return }
                NativeBrowserTabs.shared.tab(capture.tabId)?.inspected(capture)
            },
            EngineBridge.shared.on("browser:drive-state") { [weak self] args in self?.drive = DriveNow.of(args.first) },
            EngineBridge.shared.on("browser:state") { args in
                guard let fields = args.first as? [String: Any], let id = fields["id"] as? String,
                      let inspecting = fields["inspecting"] as? Bool else { return }
                NativeBrowserTabs.shared.tab(id)?.inspectStateChanged(inspecting)
            },
        ]
        follow()
        refresh()
    }

    /// Asking once also makes this window a listener, so every later change arrives as an event.
    func refresh() {
        Task {
            guard EngineBridge.shared.isReady, let value = try? await EngineBridge.shared.invoke("browser:bindings") else { return }
            view = BRBindingView.read(value)
            drive = DriveNow.of(try? await EngineBridge.shared.invoke("browser:drive-status"))
        }
    }

    private func follow() {
        withObservationTracking {
            _ = AppModel.shared.engineIsUp
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.follow()
            }
        }
    }

    /// The name the rail gives a session, for a chip's hover.
    static func sessionName(_ sessionId: String) -> String? {
        if let item = AppModel.shared.sidebar?.item(id: sessionId) { return item.title }
        return AppModel.shared.tabs?.tabs.first { $0.id == sessionId }?.title
    }
}

// MARK: - Colours (tokens.css --bind-1…4)

enum NativeBRBindColour {
    private static let light: [UInt32] = [0x725d9d, 0x327270, 0x955183, 0x626e2e]
    private static let dark: [UInt32] = [0xa98ae8, 0x4fb3b0, 0xe07ac4, 0x9fb24a]

    static func color(_ colour: Int) -> Color {
        let index = BRBindChips.colourSlot(colour) - 1
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = (dark ? Self.dark : Self.light)[index]
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
}

// MARK: - Chips

/// One `B1`: filled in the session's colour; `+N` is hollow (a count, not a window).
struct NativeBRChip: View {
    let text: String
    let colour: Int
    var more = false
    let tooltip: String

    var body: some View {
        let tint = NativeBRBindColour.color(colour)
        Text(text)
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 4)
            .frame(minWidth: more ? 0 : 20, minHeight: 15)
            .foregroundStyle(more ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.white))
            .background(more ? AnyShapeStyle(Color.clear) : AnyShapeStyle(tint), in: .rect(cornerRadius: 4))
            .overlay { if more { RoundedRectangle(cornerRadius: 4).strokeBorder(tint, lineWidth: 1) } }
            .fixedSize()
            .help(tooltip)
            .accessibilityLabel(tooltip)
    }
}

/// The chips at the end of a rail row or a strip tab: a session's windows, or the
/// one window a browser row is attached as. `kind` is the row's ("session" / "browser").
struct NativeBRBindChips: View {
    let kind: String
    let id: String
    var server: ServerTabInfo?
    /// The row's own label, for a session row's chips.
    var name: String?
    @State private var store = NativeBRBindings.shared

    var body: some View {
        content
            .task { store.start() }
    }

    @ViewBuilder private var content: some View {
        if kind == "browser", let held = store.view.holder(of: id) {
            NativeBRChip(text: held.window.slot, colour: held.session.colour,
                         tooltip: BRBindChips.windowTooltip(held.window, session: held.session,
                                                           sessionName: NativeBRBindings.sessionName(held.session.sessionId)))
        } else if kind == "session", let key = BindMenuRow.key(tabId: id, server: server),
                  let session = store.view.session(key.sessionId, machineId: key.machineId), !session.windows.isEmpty {
            let parts = BRBindChips.split(session.windows)
            HStack(spacing: 2) {
                ForEach(parts.shown, id: \.tabId) { window in
                    NativeBRChip(text: window.slot, colour: session.colour, tooltip: BRBindChips.tooltip(window, sessionName: name))
                }
                if !parts.rest.isEmpty {
                    NativeBRChip(text: "+\(parts.rest.count)", colour: session.colour, more: true,
                                 tooltip: parts.rest.map { BRBindChips.tooltip($0, sessionName: name) }.joined(separator: "\n"))
                        .accessibilityLabel(BRBindChips.moreLabel(parts.rest))
                }
            }
        } else {
            // Present (and sized nothing) so the row starts the store even before any binding exists.
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

// MARK: - Connect (one pill in the toolbar's right group; NativeBrowserChrome.swift draws it)

/// 18 Nov 2026 (owner: "Why do we have two icons here to disconnect? ... keep one icon only, disconnect and connect,
/// not two"): the link button and the link-with-a-slash button are ONE pill. Not connected: "Connect". Connected: the
/// session's chip and name, with the x that disconnects inside the same pill. A press opens our own card of sessions.
struct NativeBrowserConnectButton: View {
    let tabId: String
    var compact = false
    var open = false
    let showMenu: () -> Void
    @State private var store = NativeBRBindings.shared

    var body: some View {
        let held = store.view.holder(of: tabId)
        BrowserConnectPill(state: BrowserConnectState(slot: held?.window.slot,
                                                      sessionName: held.flatMap { NativeBRBindings.sessionName($0.session.sessionId) } ?? "",
                                                      colour: held?.session.colour ?? 0),
                           compact: compact, open: open, showMenu: showMenu,
                           disconnect: { NativeBRConnectMenu.press(.detach, tabId: tabId) })
            .task { store.start() }
    }
}

/// The Connect card with the live sessions (read when it opens).
struct NativeBrowserConnectCard: View {
    let tabId: String
    @State private var rows: [BRConnectRow]?

    var body: some View {
        // One container, so the read runs once (a modifier on the bare rows would run once per row).
        VStack(alignment: .leading, spacing: 0) {
            BrowserConnectMenu(rows: rows) { NativeBRConnectMenu.press($0, tabId: tabId) }
        }
        .task { rows = await NativeBRConnectMenu.rows(tabId: tabId) }
    }
}

/// The Connect card's rows, read when it opens, and what a press sends.
@MainActor
enum NativeBRConnectMenu {
    static func rows(tabId: String) async -> [BRConnectRow] {
        var sessions: [BrowserSessionChoice] = []
        if EngineBridge.shared.isReady, let list = try? await EngineBridge.shared.invoke("session:list") {
            sessions = BrowserSessionChoice.read(list)
        }
        if EngineBridge.shared.isReady, let value = try? await EngineBridge.shared.invoke("browser:bindings") {
            NativeBRBindings.shared.view = BRBindingView.read(value)
        }
        return BRConnectMenu.rows(tabId: tabId, sessions: sessions, view: NativeBRBindings.shared.view)
    }

    static func press(_ act: BRConnectRow.Act, tabId: String) {
        let command = BRConnectMenu.command(act, tabId: tabId)
        EngineBridge.shared.send(command.channel, [command.argument])
    }
}

// MARK: - The drive band (DriveBanner.tsx, state "agent"; "human" is NativeBrowserHandoverBar)

struct NativeBrowserDriveBand: View {
    let tab: NativeBrowserTab
    @State private var store = NativeBRBindings.shared

    var body: some View {
        // Only over the page it is about (BrowserWorkspace: drive.tabId === active.id).
        if let drive = store.drive, drive.state == .agent, drive.tabId == tab.id, tab.handoverPrompt == nil {
            HStack(spacing: 8) {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                HStack(spacing: 0) {
                    Text(BRDriveChip.text(state: drive.state.rawValue, step: drive.step))
                    Text(BRDriveChip.site(drive.url)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.10))
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - The instruction line (modes.ts modeHint)

struct NativeBrowserHintRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.bar)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
