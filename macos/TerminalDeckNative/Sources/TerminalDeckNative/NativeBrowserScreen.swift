import AppKit
import SwiftUI
import WebKit
import TerminalDeckNativeCore

/// One browser tab, drawn in Swift on WKWebView (Safari's engine). The tab
/// itself sits in the main window's strip beside the sessions (see
/// `NativeBrowserTabs`); this is what the window shows for it. The toolbar
/// (18 Nov 2026, notes/review-20261118/DESIGN-browser.md; its pieces are in
/// NativeBrowserChrome.swift):
///
///   back · forward · reload/stop · [address … ☆] · (a pill per mode that is on) ·
///   Connect · Downloads · Profile · More (⋮: every other action, as labelled rows)
///
/// then the bookmarks bar (New Tab page, or always), the progress line, find in
/// page, the handover and Record panels, and the page (or "Open a page");
/// Annotate and Draw freeze the page over it.
/// Agent driving of this browser (the engine's `browser_*` tools) is a later step.
struct NativeBrowserScreen: View {
    let tabId: String
    /// Its shortcuts (⌘W, ⌘R, ⌘F…) are live: false for a pane of the split that is not the focused one.
    var keyboard = true
    /// Its toolbar ends with the window's split switch, as a session's header does (main window only).
    var modeSwitch = true
    @State private var store = NativeBrowserTabs.shared

    var body: some View {
        Group {
            if let tab = store.tab(tabId) {
                NativeBrowserTabView(store: store, tab: tab, keyboard: keyboard, modeSwitch: modeSwitch)
                    .id(tab.id)
                    .onAppear { store.select(tab.id) }
            } else {
                ContentUnavailableView("This browser tab is closed", systemImage: "globe")
            }
        }
        .task { await store.refreshProfiles() }
    }
}

struct NativeBrowserTabView: View {
    @Environment(\.nativeTerminalSelected) private var layoutSelected
    let store: NativeBrowserTabs
    let tab: NativeBrowserTab
    var keyboard = true
    var modeSwitch = true
    /// The bookmarks bar's "»" is open.
    @State private var bookmarksOverflow = false

    private var modeHint: String {
        var drawing = false, annotating = false
        switch tab.markup {
        case .draw: drawing = true
        case .annotate: annotating = true
        case nil: break
        }
        return BRBrowserModes.hint(inspecting: tab.inspecting, drawing: drawing, hasCapture: annotating)
    }

