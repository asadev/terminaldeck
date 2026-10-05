import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TerminalDeckNativeCore

// MARK: - "Open a page"

/// What a new tab shows before it has a page — and what it shows instead of an
/// error page when one will not open: the reason, an address box, then what IS
/// listening on this machine right now (the engine's `dev:ports`, the same scan
/// the web browser's start page uses). The web browser's `StartPage`, drawn natively.
struct NativeBrowserStartView: View {
    let tab: NativeBrowserTab
    @State private var typed = ""
    @State private var ports: [BrowserDevPort]?
    @State private var problem: String?
    @State private var showOurs = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let failure = tab.failure {
                    Text("This page did not open")
                        .font(.title2.weight(.semibold))
                    Text(failure.message)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let url = failure.url {
                        Button("Try \(url.absoluteString) again") { tab.load(url) }
                            .controlSize(.large)
                    }
                } else {
                    Text("Open a page")
                        .font(.title2.weight(.semibold))
                }

                HStack(spacing: 8) {
                    TextField("localhost:5173, or any address", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit(open)
                    Button("Open", action: open)
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.large)

                portsSection

                if ports != nil || problem != nil {
                    Button("Scan Again") { Task { await scan(force: true) } }
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .task(id: tab.failure?.url) { await scan(force: tab.failure != nil) }
    }

    @ViewBuilder private var portsSection: some View {
        if let problem {
            Text(problem).foregroundStyle(.secondary)
        } else if let ports {
            let open = ports.filter { !$0.ours }
            let ours = ports.filter(\.ours)
            if open.isEmpty {
                Text(ours.isEmpty
                     ? "Nothing is listening on this machine. Start a dev server, then scan again — or type an address above."
                     : "Nothing is listening on this machine but Terminal Deck itself. Start a dev server, then scan again — or type an address above.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Listening on this machine right now:")
                    .foregroundStyle(.secondary)
                VStack(spacing: 4) {
                    ForEach(open) { port in portRow(port) }
                }
            }
            if !ours.isEmpty {
                DisclosureGroup(isExpanded: $showOurs) {
                    VStack(spacing: 4) {
                        ForEach(ours) { port in portRow(port) }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Terminal Deck's own (\(ours.count))").foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for dev servers…").foregroundStyle(.secondary)
            }
        }
    }

    private func open() {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        tab.navigate(text)
    }

    private func portRow(_ port: BrowserDevPort) -> some View {
        NativeBrowserPortRow(port: port) {
            if let url = URL(string: "http://localhost:\(port.port)/") { tab.load(url) }
        }
    }

    private func scan(force: Bool) async {
        problem = nil
        if force { ports = nil }
        guard EngineBridge.shared.isReady else {
            problem = "The engine is not running, so the open ports cannot be listed."
            return
        }
        do {
            let value = try await EngineBridge.shared.invoke("dev:ports", [force])
            ports = BrowserDevPort.read(value)
        } catch {
            problem = "Could not read the open ports."
        }
    }
}

struct NativeBrowserPortRow: View {
    let port: BrowserDevPort
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Text(":\(port.port)")
                    .font(.body.monospacedDigit().weight(.medium))
                Text(port.process.isEmpty ? "unknown" : port.process)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0.4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(hovering ? 0.9 : 0.45), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open http://localhost:\(port.port)")
    }
}

// MARK: - Send to a session (one row for Shot, Draw, Annotate and Record)

/// A session picker, a line to type, and Send — the web browser's `SendToAgent`.
/// `makeLine` turns what was typed into the one line the session receives (it may
/// save a picture first, and throw a sentence if it could not). The line is typed
/// into the session through the engine's `session:write`: the text, a short
/// pause, then Return.
struct NativeBrowserSendRow: View {
    var placeholder: String
    var action = "Send"
    /// The box must have something in it (Annotate's "What should change?").
    var needsText = false
    var multiline = false
    /// Nothing to send yet, said on the button's hover only.
    var notReady = ""
    /// Take the caret on appearing (not for Record, whose page is still in use).
    var autofocus = true
    var makeLine: (String) async throws -> String
    var onSent: (BrowserSessionChoice) -> Void = { _ in }

    @State private var sessions: [BrowserSessionChoice]?
    @State private var chosen = ""
    @State private var instruction = ""
    @State private var sending = false
    @State private var sent = false
    @State private var problem: String?
    @State private var subscriptions: [EngineSubscription] = []
    @FocusState private var fieldFocused: Bool

    private var blocked: Bool {
        chosen.isEmpty || !notReady.isEmpty || (needsText && instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("To", selection: $chosen) {
                Text(sessions == nil ? "Loading sessions…" : "Choose a session…").tag("")
                ForEach(sessions ?? []) { session in
                    Text(session.label).tag(session.id)
                }
            }
            .disabled((sessions ?? []).isEmpty)
            .onChange(of: chosen) { sent = false; problem = nil }

            Group {
                if multiline {
                    TextField(placeholder, text: $instruction, axis: .vertical)
                        .lineLimit(2...5)
                } else {
                    TextField(placeholder, text: $instruction)
                }
            }
            .textFieldStyle(.roundedBorder)
            .focused($fieldFocused)
            .onSubmit(send)
            .onChange(of: instruction) { sent = false; problem = nil }

            HStack(alignment: .firstTextBaseline) {
                if let line = statusLine {
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(sending ? "Sending…" : sent ? "Sent" : action, action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(blocked || sending)
                    .help(chosen.isEmpty ? "Choose a session first" : notReady.isEmpty ? "Send to the chosen session" : notReady)
            }
        }
        .task {
            if autofocus { fieldFocused = true }
            await loadSessions()
            subscriptions = [
                EngineBridge.shared.on("session:created") { _ in Task { await loadSessions() } },
                EngineBridge.shared.on("session:exit") { _ in Task { await loadSessions() } },
            ]
        }
        .onDisappear {
            subscriptions.forEach { $0.cancel() }
            subscriptions = []
        }
    }

    private var statusLine: String? {
        if let problem { return problem }
        if let sessions, sessions.isEmpty { return "No sessions are open. Start one, then choose it here." }
        return nil
    }

    private func loadSessions() async {
        guard EngineBridge.shared.isReady else {
            sessions = []
            problem = "The engine is not running, so there is nothing to send to."
            return
        }
        do {
            let list = BrowserSessionChoice.read(try await EngineBridge.shared.invoke("session:list"))
            sessions = list
            if !chosen.isEmpty, !list.contains(where: { $0.id == chosen }) {
                chosen = ""
                problem = "That session has closed. Choose another one."
            }
        } catch {
            sessions = []
            problem = "The sessions could not be listed."
        }
    }

    private func send() {
        guard !blocked, !sending else { return }
        let target = chosen
        sending = true
        problem = nil
        Task {
            defer { sending = false }
            // The list as it is now: a session that exited since it was chosen is refused.
            await loadSessions()
            guard chosen == target, let session = sessions?.first(where: { $0.id == target }) else { return }
            let line: String
            do {
                line = try await makeLine(instruction)
            } catch {
                // What was typed stays where it is.
                problem = (error as? BrowserDriverRefusal)?.message ?? "That could not be prepared, so nothing was sent."
                return
            }
            let writes = BrowserTerminalSend.writes(line)
            EngineBridge.shared.send("session:write", [target, writes[0]])
            try? await Task.sleep(for: .milliseconds(Int(BrowserTerminalSend.submitGapMilliseconds)))
            EngineBridge.shared.send("session:write", [target, writes[1]])
            instruction = ""
            sent = true
            onSent(session)
        }
    }
}

// MARK: - Shot: copy it, or send it to a session

/// The screenshot (already saved under ~/Pictures/Terminal Deck), Reveal, Copy,
/// and the send row. The session receives the picture's path, the page's
/// address and title (and how many marks were drawn on it).
struct NativeBrowserShotView: View {
    let shot: NativeBrowserShot
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(shot.marks > 0 ? "Marked screenshot" : "Screenshot").font(.headline)
                Spacer()
                Text("\(shot.width) × \(shot.height)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Image(nsImage: shot.image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 190)
                .clipShape(.rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

            VStack(alignment: .leading, spacing: 2) {
                if !shot.title.isEmpty {
                    Text(shot.title).font(.callout.weight(.medium)).lineLimit(1)
                }
                if let url = shot.url {
                    Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text((shot.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(shot.path)
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: shot.path)])
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([shot.image])
                        copied = true
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Copy the picture to the clipboard")
                }
            }

            NativeBrowserSendRow(placeholder: "What should the agent look at?") { instruction in
                BrowserShot.compose(instruction: instruction, path: shot.path, url: shot.url, title: shot.title,
                                    width: shot.width, height: shot.height, marks: shot.marks)
            } onSent: { _ in
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    done()
                }
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}

// MARK: - Downloads

struct NativeBrowserDownloadsButton: View {
    @Bindable var store: NativeBrowserTabs

    var body: some View {
        let downloads = store.downloads
        Button {
            store.downloadsShown.toggle()
        } label: {
            ZStack {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 13))
                if downloads.runningCount > 0 {
                    Circle()
                        .trim(from: 0, to: downloads.overallFraction ?? 0.15)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 22, height: 22)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(.rect)
        }
        .overlay(alignment: .topTrailing) {
            // The web button's badge: how many are moving, "!" when the newest
            // failed, else how many there are.
            if let badge = downloads.badge {
                Text(badge.label)
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3.5)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(badge.tone == "bad" ? Color.red : badge.tone == "busy" ? Color.accentColor : Color.secondary,
                                in: .capsule)
                    .offset(x: 3, y: -2)
                    .allowsHitTesting(false)
            }
        }
        .help("Downloads")
        .accessibilityLabel("Downloads")
        .popover(isPresented: Binding(get: { store.downloadsShown && downloads.badge != nil },
                                      set: { store.downloadsShown = $0 }), arrowEdge: .bottom) {
            NativeBrowserDownloadsList(downloads: downloads)
        }
    }
}

// MARK: - Profile

/// Who you are while you browse: the profile's letter, and the menu to switch.
/// The profiles are the engine's (`browser-profile:list`), so both browsers list
/// the same names; each profile's cookies live in its own website-data store.
struct NativeBrowserProfileButton: View {
    let store: NativeBrowserTabs
    let tab: NativeBrowserTab

    var body: some View {
        let current = store.profile(tab.profile)
        Menu {
            ForEach(store.profiles) { profile in
                Button {
                    store.choose(profile: profile.id, for: tab)
                } label: {
                    if profile.id == (current?.id ?? "") {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
            if !store.profiles.isEmpty { Divider() }
            Button("New Profile…") { askForNewProfile() }
                .disabled(!EngineBridge.shared.isReady)
        } label: {
            Text(current?.badge.isEmpty == false ? current!.badge : "·")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.18), in: .circle)
                .frame(width: 26, height: 26)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(current?.name ?? "Profile")
    }

    private func askForNewProfile() {
        let alert = NSAlert()
        alert.messageText = "New browser profile"
        alert.informativeText = "A profile keeps its own sign-ins and cookies."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue
            Task { await store.createProfile(named: name, for: tab) }
        }
        if let window = tab.webView?.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

struct NativeBrowserDownloadsList: View {
    let downloads: NativeBrowserDownloads

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { downloads.clearFinished() }
                    .disabled(!downloads.items.contains { $0.state != .running })
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if downloads.items.isEmpty {
                Text("Nothing downloaded yet. Files are saved to your Downloads folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(downloads.items) { item in
                            NativeBrowserDownloadRow(item: item, downloads: downloads)
                            Divider().padding(.leading, 50)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            Divider()
            Button("Open Downloads Folder") { downloads.openDownloadsFolder() }
                .buttonStyle(.link)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: 360)
    }
}

struct NativeBrowserDownloadRow: View {
    let item: NativeBrowserDownloads.Item
    let downloads: NativeBrowserDownloads

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if item.state == .running, let fraction = item.fraction {
                    ProgressView(value: fraction).controlSize(.small)
                }
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            switch item.state {
            case .running:
                Button { downloads.cancel(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Stop this download")
            case .finished:
                Button { downloads.reveal(item.id) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            case .failed, .cancelled:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(.rect)
        .onTapGesture(count: 2) { if item.state == .finished { downloads.open(item.id) } }
        .contextMenu {
            if item.state == .finished {
                Button("Open") { downloads.open(item.id) }
                Button("Show in Finder") { downloads.reveal(item.id) }
            }
            if item.state == .running {
                Button("Stop") { downloads.cancel(item.id) }
            }
            if let source = item.source {
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source.absoluteString, forType: .string)
                }
            }
        }
    }

    private var icon: NSImage {
        if item.state == .finished, let file = item.destination {
            return NSWorkspace.shared.icon(forFile: file.path)
        }
        let ext = (item.name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    private var status: String {
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        switch item.state {
        case .running:
            if item.expected > 0 {
                return "\(bytes.string(fromByteCount: item.received)) of \(bytes.string(fromByteCount: item.expected))"
            }
            return item.received > 0 ? bytes.string(fromByteCount: item.received) : "Starting…"
        case .finished:
            return item.expected > 0 ? "\(bytes.string(fromByteCount: item.expected)) — in Downloads" : "In Downloads"
        case .failed(let why):
            return "Failed: \(why)"
        case .cancelled:
            return "Stopped"
        }
    }
}
