import AppKit
import SwiftUI
import WebKit
import TerminalDeckNativeCore

/// One browser tab, drawn in Swift on WKWebView (Safari's engine). The tab
/// itself sits in the main window's strip beside the sessions (see
/// `NativeBrowserTabs`); this is what the window shows for it — the web
/// browser's toolbar, in the same order:
///
///   back · forward · reload/stop · home · [Enter a URL, or search] ·
///   Shared/Isolated · Annotate · Record · Shot · Draw · Size · Devtools ·
///   Downloads · Profile · ⋮
///
/// then the progress line, find in page, the handover and Record panels, and
/// the page (or "Open a page"); Annotate and Draw freeze the page over it.
/// The machine picker (pages on another computer) is not here yet.
/// Agent driving of this browser (the engine's `browser_*` tools) is a later step.
struct NativeBrowserScreen: View {
    let tabId: String
    @State private var store = NativeBrowserTabs.shared

    var body: some View {
        Group {
            if let tab = store.tab(tabId) {
                NativeBrowserTabView(store: store, tab: tab)
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
    let store: NativeBrowserTabs
    let tab: NativeBrowserTab

    var body: some View {
        VStack(spacing: 0) {
            NativeBrowserToolbarRow(store: store, tab: tab)
                .zIndex(2) // the suggestions list hangs over the page
            NativeBrowserProgressLine(tab: tab)
            Divider()
            if tab.findVisible && tab.markup == nil {
                NativeBrowserFindBar(tab: tab)
                Divider()
            }
            if let prompt = tab.handoverPrompt {
                NativeBrowserHandoverBar(tab: tab, prompt: prompt)
                Divider()
            }
            if tab.recording || !tab.steps.isEmpty {
                NativeBrowserRecordPanel(tab: tab)
                Divider()
            }
            ZStack {
                // Parked while the page is frozen for Annotate or Draw, as the web browser parks its view.
                NativeBrowserContent(tab: tab)
                    .opacity(tab.markup == nil ? 1 : 0)
                    .allowsHitTesting(tab.markup == nil)
                switch tab.markup {
                case .annotate(let shot): NativeBrowserAnnotateView(tab: tab, shot: shot)
                case .draw(let shot): NativeBrowserDrawView(tab: tab, shot: shot)
                case nil: EmptyView()
                }
            }
        }
        .background(NativeBrowserKeyCatcher { tab.handleKey($0) })
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

// MARK: - Toolbar row (the web browser's, in its order)

struct NativeBrowserToolbarRow: View {
    let store: NativeBrowserTabs
    @Bindable var tab: NativeBrowserTab
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

    private var hasPage: Bool { tab.url != nil && !tab.showsStartView }
    private var isAnnotating: Bool { if case .annotate = tab.markup { true } else { false } }
    private var isDrawing: Bool { if case .draw = tab.markup { true } else { false } }

    var body: some View {
        HStack(spacing: 4) {
            navigation
            addressField
            tools
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
        .onAppear {
            address = BrowserAddress.display(tab.url)
            if tab.url == nil { addressFocused = true }
        }
        .onChange(of: tab.url) {
            if !addressFocused { address = BrowserAddress.display(tab.url) }
        }
        .onChange(of: tab.focusAddressRequest) { addressFocused = true }
        .onChange(of: addressFocused) { _, focused in
            if focused { typedByHand = address }
            if !focused { completed = nil }
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

    // back · forward · reload/stop · home
    private var navigation: some View {
        HStack(spacing: 2) {
            NativeBrowserIcon("Back", "chevron.left", help: "Back (⌘[)") { tab.goBack() }
                .disabled(!tab.canGoBack && tab.failure == nil && !tab.showingHome)
                .contextMenu { historyMenu(tab.backList) }
            NativeBrowserIcon("Forward", "chevron.right", help: "Forward (⌘])") { tab.goForward() }
                .disabled(!tab.canGoForward)
                .contextMenu { historyMenu(tab.forwardList) }
            if tab.isLoading {
                NativeBrowserIcon("Stop loading", "xmark", help: "Stop loading (⌘.)") { tab.stop() }
            } else {
                NativeBrowserIcon("Reload", "arrow.clockwise", help: "Reload (⌘R)") { tab.reload() }
                    .disabled(tab.url == nil && tab.failure == nil)
            }
            NativeBrowserIcon("Home", "house", help: "Home (⇧⌘H)") { tab.goHome() }
        }
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            TextField("Enter a URL, or search", text: $address, selection: $selection)
                .textFieldStyle(.plain)
                .focused($addressFocused)
                .autocorrectionDisabled()
                .onSubmit(go)
                .onChange(of: address) { _, now in edited(now) }
                .onExitCommand {
                    address = BrowserAddress.display(tab.url)
                    addressFocused = false
                }
            if tab.zoom != 1 {
                Button(BrowserZoom.percent(tab.zoom)) { tab.resetZoom() }
                    .font(.caption.monospacedDigit())
                    .help("Reset zoom")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(addressFocused ? 0.7 : 0), lineWidth: 1.5)
        }
        .overlay(alignment: .topLeading) {
            if addressFocused && !tab.suggestions.isEmpty {
                NativeBrowserSuggestions(tab: tab) { open($0) }
                    .offset(y: 32)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    // Shared/Isolated · Annotate · Record · Shot · Draw · Size · Devtools · Downloads · Profile · ⋮
    private var tools: some View {
        HStack(spacing: 2) {
            NativeBrowserIcon(tab.isolated ? "Isolated" : "Shared",
                              tab.isolated ? "lock" : "person.2",
                              help: tab.isolated
                                ? "Isolated: this tab keeps its own cookies, in memory only"
                                : "Shared: this tab uses the profile's cookies",
                              pressed: tab.isolated) {
                tab.switchStore(profile: tab.profile, isolated: !tab.isolated)
            }

            NativeBrowserIcon("Annotate", "text.bubble", help: "Annotate — mark things on the page, say what should change, send it to a session",
                              pressed: isAnnotating) {
                tab.startMarkup(annotate: true)
            }
            .disabled(!hasPage)

            NativeBrowserIcon(tab.recording ? (tab.steps.count > 1 ? "Stop (\(tab.steps.count))" : "Stop") : "Record",
                              tab.recording ? "stop.circle.fill" : "record.circle",
                              help: tab.recording ? "Stop recording" : "Record — write down every click, entry and navigation as a flow",
                              pressed: tab.recording, tint: tab.recording ? .red : nil) {
                tab.toggleRecording()
            }
            .disabled(!hasPage && !tab.recording)

            NativeBrowserIcon("Shot", "camera", help: "Shot — a picture of the page to copy or send to a session") {
                tab.takeShot()
            }
            .disabled(!hasPage)
            .popover(item: $tab.pendingShot, arrowEdge: .bottom) { shot in
                NativeBrowserShotView(shot: shot) { tab.pendingShot = nil }
            }

            NativeBrowserIcon("Draw", "pencil.tip", help: "Draw — mark up a screenshot of the page, then copy it or send it",
                              pressed: isDrawing) {
                tab.startMarkup(annotate: false)
            }
            .disabled(!hasPage)

            NativeBrowserSizeMenu(tab: tab)
                .disabled(!hasPage)

            NativeBrowserIcon("Devtools", "chevron.left.forwardslash.chevron.right",
                              help: "Devtools — Safari's Web Inspector (⌥⌘I, or right-click ▸ Inspect Element)") {
                tab.showWebInspector()
            }
            .disabled(!hasPage)

            // Exactly the web toolbar's rule: there while the list has a row (kept
            // across relaunch), gone when it is empty; ⋮ ▸ Downloads always reaches it.
            if store.downloads.badge != nil {
                NativeBrowserDownloadsButton(store: store)
            }

            NativeBrowserProfileButton(store: store, tab: tab)

            NativeBrowserMoreMenu(store: store, tab: tab)
        }
    }

    /// The web toolbar's inline completion: on an insertion, the top suggestion
    /// finishes what was typed and the added part is selected, so the next key
    /// replaces it. Never on a deletion — Backspace must be able to delete.
    private func edited(_ now: String) {
        if applyingCompletion {
            applyingCompletion = false
            return
        }
        guard addressFocused else { return }
        let inserting = now.count > typedByHand.count
        typedByHand = now
        completed = nil
        tab.updateSuggestions(for: now)
        guard inserting, let top = tab.suggestions.first,
              let filled = BrowserHistory.completion(typed: now, url: top.url) else { return }
        completed = (filled, top.url)
        applyingCompletion = true
        address = filled
        let from = filled.index(filled.startIndex, offsetBy: now.count)
        selection = TextSelection(range: from..<filled.endIndex)
    }

    private func open(_ suggested: String) {
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
            Button(item.title?.isEmpty == false ? item.title! : item.url.absoluteString) { tab.go(to: item) }
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
        Button(action: action) {
            Label(label, systemImage: symbol)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 26, height: 26)
                .foregroundStyle(pressed ? AnyShapeStyle(tint ?? Color.accentColor) : AnyShapeStyle(.primary))
                .background(pressed ? AnyShapeStyle((tint ?? Color.accentColor).opacity(0.14)) : AnyShapeStyle(.clear),
                            in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .help(help)
        .accessibilityLabel(label)
    }
}

/// "Size": the page in a device's frame, as the web browser's device bar offers.
struct NativeBrowserSizeMenu: View {
    @Bindable var tab: NativeBrowserTab

    var body: some View {
        Menu {
            Button {
                tab.deviceID = nil
            } label: {
                if tab.deviceID == nil { Label("Fill the window", systemImage: "checkmark") } else { Text("Fill the window") }
            }
            Divider()
            ForEach(BrowserDevicePreset.all) { preset in
                Button {
                    tab.deviceID = preset.id
                } label: {
                    let text = "\(preset.label) — \(preset.width) × \(preset.height)"
                    if tab.deviceID == preset.id { Label(text, systemImage: "checkmark") } else { Text(text) }
                }
            }
            Divider()
            Toggle("Landscape", isOn: $tab.deviceLandscape)
                .disabled(tab.deviceID == nil)
            Toggle("Phone user agent", isOn: Binding(get: { tab.mobileUserAgent },
                                                     set: { tab.setMobileUserAgent($0) }))
        } label: {
            Label("Size", systemImage: "iphone")
                .font(.system(size: 13))
                .frame(width: 26, height: 26)
                .foregroundStyle(tab.deviceID != nil ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .background(tab.deviceID != nil ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(.clear),
                            in: .rect(cornerRadius: 6))
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Size — show the page at a phone, tablet or desktop size")
    }
}

/// ⋮ — the page in front of you, and what this browser remembers about it.
struct NativeBrowserMoreMenu: View {
    @Bindable var store: NativeBrowserTabs
    let tab: NativeBrowserTab

    /// With no Downloads button on the bar, the list opens from here instead
    /// (the web browser's "standing door").
    private var listFromHere: Binding<Bool> {
        Binding(get: { store.downloadsShown && store.downloads.badge == nil },
                set: { if !$0 { store.downloadsShown = false } })
    }

    var body: some View {
        Menu {
            Button("New Tab") { store.create(after: tab.id) }
            Button("New Isolated Tab") { store.create(after: tab.id, isolated: true, profile: tab.profile) }
            Divider()
            Button("Downloads") { store.downloadsShown = true }
            Button("Open Downloads Folder") { store.downloads.openDownloadsFolder() }
            Button("Set as Start Page") { tab.setAsStartPage() }
                .disabled(tab.url == nil)
            Button("Open in Your Browser") { tab.openInDefaultBrowser() }
                .disabled(tab.url == nil)
            Button("Copy Address") { tab.copyAddress() }
                .disabled(tab.url == nil)
            Divider()
            Button("Zoom Out") { tab.zoom(by: -1) }.disabled(tab.url == nil)
            Button("Actual Size (\(BrowserZoom.percent(tab.zoom)))") { tab.resetZoom() }.disabled(tab.url == nil)
            Button("Zoom In") { tab.zoom(by: 1) }.disabled(tab.url == nil)
            Divider()
            Button("Find in Page") { tab.showFind() }.disabled(tab.url == nil || tab.showsStartView)
            Button("Print…") { tab.printPage() }.disabled(tab.url == nil || tab.showsStartView)
        } label: {
            Label("More", systemImage: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 13))
                .frame(width: 26, height: 26)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More")
        .popover(isPresented: listFromHere, arrowEdge: .bottom) {
            NativeBrowserDownloadsList(downloads: store.downloads)
        }
    }
}

struct NativeBrowserProgressLine: View {
    let tab: NativeBrowserTab

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geometry.size.width * max(0.05, tab.progress))
                .opacity(tab.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: tab.progress)
                .animation(.easeOut(duration: 0.3), value: tab.isLoading)
        }
        .frame(height: 2)
        .background(.bar)
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
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Hoot needs you").font(.callout.weight(.semibold))
                Text(prompt).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Stop") { tab.endHandover("stopped") }
                .help("Tell the agent not to carry on")
            Button("Done") { tab.endHandover("resumed") }
                .buttonStyle(.borderedProminent)
                .help("Give the page back to the agent")
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
            TextField("Find in page", text: $tab.findText)
                .textFieldStyle(.plain)
                .focused($focused)
                .frame(maxWidth: 280)
                .onSubmit { tab.findAgain(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onExitCommand { tab.hideFind() }
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
            Button("Done") { tab.hideFind() }
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
    let tab: NativeBrowserTab

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                if let preset = tab.deviceID.flatMap(BrowserDevicePreset.byID) {
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
struct NativeBrowserPageHost: NSViewRepresentable {
    let webView: WKWebView?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let webView else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}

// MARK: - Keyboard

/// Browser shortcuts while this screen is in the key window — ahead of the app's
/// menu, so ⌘T is a new browser tab here rather than a new session.
struct NativeBrowserKeyCatcher: NSViewRepresentable {
    let handle: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.handle = handle
        return view
    }

    func updateNSView(_ view: KeyCatcherView, context: Context) {
        view.handle = handle
    }

    final class KeyCatcherView: NSView {
        var handle: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
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