    var body: some View {
        let bookmarks = NativeBrowserBookmarksStore.shared
        let marks = bookmarks.list(profile: tab.profile)
        VStack(spacing: 0) {
            NativeBrowserToolbarRow(store: store, tab: tab, modeSwitch: modeSwitch)
                .overlay(alignment: .bottom) { NativeBrowserProgressLine(tab: tab).allowsHitTesting(false) }
                .zIndex(2) // the suggestions list hangs over the page
            // Bookmarks: on the New Tab page, or everywhere with "Always show the bookmarks bar" (never an empty bar).
            if !marks.isEmpty, tab.markup == nil, tab.showsStartView || bookmarks.alwaysShowBar {
                GeometryReader { proxy in
                    BrowserBookmarksBar(items: marks, width: proxy.size.width, overflowOpen: $bookmarksOverflow,
                                        open: { NativeBrowserBookmarkActions.open($0, newTab: $1, in: tab, store: store) },
                                        copy: { NativeBrowserBookmarkActions.copy($0, store: store) },
                                        remove: { bookmarks.remove($0) })
                }
                .frame(height: BrowserBookmarksBarMetrics.height)
                .background(NativeSessionChrome.ground)
                .environment(\.colorScheme, NativeSessionChrome.scheme.isLight ? .light : .dark)
            }
            if tab.findVisible && tab.markup == nil {
                NativeBrowserFindBar(tab: tab)
                Divider()
            }
            NativeBrowserPageRequestBar(tab: tab)
            NativeBrowserDriveBand(tab: tab) // lane BR: "Hoot is driving on …" (DriveBanner.tsx)
            if let prompt = tab.handoverPrompt {
                NativeBrowserHandoverBar(tab: tab, prompt: prompt)
                Divider()
            }
            if tab.savedSignInOffer != nil || tab.savedPasswordOffer != nil || tab.savedLoginMessage != nil {
                NativeBrowserSavedLoginBar(tab: tab)
                Divider()
            }
            if tab.recording || (!tab.steps.isEmpty && !tab.flowHidden) {
                NativeBrowserRecordPanel(tab: tab)
                Divider()
            }
            if tab.deviceID == BRDeviceSize.customID && tab.markup == nil {
                NativeBrowserCustomSizeBar(tab: tab) // lane BR: Size ▸ Custom's W × H (DeviceBar.tsx)
                Divider()
            }
            // The one instruction line (modes.ts modeHint), only while it is the instruction.
            if !modeHint.isEmpty {
                NativeBrowserHintRow(text: modeHint)
                Divider()
            }
            ZStack {
                // Parked while the page is frozen for Annotate or Draw, as the web browser parks its view.
                NativeBrowserContent(tab: tab)
                    .modifier(NativeBrowserPageVisibility(covered: tab.markup != nil, selected: layoutSelected ?? keyboard))
                    .opacity(tab.markup == nil ? 1 : 0)
                    .allowsHitTesting(tab.markup == nil)
                switch tab.markup {
                case .annotate(let shot): NativeBrowserAnnotateView(tab: tab, shot: shot)
                case .draw(let shot): NativeBrowserDrawView(tab: tab, shot: shot)
                case nil: EmptyView()
                }
            }
        }
        .background(NativeBrowserKeyCatcher { keyboard && tab.handleKey($0) })
        .sheet(isPresented: Binding(get: { tab.historyShown }, set: { tab.historyShown = $0 })) {
            NativeBrowserHistorySheet(tab: tab, profileName: store.profile(tab.profile)?.name ?? "")
        }
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                Text(notice)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 18)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.notice)
    }
}

/// What a press on a bookmark does (the bar, its "»" menu and More ▸ Bookmarks all come here).
@MainActor
enum NativeBrowserBookmarkActions {
    static func open(_ mark: BrowserBookmark, newTab: Bool, in tab: NativeBrowserTab, store: NativeBrowserTabs) {
        guard let url = URL(string: mark.url) else { return }
        if newTab { store.create(url: url, after: tab.id, profile: tab.profile) } else { tab.load(url) }
    }

    static func copy(_ mark: BrowserBookmark, store: NativeBrowserTabs) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mark.url, forType: .string)
        store.show("Address copied")
    }
}

/// More (three dots) with the tab's live values: every action the toolbar's icons and the old profile menu had.
struct NativeBrowserMoreCard: View {
    let store: NativeBrowserTabs
    let tab: NativeBrowserTab
    /// The window's split switch is offered here (the main window only), as a session's header offers it.
    var splitOffered = false

    var body: some View {
        BrowserMoreMenu(model: model, act: perform)
    }

    private var model: BrowserMoreModel {
        var annotating = tab.inspecting, drawing = false
        switch tab.markup {
        case .annotate: annotating = true
        case .draw: drawing = true
        case nil: break
        }
        let layout = splitOffered ? AppModel.shared.tabs?.layout : nil
        return BrowserMoreModel(
            hasPage: tab.url != nil && !tab.showsStartView,
            hasAddress: tab.url != nil,
            annotating: annotating,
            drawing: drawing,
            recording: tab.recording,
            recordedSteps: tab.recording ? 0 : tab.steps.count,
            zoom: BrowserZoom.percent(tab.zoom),
            isolated: tab.isolated,
            split: layout.flatMap { $0.modeSwitch ? $0.mode == "split" : nil },
            bookmarksAlways: NativeBrowserBookmarksStore.shared.alwaysShowBar,
            bookmarks: NativeBrowserBookmarksStore.shared.list(profile: tab.profile),
            size: BrowserSizeModel(deviceID: tab.deviceID, landscape: tab.deviceLandscape, phoneUserAgent: tab.mobileUserAgent,
                                   custom: "\(tab.customWidth) × \(tab.customHeight)"),
            machines: NativeBRMachines.shared.rows(for: tab))
    }

