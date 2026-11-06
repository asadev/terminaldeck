import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// The quick Hoot popover (sliders on the Hoot page and on the island). Asad, 12 Oct: "here we should only see efforts,
/// model, permission level, and a drop down to change the account". So: the account (every signed-in account of every
/// Coding AI, like a session's account chip), the model of that AI, the context window in use (a plain line, only when
/// it is known), effort, and "Before it changes files". Which Coding AI and its setup live on Hoot's profile. "What
/// Hoot may do" is gone: Hoot can always run sessions, hand problems out, use phones and open any folder.
struct HootQuickSettings: View {
    var brain: ROUTINESHootBrainModel = .shared
    var live = true
    var close: () -> Void = {}
    static let size = CGSize(width: 400, height: 400)
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                HootMark(size: 22, animated: false)
                Text("Hoot").font(.headline)
                Spacer()
            }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
            Form {
                Section { HootBrainRows(brain: brain, compact: true, quick: true) }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            Divider()
            HStack {
                Button("Open Hoot's profile…") {
                    close()
                    guard live else { return }
                    HootProfileRoute.open(tab: "brain")
                }.buttonStyle(.borderless)
                Spacer()
            }.padding(.horizontal, 16).frame(height: 36)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear { if live { brain.reload() } }
    }
}

/// The account dropdown of Hoot's brain: every signed-in account of every Coding AI, grouped by AI, the one Hoot uses
/// ticked, and "Add account" at the foot. Picking an account of another AI switches Hoot to that AI; the chat carries
/// on (the next message hands the new AI the conversation so far).
struct HootAccountMenu: View {
    @Bindable var brain: ROUTINESHootBrainModel
    /// 12 Oct: done by the app itself (Settings › Coding AI with Add account open), never a page command that can drop.
    var addAccount: @MainActor () -> Void = { NativeAccountSwitcher.addAccount() }
    var body: some View {
        Menu {
            ForEach(brain.accountGroups, id: \.provider) { group in
                Section(group.title) {
                    ForEach(group.accounts) { account in
                        Button { brain.selectAccount(account.id, provider: group.provider) } label: {
                            if account.id == brain.currentAccountID, group.provider == brain.chosenProvider {
                                Label(NativeChatAccountNames.shared.label(account.id, fallback: account.name, provider: group.provider), systemImage: "checkmark")
                            } else { Text(NativeChatAccountNames.shared.label(account.id, fallback: account.name, provider: group.provider)) }
                            if CodingAILogins.normalizedEmail(account.name) != nil { Text(account.name).font(.caption) }
                        }
                    }
                }
            }
            if brain.accountGroups.isEmpty { Text("No signed-in account yet").foregroundStyle(.secondary) }
            Divider()
            Button("Add account…", action: addAccount)
        } label: {
            DeckRowLabel(NativeChatAccountNames.shared.label(brain.currentAccountID, fallback: brain.currentAccountName, provider: brain.chosenProvider), image: DeckRowIcon.provider(brain.chosenProvider)).labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help(brain.currentAccountName)
        .accessibilityLabel("Hoot's account: " + NativeChatAccountNames.shared.label(brain.currentAccountID, fallback: brain.currentAccountName, provider: brain.chosenProvider))
        .task(id: EngineBridge.shared.isReady) { await NativeChatAccountNames.shared.start() }
    }
}

/// The sliders button the Hoot page puts in its header: opens the quick popover.
struct HootQuickSettingsButton: View {
    var live = true
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            // Sliders, not the app's Settings gear (Asad, 10 Oct).
            Image(systemName: "slider.vertical.3").frame(width: 28, height: 28).contentShape(.rect)
        }
        .buttonStyle(.borderless).help("Hoot settings").accessibilityLabel("Hoot settings")
        .popover(isPresented: $open, arrowEdge: .bottom) { HootQuickSettings(live: live, close: { open = false }) }
    }
}

/// The island's gear has no SwiftUI anchor: it opens the same content in a small glass
/// panel just under the menu bar, centred on the island's screen. Opened only by a person.
@MainActor
enum HootQuickSettingsPanel {
    private static var panel: NSPanel?
    static func show(on screen: NSScreen? = NSScreen.main) {
        NativeFront.onlyForPerson("Hoot quick settings") {
            if let panel, panel.isVisible { panel.orderFront(nil); return }
            let size = NSSize(width: HootQuickSettings.size.width, height: HootQuickSettings.size.height)
            let made = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            made.titleVisibility = .hidden; made.titlebarAppearsTransparent = true
            made.isMovableByWindowBackground = true; made.isReleasedWhenClosed = false
            made.level = .floating; made.hidesOnDeactivate = false
            let effect = NSVisualEffectView(); effect.material = .popover; effect.state = .active
            let host = NSHostingView(rootView: HootQuickSettings(close: { made.close() }))
            host.frame = effect.bounds; host.autoresizingMask = [.width, .height]
            effect.addSubview(host); made.contentView = effect
            if let frame = (screen ?? NSScreen.main)?.visibleFrame {
                made.setFrameTopLeftPoint(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - 8))
            }
            panel = made
            made.makeKeyAndOrderFront(nil)
        }
    }
}
