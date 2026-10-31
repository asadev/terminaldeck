import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TerminalDeckNativeCore

/// Only safe account/site labels are drawn. Saving/filling stays in the exact
/// native document and gives immediate pending and failure feedback.
struct NativeBrowserSavedLoginBar: View {
    let tab: NativeBrowserTab
    private var usernames: [String] { tab.savedSignInOffer?["usernames"].elements?.compactMap(\.string) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let offer = tab.savedPasswordOffer {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.secondary)
                    Text("Save \(offer.login.username.isEmpty ? "this sign-in" : offer.login.username) for \(offer.login.origin)?")
                        .font(.callout).lineLimit(2)
                    Spacer(minLength: 8)
                    Button("Not now") { tab.answerSavedPassword(keep: false) }
                    Button("Save") { tab.answerSavedPassword(keep: true) }.buttonStyle(.borderedProminent)
                }
            } else if let offer = tab.savedSignInOffer {
                HStack(spacing: 8) {
                    Image(systemName: "key").foregroundStyle(.secondary)
                    Text(offer["autoFilled"].bool == true ? "Saved sign-in filled." : "A saved sign-in is available for this page.")
                        .font(.callout)
                    Spacer(minLength: 8)
                    if usernames.count == 1, let username = usernames.first {
                        Button("Fill \(username.isEmpty ? "saved sign-in" : username)") { tab.fillSavedLogin(username: username) }
                    } else if !usernames.isEmpty {
                        Menu("Fill saved sign-in") {
                            ForEach(usernames, id: \.self) { username in
                                Button(username.isEmpty ? "Saved sign-in" : username) { tab.fillSavedLogin(username: username) }
                            }
                        }
                    }
                }
                if let message = offer["message"].string, !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            if tab.savedLoginPending { ProgressView("Working…").controlSize(.small) }
            if let message = tab.savedLoginMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .disabled(tab.savedLoginPending)
        .padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
    }
}

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
    /// Only capture cards offer Hoot. Flow recordings keep their existing session path.
    var inline = false
    var fixture: NativeRPCValue? = nil
    var feedbackScope = "browser:standalone"
    var originatingSession: String? = nil
    var hootImages: (() async throws -> [Data])? = nil
    var hootSource: () -> NativeRPCValue = { .object([]) }
    var onHootSent: () -> Void = {}
    var makeLine: (String) async throws -> String
    var onSent: (BrowserSessionChoice) -> Void = { _ in }
    /// The card's Cancel, beside Send (cards never close on a click outside them).
    var cancel: (() -> Void)? = nil

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
            if hootImages == nil && fixture == nil {
                Picker("To", selection: $chosen) {
                    Text("Choose a session…").tag("")
                    ForEach(sessions ?? []) { session in DeckRowLabel(session.label, image: DeckRowIcon.session(id: session.id)).tag(session.id) }
                }.disabled((sessions ?? []).isEmpty)
            }
            if inline {
                HStack(spacing: 12) {
                    instructionField.frame(minWidth: 180, maxWidth: .infinity)
                    sendControls.fixedSize(horizontal: true, vertical: false)
                }
                if let line = statusLine { Text(line).font(.caption).foregroundStyle(.secondary) }
            } else {
                instructionField
                sendControls
            }
        }
        .onChange(of: chosen) { _, id in
            sent = false; problem = nil
            if fixture == nil, hootImages != nil, !id.isEmpty { NativeHOOTSIMTargets.shared.remember(id, scope: feedbackScope) }
        }
        .task {
            if let fixture {
                sessions = BrowserSessionChoice.read(fixture["sessions"].foundation)
                chosen = fixture["targetId"].string ?? NativeHOOTSIMFeedback.targetID
                instruction = fixture["note"].string ?? ""
                sending = fixture["sending"].bool ?? false
                problem = fixture["problem"].string
                return // No subscriptions, defaults, engine, or session calls in a render.
            }
            chosen = hootImages == nil ? originatingSession ?? "" : NativeHOOTSIMTargets.shared.target(scope: feedbackScope, originatingSession: originatingSession)
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

    private var instructionField: some View {
            Group {
                if multiline {
                    TextField(placeholder, text: $instruction, axis: .vertical)
                        .lineLimit(2...5)
                } else {
                    TextField(placeholder, text: $instruction)
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(sending)
            .focused($fieldFocused)
            .onSubmit(send)
            .onChange(of: instruction) { sent = false; problem = nil }

    }

    private var sendControls: some View {

            HStack(alignment: .firstTextBaseline) {
                if !inline, let line = statusLine {
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let cancel { NativeCardCancelButton(action: cancel).disabled(sending) }
                if hootImages != nil || fixture != nil {
                    SendTargetButton(targetID: $chosen, sessions: sendSessions,
                        sending: sending, disabled: blocked, reason: notReady, canCopy: fixture == nil,
                        send: send, copy: copyFeedback)
                    .fixedSize()
                } else {
                    Button(sending ? "Sending…" : sent ? "Sent" : action, action: send)
                        .buttonStyle(.borderedProminent).disabled(blocked || sending)
                }
            }
    }

    private var sendSessions: [SendTargetButton.Session] {
        if let fixture {
            return (fixture["sessions"].elements ?? []).compactMap { row in
                guard let id = row["id"].string else { return nil }
                return .init(id: id, name: row["label"].string ?? id, project: row["project"].string ?? "Independent",
                    colour: SIDEBARChrome.dot(row["colour"].string ?? "#8E8E93"))
            }
        }
        return (sessions ?? []).map { .init(id: $0.id, name: $0.label, folder: $0.cwd) }
    }

    private var statusLine: String? {
        if let problem { return problem }
        // Hoot is always a target when the split Send button shows, so the hint is only for the plain session button.
        if let sessions, sessions.isEmpty, hootImages == nil, fixture == nil { return "No sessions are open. Start one, then choose it here." }
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
            if !chosen.isEmpty, chosen != NativeHOOTSIMFeedback.targetID, !list.contains(where: { $0.id == chosen }) {
                chosen = ""
                problem = "That session has closed. Choose another one."
            }
        } catch {
            sessions = []
            problem = "The sessions could not be listed."
        }
    }

    private func copyFeedback() {
        guard let hootImages, !sending else { return }
        Task {
            do {
                _ = try await makeLine(instruction)
                try NativeHOOTSIMFeedback.copy(try await hootImages())
            } catch { problem = error.localizedDescription }
        }
    }

    private func send() {
        guard fixture == nil, !blocked, !sending else { return }
        let target = chosen
        sending = true
        problem = nil
        Task {
            defer { sending = false }
            // The list as it is now: a session that exited since it was chosen is refused.
            await loadSessions()
            guard chosen == target else { return }
            let session = sessions?.first(where: { $0.id == target })
            let toHoot = target == NativeHOOTSIMFeedback.targetID
            guard toHoot ? hootImages != nil : session != nil else { return }
            let line: String
            do {
                line = try await makeLine(instruction)
            } catch {
                // What was typed stays where it is.
                problem = (error as? BrowserDriverRefusal)?.message ?? "That could not be prepared, so nothing was sent."
                return
            }
            if toHoot {
                do {
                    let images = try await hootImages?() ?? []
                    guard chosen == target else { return }
                    var source = hootSource()
                    if let originatingSession {
                        source = source.setting("sessionId", .string(originatingSession))
                        if let row = sessions?.first(where: { $0.id == originatingSession }), !row.cwd.isEmpty {
                            source = source.setting("folder", .string(row.cwd))
                            let projects = SIDEBARProjectStore.shared.projects
                            let projectID = PROJProjects.resolve(projectID: nil, folder: row.cwd, projects: projects)
                            if projectID != PROJProjects.independentID { source = source.setting("projectId", .string(projectID)) }
                        }
                    }
                    try await NativeHOOTSIMFeedback.send(line, images: images, source: source)
                    instruction = ""; sent = true; onHootSent()
                    NativeHOOTSIMTargets.shared.sentToHoot()
                } catch { problem = error.localizedDescription }
                return
            }
            guard let session else { return }
            do {
                let source = hootSource(), paths = source["path"].string.map { [$0] } ?? []
                try await NativeCapturedFeedback.send(sessionID: target, text: line, chatText: instruction, paths: paths, source: source)
            } catch { problem = error.localizedDescription; return }
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
    var tabID = ""
    let done: () -> Void
    @State private var copied = false
    /// Crop (the shared crop view): the cropped copy, saved beside the original, replaces it here.
    @State private var cropped: NativeBrowserShot?
    @State private var applied = NativeShotCrop.full
    @State private var cropping = false
    @State private var crop = NativeShotCrop.full
    @State private var cropProblem = ""

    private var current: NativeBrowserShot { cropped ?? shot }

    var body: some View {
        let current = current
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(current.marks > 0 ? "Marked screenshot" : "Screenshot").font(.headline)
                Spacer()
                Text(cropping ? NativeShotCrop.sizeLabel(crop, width: shot.width, height: shot.height)
                              : "\(current.width) × \(current.height)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            NativeShotCropView(image: cropping ? shot.image : current.image, crop: $crop, editing: cropping)
                .frame(maxWidth: .infinity, maxHeight: cropping ? 320 : 190)
                .clipShape(.rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

            VStack(alignment: .leading, spacing: 2) {
                if !current.title.isEmpty {
                    Text(current.title).font(.callout.weight(.medium)).lineLimit(1)
                }
                if let url = current.url {
                    Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text((current.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(current.path)
                    if !cropping {
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: current.path)])
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([current.image])
                            copied = true
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Copy the picture to the clipboard")
                    }
                    Spacer(minLength: 4)
                    NativeShotCropButtons(cropping: cropping, start: {
                        crop = applied; cropProblem = ""; cropping = true
                    }, reset: {
                        crop = NativeShotCrop.full; applied = NativeShotCrop.full; cropped = nil; copied = false
                    }, done: applyCrop)
                    .font(.caption)
                }
                if !cropProblem.isEmpty {
                    Text(cropProblem).font(.caption).foregroundStyle(.red)
                }
            }

            NativeBrowserSendRow(placeholder: "What should change?", feedbackScope: "browser:" + tabID,
                originatingSession: NativeBRBindings.shared.view.holder(of: tabID)?.session.sessionId, hootImages: {
                guard let png = NSBitmapImageRep(cgImage: current.cgImage).representation(using: .png, properties: [:]) else {
                    throw BrowserDriverRefusal("The picture could not be prepared. Nothing was sent.")
                }
                return [png]
            }, hootSource: {
                .object([.init("kind", .string("browser")), .init("title", .string(current.title)),
                    .init("url", .string(current.url?.absoluteString ?? "")), .init("path", .string(current.path)),
                    .init("noteCount", .number(1))])
            }, onHootSent: done, makeLine: { instruction in
                let current = self.current
                return BrowserShot.compose(instruction: instruction, path: current.path, url: current.url, title: current.title,
                                           width: current.width, height: current.height, marks: current.marks)
            }, onSent: { _ in
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    done()
                }
            }, cancel: {
                if cropping { cropping = false; crop = applied } else { done() }
            })
        }
        .padding(14)
        .frame(width: 380)
        .nativeCardStaysOpen { if cropping { cropping = false; crop = applied } else { done() } }
    }

    /// Done: the area inside the rectangle, saved beside the original, is what Copy and Send use.
    private func applyCrop() {
        if NativeShotCrop.isFull(crop) {
            applied = NativeShotCrop.full; cropped = nil; cropping = false; return
        }
        do {
            guard let cut = NativeShotCrop.cropped(shot.cgImage, to: crop) else { throw CocoaError(.fileWriteUnknown) }
            let path = try NativeShotCrop.save(cut, beside: shot.path)
            cropped = NativeBrowserShot(image: NativeShotCrop.image(cut), cgImage: cut, url: shot.url, title: shot.title,
                                        path: path, marks: shot.marks)
            applied = crop; cropping = false; copied = false; cropProblem = ""
        } catch {
            cropProblem = "The cropped screenshot could not be saved: \(error.localizedDescription)"
        }
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
                        .stroke(NativeSessionChrome.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
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
                    .background(badge.tone == "bad" ? Color.red : badge.tone == "busy" ? NativeSessionChrome.accent : Color.secondary,
                                in: .capsule)
                    .offset(x: 3, y: -2)
                    .allowsHitTesting(false)
            }
        }
        .help("Downloads")
        .foregroundStyle(.secondary)
        .accessibilityLabel("Downloads")
        .popover(isPresented: Binding(get: { store.downloadsShown },
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
            Divider()
            NativeBrowserMenuActions(store: store, tab: tab)
        } label: {
            Text(current?.badge.isEmpty == false ? current!.badge : "·")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.08), in: .circle)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(current.map { "Profile — \($0.name)" } ?? "Profile")
        .accessibilityLabel("Profile")
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
        } else if NativeFront.personActing {
            finish(alert.runModal()) // front-ok: the person's own "New profile" press, no window to sheet over
        }
    }
}

struct NativeBrowserDownloadsList: View {
    let downloads: any NativeCompositionBrowserDownloadsPresentation

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
            if !downloads.message.isEmpty {
                Text(downloads.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(14)
            }
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
    let downloads: any NativeCompositionBrowserDownloadsPresentation
    private var localFile: Bool { downloads.backendRow(item.id)?.onMachine.isEmpty ?? true }

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
                if localFile {
                    Button { downloads.reveal(item.id) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                }
            case .failed, .cancelled:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(.rect)
        .onTapGesture(count: 2) { if item.state == .finished && localFile { downloads.open(item.id) } }
        .contextMenu {
            if item.state == .finished && localFile {
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
        if let row = downloads.backendRow(item.id) {
            if row.state == .delivering { return row.onMachineName.isEmpty ? "Delivering…" : "Delivering to \(row.onMachineName)…" }
            if !row.onMachine.isEmpty { return row.onMachineName.isEmpty ? "Saved on another machine" : "Saved on \(row.onMachineName)" }
            if !row.message.isEmpty { return row.message }
        }
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