    private func perform(_ action: BrowserMoreAction) {
        switch action {
        case .newTab: store.create(after: tab.id)
        case .newIsolatedTab: store.create(after: tab.id, isolated: true, profile: tab.profile)
        case .annotate: tab.toggleAnnotate() // lane BR: the live picker first, as the web browser's Annotate
        case .screenshot: tab.takeShot()
        case .draw: tab.startMarkup(annotate: false)
        case .record: tab.toggleRecording()
        case .showFlow: tab.flowHidden = false
        case .devtools: tab.showWebInspector()
        case .zoomOut: tab.zoom(by: -1)
        case .zoomReset: tab.resetZoom()
        case .zoomIn: tab.zoom(by: 1)
        case .find: tab.showFind()
        case .print: tab.printPage()
        case .copyAddress: tab.copyAddress()
        case .openInBrowser: tab.openInDefaultBrowser()
        case .toggleIsolated: tab.switchStore(profile: tab.profile, isolated: !tab.isolated)
        case .toggleSplit:
            if let layout = AppModel.shared.tabs?.layout { AppModel.shared.runButton(.setMode(layout.mode == "split" ? "terminal" : "split")) }
        case .home: tab.goHome()
        case .setStartPage: tab.setAsStartPage()
        case .store: AppModel.shared.select("store") // lane BR: the Store page (App.tsx showPanel('store'))
        case .settings: NativeBrowserSettingsWindow.show()
        case .size(let id): tab.deviceID = id
        case .landscape(let on): tab.deviceLandscape = on
        case .phoneUserAgent(let on): tab.setMobileUserAgent(on)
        case .bookmarksAlways(let on): NativeBrowserBookmarksStore.shared.alwaysShowBar = on
        case .openBookmark(let address): if let url = URL(string: address) { tab.load(url) }
        case .machine(let id): NativeBRMachines.shared.select(id, for: tab)
        }
    }
}

// MARK: - Toolbar row (the web browser's, in its order)

struct NativeBrowserToolbarRow: View {
    @Environment(\.nativeScreenActive) private var screenActive
    @Environment(\.nativeSessionInputScope) private var inputScope
    @State private var inputRule = NativeSessionInputRule()
    let store: NativeBrowserTabs
    @Bindable var tab: NativeBrowserTab
    var modeSwitch = false
    @State private var inMainWindow = false
    /// The toolbar's open card (one at a time; a press anywhere else closes it).
    @State private var menu: BrowserChromeMenu?
    /// A narrow toolbar (a split pane): Connect shows its glyph only.
    @State private var compact = false
    @State private var address = ""
    @FocusState private var addressFocused: Bool
    @State private var selection: TextSelection?
    /// What the person typed themselves, without the completion's added tail.
    @State private var typedByHand = ""
    /// The completion standing in the field, and the visited address it came
    /// from: Enter on it goes to exactly that address (its https included), not
    /// back through the address rules, which make a bare host http://.
    @State private var completed: (text: String, url: String)?
    @State private var applyingCompletion = false
    @State private var completionInput: String?

    private var hasPage: Bool { tab.url != nil && !tab.showsStartView }
    private var isAnnotating: Bool { if case .annotate = tab.markup { true } else { false } }
    private var isDrawing: Bool { if case .draw = tab.markup { true } else { false } }

    var body: some View {
        inputRule.bind(to: inputScope)
        inputRule.update(active: inputScope == nil ? screenActive : true, enabled: true)
        return BrowserToolbarFrame {
            navigation
        } address: {
            addressField
        } trailing: {
            // The page tools, like Chrome's extensions (owner, 18 Nov: "We can have extension like this way"): a small
            // group right of the address; the rest is behind the three dots. A narrow pane keeps them behind the dots.
            if !compact { toolGroup }
            modePills
            // ONE Connect control (owner, 18 Nov: "keep one icon only, disconnect and connect, not two").
            NativeBrowserConnectButton(tabId: tab.id, compact: compact, open: menu == .connect) { toggle(.connect) }
                .deckMenu(isPresented: shows(.connect), alignment: .trailing, width: BrowserToolbarMetrics.connectWidth) {
                    NativeBrowserConnectCard(tabId: tab.id)
                }
            NativeBrowserDownloadsButton(store: store)
            NativeBrowserProfileButton(store: store, tab: tab, open: menu == .profile) { toggle(.profile) }
                .deckMenu(isPresented: shows(.profile), alignment: .trailing, width: BrowserToolbarMetrics.profileWidth) {
                    NativeBrowserProfileCard(store: store, tab: tab, screenActive: screenActive, inputScope: inputScope)
                }
            // Three dots: every other action, as labelled rows (BrowserMoreMenu).
            BrowserToolbarButton(label: "More", help: "More", active: menu == .more, action: { toggle(.more) }) {
                Image(systemName: "ellipsis").rotationEffect(.degrees(90))
            }
            .deckMenu(isPresented: shows(.more), alignment: .trailing, width: BrowserToolbarMetrics.moreWidth) {
                NativeBrowserMoreCard(store: store, tab: tab, splitOffered: modeSwitch && inMainWindow)
            }
            // Screenshot's card (More ▸ Screenshot, and a finished drawing) opens under the More button.
            .popover(item: $tab.pendingShot, arrowEdge: .bottom) { shot in
                NativeBrowserShotView(shot: shot, tabID: tab.id) { tab.pendingShot = nil }
            }
        }
        .background(NativeSessionChrome.ground)
        .environment(\.colorScheme, NativeSessionChrome.scheme.isLight ? .light : .dark)
        .onGeometryChange(for: Bool.self, of: { $0.size.width < BrowserToolbarMetrics.compactUnder }) { compact = $0 }
        .background(NativeWindowReader { window in
            inMainWindow = window != nil && window === AppModel.shared.web.webView.window
        })
        .task { NativeBRMachines.shared.start() } // lane BR: which machine serves a page (the address field's word)
        .onAppear {
            address = BrowserAddress.display(tab.url)
            // An empty tab he opened puts his cursor in its address bar; a page's own new window (it has no address
            // until WebKit loads it) never does (MAC-NEXT-15).
            if tab.url == nil, !tab.openedByPage { addressFocused = true }
        }
        .onChange(of: tab.url) {
            if !addressFocused { address = BrowserAddress.display(tab.url) }
        }
        .onChange(of: tab.suggestions) { applyCompletion() }
        .onChange(of: tab.focusAddressRequest) { addressFocused = true }
        .onChange(of: addressFocused) { _, focused in
            if focused { typedByHand = address }
            if !focused { completed = nil; completionInput = nil }
            if !focused, tab.url != nil { address = BrowserAddress.display(tab.url) }
            if !focused {
                // A beat later, so a click on a suggestion lands before the list goes.
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    if !addressFocused { tab.dismissSuggestions() }
                }
            }
        }
    }

    private func toggle(_ card: BrowserChromeMenu) { menu = menu == card ? nil : card }

    /// The card's own "is it open": the shared menu sets it false when a press elsewhere or Escape closes it.
    private func shows(_ card: BrowserChromeMenu) -> Binding<Bool> {
        Binding(get: { menu == card }, set: { open in
            if open { menu = card } else if menu == card { menu = nil }
        })
    }

    // back · forward · reload/stop (Home is in More)
    @ViewBuilder private var navigation: some View {
        BrowserToolbarButton("Back", "chevron.left", help: "Back (⌘[)") { tab.goBack() }
            .disabled(!tab.canGoBack && tab.failure == nil && !tab.showingHome)
            .contextMenu { historyMenu(tab.backList) }
        BrowserToolbarButton("Forward", "chevron.right", help: "Forward (⌘])") { tab.goForward() }
            .disabled(!tab.canGoForward)
            .contextMenu { historyMenu(tab.forwardList) }
        if tab.isLoading {
            BrowserToolbarButton("Stop loading", "xmark", help: "Stop loading (⌘.)") { tab.stop() }
        } else {
            BrowserToolbarButton("Reload", "arrow.clockwise", help: "Reload (⌘R)") { tab.reload() }
                .disabled(tab.url == nil && tab.failure == nil)
        }
    }

    private var addressField: some View {
        BrowserAddressPill(focused: addressFocused) {
            NativeBrowserServedMark(tab: tab) // lane BR: which machine serves this page (served-mark.ts)
            NativeSessionTextField("Enter a URL, or search", text: $address, selection: $selection)
                .sessionFocused($addressFocused)
                .onSubmit(go)
                .onExitCommand {
                    address = BrowserAddress.display(tab.url)
                    addressFocused = false
                }
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .onChange(of: address) { _, now in edited(now) }
            if tab.zoom != 1 {
                NativeSessionButton(BrowserZoom.percent(tab.zoom)) { tab.resetZoom() }
                    .buttonStyle(.borderless)
                    .font(.caption.monospacedDigit())
                    .help("Reset zoom")
            }
            // The bookmark star, on every web page (owner, 18 Nov: "We can have bookmarks over here").
            if hasPage, let url = tab.url, BrowserHistory.visitable(url.absoluteString) != nil {
                BrowserBookmarkStar(saved: NativeBrowserBookmarksStore.shared.contains(profile: tab.profile, url: url)) {
                    let added = NativeBrowserBookmarksStore.shared.toggle(profile: tab.profile, url: url, title: tab.title,
                                                                         favicon: tab.favicon)
                    if let added { store.show(added ? "Bookmark added" : "Bookmark removed") }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if addressFocused && !tab.suggestions.isEmpty {
                NativeBrowserSuggestions(tab: tab) { open($0) }
                    .offset(y: BrowserToolbarMetrics.addressHeight + 4)
            }
        }
    }

    /// Annotate, Screenshot, Record: one press each. Annotate and Record are pills while they are on (`modePills`).
    @ViewBuilder private var toolGroup: some View {
        if !(isAnnotating || tab.inspecting) {
            BrowserToolbarButton("Annotate", "cursorarrow.rays",
                                 help: "Annotate: mark things on the page, say what should change, send it to a session") {
                tab.toggleAnnotate() // lane BR: the live picker first, as the web browser's Annotate
            }
            .disabled(!hasPage)
        }
        BrowserToolbarButton("Screenshot", "camera", help: "Screenshot: a picture of the page to copy or send to a session") {
            tab.takeShot()
        }
        .disabled(!hasPage)
        if !tab.recording {
            BrowserToolbarButton("Record", "record.circle", help: "Record: write down every click, entry and navigation as a flow") {
                tab.toggleRecording()
            }
            .disabled(!hasPage)
        }
    }

    /// A mode that is on shows as a pill here, and the pill turns it off. Nothing shows while none is on.
    @ViewBuilder private var modePills: some View {
        if isAnnotating || tab.inspecting {
            BrowserModePill(text: "Annotating", symbol: "cursorarrow.rays", help: "Stop annotating") { tab.toggleAnnotate() }
        }
        if tab.recording {
            BrowserModePill(text: tab.steps.count > 1 ? "Recording · \(tab.steps.count)" : "Recording", symbol: "record.circle.fill",
                            tint: .red, help: "Stop recording") { tab.toggleRecording() }
        }
        if isDrawing {
            BrowserModePill(text: "Drawing", symbol: "pencil.tip", help: "Leave drawing without saving") {
                tab.startMarkup(annotate: false)
            }
        }
        if tab.deviceID != nil {
            BrowserModePill(text: BrowserSizeModel(deviceID: tab.deviceID).label, symbol: "iphone",
                            help: "Fill the window again") { tab.deviceID = nil }
        }
    }

    /// The web toolbar's inline completion: on an insertion, the top suggestion
    /// finishes what was typed and the added part is selected, so the next key
    /// replaces it. Never on a deletion — Backspace must be able to delete.
    private func edited(_ now: String) {
        guard inputRule.acceptsFocus else { return }
        if applyingCompletion {
            applyingCompletion = false
            return
        }
        guard addressFocused else { return }
        let inserting = now.count > typedByHand.count
        typedByHand = now
        completed = nil
        completionInput = inserting ? now : nil
        tab.updateSuggestions(for: now)
        applyCompletion()
    }

    private func applyCompletion() {
        guard inputRule.acceptsFocus, addressFocused, let now = completionInput, address == now, typedByHand == now,
              let top = tab.suggestions.first,
              let filled = BrowserHistory.completion(typed: now, url: top.url) else { return }
        completionInput = nil
        completed = (filled, top.url)
        applyingCompletion = true
        address = filled
        let from = filled.index(filled.startIndex, offsetBy: now.count)
        selection = TextSelection(range: from..<filled.endIndex)
    }

    private func open(_ suggested: String) {
        guard inputRule.acceptsFocus else { return }
        tab.dismissSuggestions()
        load(visited: suggested)
    }

    /// A visited address goes straight to the tab — it is already a URL.
    private func load(visited: String) {
        guard let url = URL(string: visited) else { return }
        tab.load(url)
        finishEditing()
    }

    private func finishEditing() {
        completed = nil
        typedByHand = ""
        address = BrowserAddress.display(tab.url)
        addressFocused = false
        if let webView = tab.webView { webView.window?.makeFirstResponder(webView) }
    }

    private func go() {
        guard inputRule.acceptsFocus else { return }
        if tab.suggestionCursor >= 0, tab.suggestionCursor < tab.suggestions.count {
            let chosen = tab.suggestions[tab.suggestionCursor].url
            tab.dismissSuggestions()
            load(visited: chosen)
            return
        }
        tab.dismissSuggestions()
        if let completed, completed.text == address {
            load(visited: completed.url)
            return
        }
        let typed = address
        guard BrowserAddress.resolve(typed).target != nil else { return }
        tab.navigate(typed)
        finishEditing()
    }

    @ViewBuilder private func historyMenu(_ items: [WKBackForwardListItem]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            NativeSessionButton(item.title?.isEmpty == false ? item.title! : item.url.absoluteString) { tab.go(to: item) }
        }
    }
}

/// A toolbar glyph with its name on hover, like the web browser's `IconButton`.
struct NativeBrowserIcon: View {
    let label: String
    let symbol: String
    let help: String
    var pressed = false
    var tint: Color?
    let action: () -> Void

    init(_ label: String, _ symbol: String, help: String, pressed: Bool = false, tint: Color? = nil,
         action: @escaping () -> Void) {
        self.label = label
        self.symbol = symbol
        self.help = help
        self.pressed = pressed
        self.tint = tint
        self.action = action
    }

    var body: some View {
        NativeSessionButton(action: action) {
            Label(label, systemImage: symbol)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 26, height: 26)
                .foregroundStyle(pressed ? AnyShapeStyle(tint ?? Color.primary) : AnyShapeStyle(Color.secondary))
                .background(pressed ? AnyShapeStyle((tint ?? Color.primary).opacity(0.14)) : AnyShapeStyle(.clear),
                            in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .help(help)
        .accessibilityLabel(label)
    }
}

struct NativeBrowserProgressLine: View {
    let tab: NativeBrowserTab

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(NativeSessionChrome.accent)
                .frame(width: geometry.size.width * max(0.05, tab.progress))
                .opacity(tab.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: tab.progress)
                .animation(.easeOut(duration: 0.3), value: tab.isLoading)
        }
        .frame(height: 2)
    }
}

// MARK: - Handover

/// An agent gave this page to the person: what it asks, and the two answers.
/// Nothing typed here is seen by the agent; it can neither read nor act until Done.
struct NativeBrowserHandoverBar: View {
    let tab: NativeBrowserTab
    let prompt: String

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.orange).frame(width: 8, height: 8)
            HStack(spacing: 0) {
                Text(BRHandoverWords.text(prompt: prompt)).lineLimit(2)
                Text(BRHandoverWords.site(tab.url)).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.callout)
            Spacer()
            NativeSessionButton(BRHandoverWords.carryOn) { tab.endHandover("resumed") }
                .buttonStyle(.borderedProminent)
                .help("Give the page back to the agent")
            NativeSessionButton(BRHandoverWords.stop) { tab.endHandover("stopped") }
                .help("Tell the agent not to carry on")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: - Find in page

struct NativeBrowserFindBar: View {
    @Bindable var tab: NativeBrowserTab
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            NativeSessionTextField("Find in page", text: $tab.findText)
                .sessionFocused($focused)
                .onSubmit { tab.findAgain(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onExitCommand { tab.hideFind() }
                .textFieldStyle(.plain)
                .frame(maxWidth: 280)
                .onChange(of: tab.findText) { tab.findFromStart() }
            if tab.findMissed && !tab.findText.isEmpty {
                Text("Not found").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { tab.findAgain(backwards: true) } label: { Image(systemName: "chevron.up") }
                .help("Previous (⇧⌘G)")
                .disabled(tab.findText.isEmpty)
            Button { tab.findAgain(backwards: false) } label: { Image(systemName: "chevron.down") }
                .help("Next (⌘G)")
                .disabled(tab.findText.isEmpty)
            NativeSessionButton("Done") { tab.hideFind() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
        .onAppear { focused = true }
        .onChange(of: tab.focusFindRequest) { focused = true }
    }
}

// MARK: - The page

struct NativeBrowserContent: View {
    @Environment(\.nativeTerminalSelected) private var selected
    let tab: NativeBrowserTab

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                if let preset = BRDeviceSize.frame(deviceID: tab.deviceID, customWidth: tab.customWidth, customHeight: tab.customHeight) {
                    let fit = BrowserDevicePreset.fit(width: preset.width, height: preset.height,
                                                      landscape: tab.deviceLandscape,
                                                      into: (geometry.size.width - 24, geometry.size.height - 40))
                    VStack(spacing: 6) {
                        Text("\(preset.label) — \(Int(fit.width)) × \(Int(fit.height))\(fit.clamped ? " (shrunk to fit)" : "")")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        NativeBrowserPageHost(webView: tab.webView)
                            .frame(width: max(1, fit.width), height: max(1, fit.height))
                            .overlay(Rectangle().strokeBorder(.separator))
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    }
                    .padding(.top, 10)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                    .background(.quaternary.opacity(0.35))
                } else {
                    NativeBrowserPageHost(webView: tab.webView)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .modifier(NativeBrowserPageVisibility(covered: tab.showsStartView, selected: selected ?? true))
            .opacity(tab.showsStartView ? 0 : 1)
            .allowsHitTesting(!tab.showsStartView)

            if tab.showsStartView {
                NativeBrowserStartView(tab: tab)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if tab.recording && !tab.showsStartView { NativeBrowserRecordingBadge() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .driveAnchor(DriveAnchors.pageId) // Hoot's tour can box the page (the web's `.bw-stage`)
    }
}

/// Holds the tab's web view; the page is never reloaded by being shown again.
/// Native overlays close only the page subtree's gate; their own editors stay live.
struct NativeBrowserPageVisibility: ViewModifier {
    @Environment(\.nativeScreenActive) private var active
    let covered: Bool
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.nativeScreenActive, active && !covered)
            .environment(\.nativeTerminalSelected, selected)
    }
}

struct NativeBrowserPageHost: NSViewRepresentable {
    @Environment(\.nativeScreenActive) private var active
    @Environment(\.nativeTerminalSelected) private var selected
    @Environment(\.nativeSessionInputScope) private var scope
    let webView: WKWebView?

    // L1-SHELL: glass (not white) until the page first paints, then a 0.15 s fade in.
    func makeNSView(context: Context) -> NativeBrowserPageSlot { NativeBrowserPageSlot(frame: .zero) }

    func updateNSView(_ container: NativeBrowserPageSlot, context: Context) {
        container.show(webView, active: active, selected: selected ?? true, scope: scope)
    }

    static func dismantleNSView(_ container: NativeBrowserPageSlot, coordinator: ()) {
        container.show(nil, active: false)
    }
}

/// Opacity does not remove WKWebView's private text client from the responder
/// chain. Detach the cached page while hidden, preserving its navigation/process.
@MainActor
final class NativeBrowserPageSlot: NSView, NativeSessionInputProtected {
    let inputRule = NativeSessionInputRule()
    private let paint = DeckWebPaintHost(frame: .zero)
    private weak var page: WKWebView?
    private var active = false
    private var selected = true
    private weak var scope: NativeSessionInputScope?
    private static let slots = NSHashTable<NativeBrowserPageSlot>.weakObjects()
    private var keyObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        paint.frame = bounds
        paint.autoresizingMask = [.width, .height]
        addSubview(paint)
        Self.slots.add(self)
        inputRule.owner = self
        inputRule.onScopeWillDeactivate = { [weak self] in
            guard let self else { return }
            if !self.active || self.scope?.active == false || !self.inputRule.active { self.releasePage() }
            else { self.releaseKeyboard() }
        }
        inputRule.onScopeChanged = { [weak self] in self?.refreshAttachment() }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                            object: nil, queue: .main) { [weak self] note in
            let notifiedWindow = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, self.window.map(ObjectIdentifier.init) == notifiedWindow else { return }
                self.refreshAttachment()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    isolated deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    func show(_ next: WKWebView?, active: Bool, selected: Bool = true, scope: NativeSessionInputScope? = nil) {
        if page !== next { releasePage() }
        page = next
        self.active = active
        self.selected = selected
        self.scope = scope
        inputRule.bind(to: scope)
        // Local covers must close this subtree even while their outer browser
        // scope remains active for the annotation or address editor.
        inputRule.update(active: active, enabled: selected)
        refreshAttachment()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { releasePage() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshAttachment()
    }

    private func refreshAttachment() {
        guard active, scope?.active != false, window != nil else { releasePage(); return }
        if !selected { releaseKeyboard() }
        attach()
    }

    private func attach() {
        guard active, scope?.active != false, let page, let window else { return }
        if let owner = Self.slots.allObjects.first(where: { $0 !== self && page.superview === $0.paint }), owner.active {
            if owner.selected && !selected { return }
            if owner.window?.isKeyWindow == true && !window.isKeyWindow { return }
        }
        // show never asks for focus. Returning a background browser cannot take
        // the person's keyboard from the visible session or another field.
        paint.show(page)
    }

    private func releaseKeyboard() {
        guard let page, page.superview === paint else { return }
        let oldWindow = window ?? page.window
        if let responder = oldWindow?.firstResponder as? NSView,
           responder === page || responder.isDescendant(of: page) {
            responder.inputContext?.discardMarkedText()
            oldWindow?.makeFirstResponder(nil)
        }
        if let oldWindow { DeckTerminalSlot.restoreFocus(in: oldWindow, request: false) }
    }

    private func releasePage() {
        guard let page, page.superview === paint else { return }
        let oldWindow = window ?? page.window
        releaseKeyboard()
        paint.show(nil)
        // A pop-out or split can retain another visible host of this same page.
        let survivor = Self.slots.allObjects.first {
            $0 !== self && $0.active && $0.scope?.active != false && $0.page === page && $0.window?.isKeyWindow == true
        } ?? Self.slots.allObjects.first {
            $0 !== self && $0.active && $0.scope?.active != false && $0.page === page && $0.window != nil
        }
        survivor?.attach()
        if let oldWindow { DeckTerminalSlot.restoreFocus(in: oldWindow, request: false) }
    }
}

// MARK: - Keyboard

/// Browser shortcuts while this screen is in the key window — ahead of the app's
/// menu, so ⌘T is a new browser tab here rather than a new session.
struct NativeBrowserKeyCatcher: NSViewRepresentable {
    @Environment(\.nativeScreenActive) private var active
    let handle: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.handle = active ? handle : nil
        return view
    }

    func updateNSView(_ view: KeyCatcherView, context: Context) {
        view.handle = active ? handle : nil
    }

    static func dismantleNSView(_ view: KeyCatcherView, coordinator: ()) { view.stopMonitoring() }

    final class KeyCatcherView: NSView {
        var handle: ((NSEvent) -> Bool)?
        private var monitor: Any?

        isolated deinit { stopMonitoring() }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let used = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window, event.window === window,
                          window.isKeyWindow, window.attachedSheet == nil,
                          !self.isHiddenOrHasHiddenAncestor else { return false }
                    return self.handle?(event) ?? false
                }
                return used ? nil : event
            }
        }
    }
}
