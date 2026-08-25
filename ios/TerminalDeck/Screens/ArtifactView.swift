/**
 * An artifact, opened — the page running, the photograph drawn, the file read.
 *
 * > *"The artifact page should be able to drive the artifacts actually — to show
 * > the visual artifacts, files and things. This application should be
 * > supporting to view photos inside, or whatever is there, if we want to have
 * > something — files or stuff. Artifacts like prototypes: in artifacts it will
 * > be most probably for prototypes, whatever Claude will make. All of these
 * > prototypes will be saved there and they can be reviewed and they can be
 * > used."*
 *
 * The Artifacts panel was a list of filenames with one button on each row that
 * said *Open in Files* and, when pressed, answered *"Opening PLAN.md."* while
 * nothing opened. There was no screen for it to open. This is that screen, and
 * the point of it is the verb: **review** and **use**, not audit a path list.
 *
 * ## Four things happen here, and which one is decided by the host
 *
 * The panel puts the kind in the row — see the id grammar in
 * `src/main/remote/panels/artifacts.ts` — so this screen knows what it is
 * opening *before* it opens anything. That matters twice: a viewer that had to
 * read the file to find out would fetch forty megabytes of PNG to discover it
 * was a PNG, and a phone that guessed from the extension would be contradicting
 * the only side that can actually see the disk.
 *
 *  - **A prototype** (`page`) is **served and opened as a page**. See below.
 *  - **A photograph** (`image`) is fetched as real bytes and drawn.
 *  - **A PDF, a video, a recording** (`media`) go to the same browser view,
 *    which renders all three natively and seeks properly, because the server on
 *    the other end answers byte ranges.
 *  - **Text** (`text`) is read through `files.read`, a window at a time, in the
 *    **terminal's own colours** rather than in colours invented for this screen.
 *  - Anything else is named, measured and left alone. `other` is a `.zip` or a
 *    `.sqlite`; `gone` is a file an agent wrote and deleted two turns later.
 *    Neither gets a frame that cannot load.
 *
 * ## What stopped arriving here
 *
 * > *"an artifact is still showing the MD files, which is — multiple times I
 * > have discussed about it. Artifact should not show the MD files. It should
 * > be only for purely the prototypes."*
 *
 * The panel now sends `page`, `image` and `media` and nothing else. That rule
 * lives on the **desktop**, in `src/main/remote/panels/artifacts.ts`, so that
 * one side decides what an artifact is and this screen cannot drift from it;
 * markdown is read in **Files**, which is the file browser and this is not.
 *
 * The `text` and `other` branches below are kept all the same, and they are not
 * dead code. A `page` showing its own source runs the whole `text` reader — the
 * *Read more* bar, *Read again*, *Copy what is shown* — and this phone pairs
 * with whatever host it is pointed at, including one built before that rule.
 * The one thing now unreachable from a current host is the markdown/prose
 * toggle, and it stays for the second of those two reasons.
 *
 * ## How a prototype actually runs, and where
 *
 * **On the machine.** Pressing *Run it* asks the panel for a `preview`; the host
 * starts a bounded static HTTP server rooted at the project
 * (`src/main/artifact-preview.ts` says why an HTTP server and not a bigger file
 * frame), and answers with its port and its secret in the row's own id. This
 * screen then opens a `PortTunnel` — the same tunnel that already carries a dev
 * server to this phone — and points {@link LocalhostBrowser} at
 * `/<secret>/~/<token>`, which the host redirects to the file's real URL.
 *
 * The redirect is not decoration. After it, the page's own address **is** its
 * path inside the project, so `<img src="logo.png">`, `<link href="app.css">`,
 * a `fetch('./data.json')` and a module import all resolve exactly as they do on
 * the machine. A page handed over as a string would have none of that, which is
 * the difference between running a prototype and looking at its markup with the
 * angle brackets hidden.
 *
 * Nothing here needs Electron. The panel, the preview server and the tunnel are
 * all plain Node, so a headless host on a rented Linux box does this too — which
 * is the case that matters most, because that is the machine nobody is sitting
 * in front of.
 *
 * ## Why a photograph is fetched and not sent
 *
 * `files.read` answers with **text**. It decides binary from the bytes — a NUL
 * in the block it read — and sends `binary: true` with an empty string rather
 * than mojibake, which is the right answer for a frame that carries a string and
 * the reason there was no way to look at a screenshot from this app at all. The
 * bytes come over the tunnel instead, as an ordinary HTTP response with a real
 * `Content-Type`, through the loopback address ATS is already excepted for in
 * `Support/Info.plist`.
 *
 * A frame that carried base64 would also work and would be less machinery; it
 * is written up in this lane's report as `files.blob`. It is not what is needed
 * here, because the same server has to exist anyway for the prototype case and
 * one mechanism that serves both beats two that each serve half.
 *
 * ## What is not offered when it cannot work
 *
 * A machine that does not open its ports to a device — `canBrowseLocalhost`
 * false, which is what the public demo box advertises — gets no *Run it* and no
 * image fetch, and a sentence saying which machine cannot do it rather than a
 * button that fails. The same rule the rest of this app keeps: never draw a
 * control that cannot act, and never a preview that cannot load.
 */

import SwiftUI
import UIKit

// MARK: - What the row said it is

/// The six words the panel sorts a file into. A port of `ArtifactKindName`.
enum ArtifactKind: String, Equatable, Hashable {
    case page
    case image
    case media
    case text
    case other
    case gone
}

/**
 * Where this project is being served, when it is.
 *
 * The secret is half of it and is not optional: the port is guessable by
 * anything else running on that machine and the secret is not, so a request
 * without it gets the same 404 as a file that is not there. See the module
 * header of `src/main/artifact-preview.ts`.
 */
struct ArtifactPreviewAddress: Equatable, Hashable {
    let port: Int
    let secret: String

    /**
     * The `<port>.<secret>` field of a row id, or nil for `-`.
     *
     * Split at the **first** dot, because a secret is `base64url` and may
     * contain neither a dot nor a space — a port never does — so the first dot
     * is unambiguously the separator. A field that does not parse is treated as
     * nothing being served rather than as a bad row: the rest of the row is
     * still a file worth opening.
     */
    init?(field: String) {
        guard field != "-", let dot = field.firstIndex(of: ".") else { return nil }
        guard let number = Int(field[field.startIndex..<dot]), (1...65535).contains(number) else {
            return nil
        }
        let rest = String(field[field.index(after: dot)...])
        guard !rest.isEmpty, rest.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        port = number
        secret = rest
    }
}

/**
 * A row's machine-readable half.
 *
 * `<token> <kind> <bytes> <preview> <absolute path>`, path last and the only
 * field allowed to contain a space — which is what makes the split unambiguous
 * on a filesystem where a filename may hold anything but `/` and NUL. The panel
 * writes it; this reads it; `src/main/remote/panels/artifacts.ts` is where the
 * grammar and the reasons for it live.
 *
 * A failable initialiser rather than a lenient one **on purpose**: a row this
 * build cannot parse is a row from a host older or newer than this app, and the
 * honest thing is for it not to be tappable at all. `PanelView` asks for one of
 * these before it draws a chevron, so a host that has not been updated draws the
 * list it always drew instead of a control that leads to a screen with nothing
 * on it.
 */
struct ArtifactRef: Equatable, Hashable {
    /// What `panel.act` calls this row by. Bounded by the panel to fit
    /// `MAX_PANEL_WORD`, because an id over it closes the socket.
    let token: String
    let kind: ArtifactKind
    /// Size on disk, or nil where the host could not stat the file.
    let bytes: Int?
    let preview: ArtifactPreviewAddress?
    /// The machine's own spelling, built there with its own separators.
    let path: String

    init?(id: String?) {
        guard let id, !id.isEmpty else { return nil }
        let parts = id.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count == 5,
              let kind = ArtifactKind(rawValue: String(parts[1])),
              let size = Int(parts[2]) else { return nil }
        let where_ = String(parts[4])
        guard !where_.isEmpty else { return nil }
        token = String(parts[0])
        self.kind = kind
        // `-1` is the host saying it could not stat the file, which is a
        // different fact from a zero-byte file and must not be drawn as one.
        bytes = size < 0 ? nil : size
        preview = ArtifactPreviewAddress(field: String(parts[3]))
        path = where_
    }

    /// The folder it sits in, on the machine. Both separators, because the
    /// machine may be Windows and this string is its spelling rather than ours.
    var folder: String {
        guard let cut = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return path }
        let up = String(path[path.startIndex..<cut])
        return up.isEmpty ? String(path[path.startIndex...cut]) : up
    }

    var name: String {
        guard let cut = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return path }
        return String(path[path.index(after: cut)...])
    }

    /// The lower-cased extension, or empty. Used for the one word under the
    /// title and never for a decision — the host decided the kind.
    var suffix: String {
        let name = self.name
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// Everything but a path allowed through unescaped. `alphanumerics` alone
    /// would encode `.`, `-` and `_`, which is legal and makes an unreadable URL
    /// out of every ordinary filename.
    private static let pathSafe: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /**
     * The URL inside the preview server that answers with this file.
     *
     * `/<secret>/~/<token>` — the host answers `302` to the file's real path, so
     * the page that finally loads is at its own address and every relative URL
     * in it resolves from there. Spelling the relative path here instead would
     * mean this phone doing path arithmetic with a root and an absolute path it
     * did not produce, on a separator it cannot see.
     */
    func previewPath(_ address: ArtifactPreviewAddress) -> String {
        let escaped = token.addingPercentEncoding(withAllowedCharacters: Self.pathSafe) ?? token
        return "/\(address.secret)/~/\(escaped)"
    }
}

// MARK: - The screen

struct ArtifactView: View {
    let model: DeckModel
    /// What the panel said this row is. Held rather than re-read from the model,
    /// so a redraw of the list underneath cannot change what this screen is
    /// about — only the preview address is taken from later answers.
    let opened: ArtifactRef
    /// The row's own title, which is the project-relative path for anything in a
    /// sub-folder. The heading; `opened.path` is the fact underneath it.
    let title: String
    /// The folder the panel is answering for. Sent back on `panel.act` so the
    /// host serves the same project the list came from.
    let project: String?
    /// The terminal's colours, which is what a file is drawn in here. Injected
    /// the way every other screen in this app takes it.
    var themes: TerminalThemeStore = .shared

    init(model: DeckModel,
         opened: ArtifactRef,
         title: String,
         project: String? = nil,
         themes: TerminalThemeStore = .shared) {
        self.model = model
        self.opened = opened
        self.title = title
        self.project = project
        self.themes = themes
        _address = State(initialValue: opened.preview)
    }

    @Environment(\.colorScheme) private var appearance

    // MARK: Reading a text file

    /// The windows read so far, in order, joined for display. Kept as pieces
    /// because that is what arrives — see `absorb`, which refuses one that does
    /// not continue exactly where the last ended rather than splicing a gap into
    /// the middle of somebody's file.
    @State private var windows: [String] = []
    @State private var readTo = 0
    @State private var truncated = false
    @State private var binary = false
    /// Whether anything at all has come back. Tells an empty file — a real and
    /// common answer — from a read still in flight.
    @State private var answered = false
    @State private var waiting = false
    @State private var silent = false
    @State private var attempt = 0
    /// Markdown as prose rather than as source. Off for everything else.
    @State private var asProse = true

    // MARK: Serving

    /// Where this project is being served. Seeded from the row that was tapped —
    /// a second artifact in a project already serving needs no round trip at all
    /// — and replaced by every later answer that names one.
    @State private var address: ArtifactPreviewAddress?
    /// A `preview` action is on the wire.
    @State private var asking = false
    /// Bumped per ask, so the deadline below restarts for each one.
    @State private var askAttempt = 0
    @State private var tunnel: PortTunnel?
    /// What went wrong, in the machine's words where there are any. Never a
    /// spinner that runs for ever: this screen has three round trips in it and
    /// each of them has a sentence for the case where nothing comes back.
    @State private var problem: String?
    /// The browser view, pushed. Non-nil is also what stops the tunnel being
    /// torn down underneath it — see `.onDisappear`.
    @State private var page: PagePush?
    /// The Files screen, pushed at this artifact's own folder.
    @State private var folderShown = false
    /// A page's markup, rather than the page. See the menu and `content`.
    @State private var sourceShown = false
    /// What was asked for before the tunnel came up, so the answer knows what to
    /// do with it. Cleared the moment it is spent.
    @State private var pending: Errand?

    // MARK: Drawing a picture

    @State private var picture: UIImage?
    @State private var fetching = false
    /// Actual size rather than fit-to-width. A double tap, which is what every
    /// photo viewer on this platform does.
    @State private var actualSize = false

    /**
     * How big a picture is fetched without being asked about first.
     *
     * Four megabytes is a generous screenshot and a small photograph. Past it
     * the size is put on a button — *"Show it · 41 MB"* — because the bytes come
     * over a relay to a phone that may be on a train, and a screen that starts a
     * forty-megabyte download on arrival is one nobody can decline.
     */
    private let fetchWithoutAsking = 4 * 1024 * 1024

    /// Where reading a text file stops. One `Text` holding a megabyte of
    /// monospaced glyphs is already close to what a phone will lay out in a
    /// frame; a *Read more* past it would be a button whose only effect is a
    /// beachball. Said out loud rather than by the button vanishing.
    private let ceiling = 1_000_000

    private var text: String { windows.joined() }

    /// The scheme actually painted, for the appearance this view is in. The same
    /// call `TerminalScreen` makes, so a file read here and a session read next
    /// to it are the same two colours.
    private var scheme: TerminalScheme {
        TerminalPalette.resolved(themes.selected, style: appearance == .light ? .light : .dark)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                content
            }
        }
        .navigationTitle(opened.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { menu } }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationDestination(isPresented: $folderShown) {
            FilesView(model: model, start: opened.folder)
        }
        .navigationDestination(item: $page) { push in
            // `dismiss` is that screen's *Done*, and here it means come back to
            // the artifact rather than leave the stack — the tunnel is still
            // wanted, and a second press of Run it must not have to open it
            // again.
            LocalhostBrowser(model: model, tunnel: push.tunnel, path: push.path) { page = nil }
        }
        /*
         * **Tell the tab bar a page is open, so it gets out of the way.**
         *
         * A prototype opens in the same `LocalhostBrowser` the Browser tab uses,
         * and that screen has a bottom toolbar — but it is pushed on the *Menu*
         * stack here, whose surface is otherwise always `.settings`/`.machines`,
         * so the floating pill was drawn straight over its controls.
         * `.toolbar(.hidden, for: .tabBar)` on a pushed screen has no effect on
         * iOS 26 (recorded in `DeckChrome`'s header), so the flag on the model is
         * the only lever, and `DeckModel.settingsSurface` reads it.
         *
         * Cleared on the way out as well as on the way back, because the screen
         * can be left with the page still on top of it.
         */
        .onChange(of: page) { _, open in model.localhostPageIsOpen = open != nil }
        .onAppear(perform: arrive)
        .onDisappear {
            // Only when the browser is not standing on top of it. Pushing a
            // child calls this on some iOS versions, and tearing the tunnel down
            // there would blank the page the person just opened.
            if page == nil {
                release()
                model.localhostPageIsOpen = false
            }
        }
        .onChange(of: model.fileText) { _, answer in absorb(answer) }
        .onChange(of: model.panelData(.artifacts)) { _, answer in tookPreview(answer) }
        .onChange(of: tunnel?.phase) { _, phase in tunnelMoved(phase) }
        .task(id: attempt) {
            silent = false
            guard opened.kind == .text, !answered else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            silent = !answered
        }
        .task(id: askAttempt) {
            guard asking else { return }
            // The host re-scans its own ports and makes a real TCP connection
            // before it answers, so this is deliberately longer than a panel
            // read — and it still has to end, because a spinner with no deadline
            // is the defect this whole round is about.
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, asking else { return }
            asking = false
            problem = "The machine did not answer. It may not be able to serve this folder."
        }
    }

    // MARK: - Arriving

    private func arrive() {
        switch opened.kind {
        case .text:
            if let already = model.fileText, already.path == opened.path, already.at == 0 {
                absorb(already)
            } else {
                startReading()
            }
        case .image:
            // Small enough that asking would be ceremony. Anything bigger waits
            // for a press that says what it costs — and a machine that cannot
            // serve one is a card explaining that rather than an error raised by
            // a fetch nobody asked for.
            if model.canBrowseLocalhost, (opened.bytes ?? 0) <= fetchWithoutAsking { show() }
        case .page, .media, .other, .gone:
            break
        }
    }

    /// Everything this screen holds on the machine, given back. A tunnel left
    /// open is a listener on the phone and a stream on the host for a page
    /// nobody is looking at.
    private func release() {
        if let tunnel {
            model.closeLocalhost(port: tunnel.port)
        }
        tunnel = nil
        pending = nil
    }

    // MARK: - Reading a text file

    private func startReading() {
        windows = []
        readTo = 0
        truncated = false
        binary = false
        answered = false
        waiting = true
        silent = false
        attempt += 1
        model.readFile(opened.path, at: 0)
    }

    private func readMore() {
        guard truncated, readTo < ceiling, !waiting else { return }
        waiting = true
        attempt += 1
        model.readFile(opened.path, at: readTo)
    }

    /**
     * Take an answer, or refuse it.
     *
     * The **path**, because this screen can be pushed twice in a row and a late
     * answer for the file behind must not be drawn as this one. The **offset**,
     * because only a window beginning exactly where the last ended is a
     * continuation. And **binary**, which ends the read: there is nothing to
     * continue and nothing more to ask for.
     */
    private func absorb(_ answer: FileText?) {
        guard let answer, answer.path == opened.path else { return }
        waiting = false

        if answer.binary {
            windows = []
            readTo = 0
            truncated = false
            binary = true
            answered = true
            return
        }
        if answer.at == 0 {
            windows = [answer.text]
            readTo = answer.text.utf8.count
        } else if answer.at == readTo {
            windows.append(answer.text)
            readTo += answer.text.utf8.count
        } else {
            // A window from an offset this screen is not standing at. Dropped
            // rather than appended: a gap drawn as continuous text reads as
            // corruption in somebody's file.
            return
        }
        binary = false
        truncated = answer.truncated
        answered = true
    }

    // MARK: - Serving, and what to do once it is up

    /// What the round trip was started for. A tunnel comes up long after the
    /// press, and by then the press is gone.
    private enum Errand: Equatable {
        case openPage
        case fetchImage
    }

    private func run() { begin(.openPage) }
    private func show() { begin(.fetchImage) }

    /**
     * Ask the machine to serve this project, or use the server already up.
     *
     * Three gates, and each is a real state rather than defensiveness: a machine
     * that will not answer panels cannot be asked; one that does not open its
     * ports to a device cannot be tunnelled to; and a file that is not on disk
     * has nothing to serve. All three are checked before anything is drawn as
     * pressable, so this is the backstop rather than the message.
     */
    private func begin(_ errand: Errand) {
        problem = nil
        guard opened.kind != .gone else { return }
        guard model.canBrowseLocalhost else {
            problem = "\(model.theMachine) does not open its ports to a device, so it cannot show this here."
            return
        }
        pending = errand
        if let address {
            openTunnel(to: address)
            return
        }
        guard model.canReadPanels else {
            problem = "\(model.theMachine) is not answering panels, so it cannot be asked to serve this."
            return
        }
        asking = true
        askAttempt += 1
        model.actOnPanel(.artifacts,
                         action: ArtifactView.previewAction,
                         path: project,
                         id: opened.token)
    }

    /// The verb the panel answers and deliberately does not advertise on a row —
    /// see `src/main/remote/panels/artifacts.ts`. A generic button would start a
    /// server and have nowhere to show it.
    static let previewAction = "preview"

    /**
     * The panel answered. Find this file's row in it and take the address.
     *
     * Matched on the **token** rather than on the row's position, because the
     * host rescans on every act and a file written in between would move the
     * list under a remembered index. That is the whole reason a row carries a
     * name of its own.
     */
    private func tookPreview(_ answer: PanelData?) {
        guard let answer else { return }
        let mine = answer.rows
            .compactMap { ArtifactRef(id: $0.key) }
            .first { $0.token == opened.token }
        if let found = mine?.preview {
            address = found
            if asking {
                asking = false
                openTunnel(to: found)
            }
            return
        }
        guard asking else { return }
        asking = false
        // The host says why in its own words — a folder it could not serve, a
        // file that has gone. Its sentence beats one invented here.
        problem = answer.notice ?? "The machine did not start a server for this project."
    }

    private func openTunnel(to address: ArtifactPreviewAddress) {
        if let held = tunnel, held.port == address.port {
            spend(held)
            return
        }
        guard let opened = model.openLocalhost(port: address.port) else {
            problem = model.lastError ?? "This phone could not open a tunnel to that port."
            pending = nil
            return
        }
        tunnel = opened
        spend(opened)
    }

    private func tunnelMoved(_ phase: PortTunnel.Phase?) {
        guard let phase else { return }
        switch phase {
        case .live:
            if let tunnel { spend(tunnel) }
        case let .ended(detail):
            problem = detail
            pending = nil
        case .opening:
            break
        }
    }

    /// Do the thing the press was for, once — and only once the tunnel is
    /// actually serving. `PortTunnel` binds nothing until the machine has
    /// answered, so `.live` is the first moment a URL means anything.
    private func spend(_ tunnel: PortTunnel) {
        guard let errand = pending, case let .live(base) = tunnel.phase else { return }
        pending = nil
        guard let address else { return }
        let path = opened.previewPath(address)
        switch errand {
        case .openPage:
            page = PagePush(tunnel: tunnel, path: path)
        case .fetchImage:
            fetch(URL(string: path, relativeTo: base)?.absoluteURL)
        }
    }

    /// What a pushed browser needs, as one identity so `navigationDestination`
    /// can drive it. The path is part of the identity: opening the same tunnel
    /// at a different file is a different destination.
    private struct PagePush: Identifiable, Hashable {
        let tunnel: PortTunnel
        let path: String

        var id: String { "\(tunnel.id)\(path)" }

        static func == (lhs: PagePush, rhs: PagePush) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    // MARK: - Drawing a picture

    /**
     * The bytes, over the tunnel, as an ordinary HTTP response.
     *
     * Ephemeral rather than the shared session: a prototype is a thing being
     * iterated on, and a cached image is somebody pressing *Read again* and
     * seeing the version from before they saved. The host says `no-store` too;
     * both, because a cache that is only refused at one end is not refused.
     */
    private func fetch(_ url: URL?) {
        guard let url else {
            problem = "That file's address could not be built."
            return
        }
        fetching = true
        problem = nil
        Task { @MainActor in
            defer { fetching = false }
            do {
                let session = URLSession(configuration: .ephemeral)
                let (data, response) = try await session.data(from: url)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else {
                    problem = "The machine answered \(code) for this file."
                    return
                }
                guard let image = UIImage(data: data) else {
                    // A `.svg` is an image the panel is right to call one and
                    // `UIImage` cannot decode. The browser view can, and it is
                    // one press away on the bar below.
                    problem = "This phone cannot draw that image. Open it in the browser view."
                    return
                }
                picture = image
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    // MARK: - Chrome

    /// The path in full, above everything, so it stays put while the file moves
    /// under it. `FilesView` and `FileTextView` put the same line in the same
    /// place, at the same metrics.
    private var header: some View {
        VStack(spacing: 0) {
            Text(opened.path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.faint)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .accessibilityIdentifier("artifact.path")
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    private var menu: some View {
        Menu {
            Button {
                UIPasteboard.general.string = opened.path
            } label: {
                Label("Copy path", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("artifact.copypath")

            if readsAFile, !text.isEmpty {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("Copy what is shown", systemImage: "doc.on.clipboard")
                }
                .accessibilityIdentifier("artifact.copytext")
            }

            if isMarkdown {
                Button {
                    asProse.toggle()
                } label: {
                    Label(asProse ? "Show the source" : "Read it as prose",
                          systemImage: asProse ? "chevron.left.forwardslash.chevron.right" : "text.alignleft")
                }
                .accessibilityIdentifier("artifact.prose")
            }

            if model.canReadFiles {
                /*
                 * A `Button` and a destination, not a `NavigationLink`.
                 *
                 * SwiftUI turns a `Menu`'s contents into a UIKit menu, whose
                 * items are actions — a `NavigationLink` placed in one draws its
                 * label and pushes nothing. That is a control that cannot act,
                 * on the screen whose whole subject is one of those.
                 */
                Button {
                    folderShown = true
                } label: {
                    Label("Show the folder", systemImage: "folder")
                }
                .accessibilityIdentifier("artifact.folder")
            }

            if opened.kind == .page {
                Button {
                    if !sourceShown { startReading() }
                    sourceShown.toggle()
                } label: {
                    Label(sourceShown ? "Back to the page" : "Show the source",
                          systemImage: sourceShown ? "safari" : "chevron.left.forwardslash.chevron.right")
                }
                .accessibilityIdentifier("artifact.source.menu")
            }

            if readsAFile {
                Button {
                    startReading()
                } label: {
                    Label("Read again", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("artifact.reload")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("artifact.more")
    }

    private var isMarkdown: Bool {
        opened.kind == .text && (opened.suffix == "md" || opened.suffix == "markdown")
    }

    /**
     * Whether what is on screen is a file being read a window at a time.
     *
     * A page showing its source is doing exactly what a text file does — it has
     * the same *Read more* bar, the same *Read again*, the same *Copy what is
     * shown* — and keying those off `kind == .text` left a 900 KB `index.html`
     * stopping silently at the first window with nothing saying so.
     */
    private var readsAFile: Bool {
        opened.kind == .text || (opened.kind == .page && sourceShown)
    }

    // MARK: - What is on screen

    @ViewBuilder
    private var content: some View {
        switch opened.kind {
        case .gone:
            absent
        case .other:
            opaque
        case .page:
            // The markup, when it was asked for. A prototype's source is worth
            // reading and is never what somebody came here for first, which is
            // why it is a press and not the screen.
            if sourceShown { reading } else { runnable }
        case .media:
            runnable
        case .image:
            photograph
        case .text:
            reading
        }
    }

    // MARK: The prototype

    /**
     * A prototype, and the one control that runs it.
     *
     * The card says what will happen before it happens — which machine serves
     * it, and that the page is the real one rather than a picture of it —
     * because *Run it* on a phone pointed at a Linux box in another country is
     * not a self-evident act.
     */
    private var runnable: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                card {
                    row(icon: opened.kind == .page ? "safari" : "play.rectangle",
                        title: opened.kind == .page ? "A page" : "A \(mediaWord)",
                        detail: facts,
                        note: opened.kind == .page
                            ? "Run it and \(model.theMachine) serves this project on a port of its own. "
                                + "The page opens here on that port, so its stylesheet, its script and "
                                + "every relative link work exactly as they do over there."
                            : "\(model.theMachine) serves it and the browser view plays it. Seeking works: "
                                + "the server answers byte ranges.")
                }

                if let problem {
                    failure(problem)
                }

                if model.canBrowseLocalhost {
                    Button {
                        run()
                    } label: {
                        HStack(spacing: 8) {
                            if asking || pending != nil {
                                ProgressView().controlSize(.small)
                                Text(asking ? "Asking \(model.theMachine)…" : "Opening the tunnel…")
                            } else {
                                Image(systemName: "play.fill")
                                Text(opened.kind == .page ? "Run it" : "Play it")
                            }
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(asking || pending != nil)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("artifact.run")
                } else {
                    card {
                        noteRow("\(model.theMachine) does not open its ports to a device, so a page "
                                + "from it cannot be opened here.")
                    }
                }

                if opened.kind == .page {
                    Button("Show the source") { showSource() }
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 20)
                        .accessibilityIdentifier("artifact.source")
                }

                TabBarClearance()
            }
            .padding(.top, 16)
        }
    }

    private var mediaWord: String {
        switch opened.suffix {
        case "pdf": return "PDF"
        case "mp3", "m4a", "wav", "aac", "flac", "ogg": return "recording"
        default: return "video"
        }
    }

    private func showSource() {
        startReading()
        sourceShown = true
    }

    // MARK: The photograph

    @ViewBuilder
    private var photograph: some View {
        if let picture {
            /*
             * Two axes, and a double tap between fit-to-width and one-to-one.
             *
             * A pinch gesture would be the third thing on this screen listening
             * for a touch, over a scroll view that already owns two; the double
             * tap is what every photo viewer on this platform does and it is one
             * piece of state rather than a transform to maintain.
             */
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: picture)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: actualSize ? picture.size.width : nil)
                    .frame(maxWidth: actualSize ? nil : .infinity)
                    .accessibilityLabel("\(opened.name), \(Int(picture.size.width)) by \(Int(picture.size.height))")
                    .accessibilityIdentifier("artifact.image")
            }
            .scrollBounceBehavior(.basedOnSize)
            .onTapGesture(count: 2) { actualSize.toggle() }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    card {
                        row(icon: "photo",
                            title: "A picture",
                            detail: facts,
                            note: "It comes over the connection from \(model.theMachine) as real bytes. "
                                + "The frame that carries a file to this phone carries text, so this is "
                                + "the only honest way to look at one.")
                    }
                    if let problem { failure(problem) }
                    if model.canBrowseLocalhost {
                        Button {
                            show()
                        } label: {
                            HStack(spacing: 8) {
                                if fetching || asking || pending != nil {
                                    ProgressView().controlSize(.small)
                                    Text("Fetching…")
                                } else {
                                    Image(systemName: "arrow.down.circle")
                                    Text(opened.bytes.map { "Show it · \(byteSize($0))" } ?? "Show it")
                                }
                            }
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(fetching || asking || pending != nil)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("artifact.fetch")
                    } else {
                        card {
                            noteRow("\(model.theMachine) does not open its ports to a device, so its "
                                    + "pictures cannot be fetched here.")
                        }
                    }
                    TabBarClearance()
                }
                .padding(.top, 16)
            }
        }
    }

    // MARK: The file

    @ViewBuilder
    private var reading: some View {
        if binary {
            notText
        } else if answered && text.isEmpty {
            card { noteRow("This file is empty.") }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .frame(maxHeight: .infinity, alignment: .top)
                .accessibilityIdentifier("artifact.empty")
        } else if !windows.isEmpty {
            fileBody
        } else if silent {
            noAnswer
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /**
     * The file, on the terminal's paper in the terminal's ink.
     *
     * Not `Theme.primary` on `Theme.surface`, which is what the plain file
     * viewer uses and what this screen would have invented for itself. A file on
     * this phone is read next to a session showing the same project, and two
     * greys eight levels apart across one navigation stack is the seam a person
     * notices first. `TerminalPalette.resolved` is the same call `TerminalScreen`
     * makes, so choosing Nord in the picker moves both.
     *
     * `fixedSize(horizontal: true)` is the line that makes it a file viewer
     * rather than a paragraph: code has columns and they carry meaning, and a
     * 400-character line folded into thirty phone-width rows has had that
     * structure destroyed rather than presented.
     *
     * **No line-number gutter**, and that is measured rather than an omission: a
     * gutter means one view per line, and a megabyte of source is tens of
     * thousands of them in a `VStack` that SwiftUI lays out in one pass. The
     * ceiling on this screen exists because a single `Text` that size is already
     * close to what a phone will draw in a frame.
     */
    @ViewBuilder
    private var fileBody: some View {
        if isMarkdown && asProse {
            // Prose is the one thing on this screen that *should* wrap, so it
            // scrolls in one axis and is laid out at the width it is given.
            ScrollView {
                MarkdownProse(text: text, scheme: scheme)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .accessibilityIdentifier("artifact.body")
            }
            .background(TerminalPalette.swiftUIColor(scheme.background, fallback: .black))
        } else {
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TerminalPalette.swiftUIColor(scheme.foreground, fallback: .label))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .accessibilityIdentifier("artifact.body")
            }
            .background(TerminalPalette.swiftUIColor(scheme.background, fallback: .black))
        }
    }

    // MARK: The two answers that are not a file

    /**
     * Not text, said in as much detail as this side honestly has.
     *
     * The machine's word for what the file *is not*, this side's guess from the
     * name at what it might be — labelled as the extension it came from so
     * nobody reads it as the machine's answer — and the size, which is real.
     */
    private var notText: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                card {
                    row(icon: "doc.badge.ellipsis",
                        title: "This is not a text file",
                        detail: facts,
                        note: "The machine decided that from the bytes themselves — a zero byte in the "
                            + "block it read — rather than from the file's name. That is the test every "
                            + "editor uses, and the only one that is right about a .log that is really a "
                            + "crash dump. It sent no text at all rather than sending nonsense.")
                }
                TabBarClearance()
            }
            .padding(.top, 16)
        }
        .accessibilityIdentifier("artifact.binary")
    }

    /// A `.zip`, a `.sqlite`, a font. Named and measured, and nothing is offered
    /// that would end in a frame that cannot load.
    private var opaque: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                card {
                    row(icon: "shippingbox",
                        title: "Nothing here can open this",
                        detail: facts,
                        note: "It is not a page, a picture or text. Its path is on the menu above, "
                            + "which is what a session on \(model.theMachine) needs to do something "
                            + "with it.")
                }
                TabBarClearance()
            }
            .padding(.top, 16)
        }
        .accessibilityIdentifier("artifact.opaque")
    }

    /// An agent wrote it and it is not there any more. A true fact about the
    /// project rather than a failure of this screen, and the panel's history
    /// still holds what it was.
    private var absent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                card {
                    row(icon: "questionmark.folder",
                        title: "Not on disk any more",
                        detail: opened.path,
                        note: "An agent made this and it has since been deleted or moved. Nothing can "
                            + "be opened, and the record of what was written to it is still on the "
                            + "Artifacts list.")
                }
                TabBarClearance()
            }
            .padding(.top, 16)
        }
        .accessibilityIdentifier("artifact.gone")
    }

    /// The kind in a word, the extension labelled as one, and the size.
    private var facts: String {
        var parts: [String] = []
        if !opened.suffix.isEmpty { parts.append(".\(opened.suffix) file") }
        if let bytes = opened.bytes { parts.append(byteSize(bytes)) }
        return parts.isEmpty ? "Nothing more is known about it from here." : parts.joined(separator: "  ·  ")
    }

    // MARK: - The bar at the bottom

    /**
     * How much of the file is in hand, and the button that reads on.
     *
     * Drawn only for a text file the host said was truncated, so a file that
     * came back whole has nothing at the bottom of the screen at all. Past the
     * ceiling the sentence stays and the button goes — the fact that there is
     * more does not stop being true because this screen has stopped fetching it.
     */
    @ViewBuilder
    private var bottomBar: some View {
        if readsAFile && truncated && !binary {
            VStack(spacing: 0) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(readSoFar)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                        if readTo >= ceiling {
                            Text("This screen stops here. Use a session and `tail` for the rest.")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.faint)
                        }
                    }
                    Spacer(minLength: 8)
                    if readTo < ceiling {
                        Button {
                            readMore()
                        } label: {
                            if waiting {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Read more").font(.system(size: 15, weight: .semibold))
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(waiting)
                        .accessibilityIdentifier("artifact.more.read")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(.bar)
        } else if opened.kind == .image, picture != nil, model.canBrowseLocalhost {
            VStack(spacing: 0) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                HStack(spacing: 12) {
                    Text(actualSize ? "Actual size" : "Fit to width")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                    Spacer(minLength: 8)
                    Button("Open in the browser view") { run() }
                        .font(.system(size: 15))
                        .disabled(pending != nil)
                        .accessibilityIdentifier("artifact.image.page")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(.bar)
        }
    }

    private var readSoFar: String {
        if let bytes = opened.bytes, bytes > 0 {
            return "First \(byteSize(readTo)) of \(byteSize(bytes))"
        }
        return "First \(byteSize(readTo)) — there is more"
    }

    // MARK: - Pieces

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 16)
    }

    private func row(icon: String, title: String, detail: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.primary)
                Spacer(minLength: 8)
                InfoDot(about: title, text: note)
            }
            Text(detail)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 36)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noteRow(_ what: String) -> some View {
        Text(what)
            .font(.system(size: 14))
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
    }

    /// Whatever went wrong, in the machine's words where there are any, with the
    /// one control that is worth offering after it.
    private func failure(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(Theme.critical)
                    .frame(width: 24)
                Text("That did not work.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.primary)
                Spacer(minLength: 0)
            }
            Text(reason)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 36)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .accessibilityIdentifier("artifact.error")
    }

    /// Nothing came back. It says *no answer*, not *that file does not exist*,
    /// because this screen cannot tell those apart — a refusal is an `error`
    /// frame on the connection and never reaches here.
    private var noAnswer: some View {
        ContentUnavailableView {
            Label("No answer from the machine", systemImage: "doc.questionmark")
        } description: {
            Text("It did not send anything back for this file. It may not have been able to read it.")
        } actions: {
            Button("Try again") { startReading() }
                .accessibilityIdentifier("artifact.retry")
        }
    }
}

// MARK: - Markdown, as prose

/**
 * A note an agent wrote, read as a note.
 *
 * Markdown is far and away the most common thing an agent produces — a plan, a
 * summary, a handover — and *"they can be reviewed"* is the word he used. A plan
 * shown as monospace source with its own hashes and asterisks in it is the same
 * defect the desktop panel was reported for twice: a page about what was made
 * that looks like a file browser.
 *
 * **A block renderer and not a Markdown implementation.** Headings, bullets,
 * numbered items, fenced code, rules and paragraphs — the six shapes an agent
 * actually writes. Everything inside a paragraph goes through Foundation's own
 * `AttributedString(markdown:)`, which handles emphasis, code spans and links
 * and is the only part of this worth not writing. A construct nobody handles —
 * a table, a footnote — falls through to its own source text on its own line,
 * which is legible and is never wrong about what the file says.
 *
 * The source is one press away on the menu, because the markup is the artifact
 * as much as the prose is.
 */
private struct MarkdownProse: View {
    let text: String
    let scheme: TerminalScheme

    /// Blocks drawn before the rest is left to the source view.
    ///
    /// A `LazyVStack` would let this be unbounded, and it would still be one
    /// SwiftUI view per block over a file this screen has already capped at a
    /// megabyte. Two thousand blocks is a very long document and a bound that
    /// says so out loud beats a screen that stops responding.
    private static let maxBlocks = 2_000

    private var ink: Color { TerminalPalette.swiftUIColor(scheme.foreground, fallback: .label) }
    private var quiet: Color { TerminalPalette.swiftUIColor(scheme.brightBlack, fallback: .secondaryLabel) }
    private var accent: Color { TerminalPalette.swiftUIColor(scheme.cyan, fallback: .systemBlue) }

    var body: some View {
        let blocks = MarkdownBlock.parse(text)
        return LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.prefix(Self.maxBlocks).enumerated()), id: \.offset) { _, block in
                draw(block)
            }
            if blocks.count > Self.maxBlocks {
                Text("\(blocks.count - Self.maxBlocks) more blocks are not drawn. Show the source to read them.")
                    .font(.system(size: 12))
                    .foregroundStyle(quiet)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func draw(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, words):
            inline(words)
                .font(.system(size: [22.0, 19.0, 17.0][min(level, 3) - 1], weight: .semibold))
                .foregroundStyle(ink)
                .padding(.top, level == 1 ? 8 : 4)
        case let .paragraph(words):
            inline(words).font(.system(size: 15)).foregroundStyle(ink)
        case let .bullet(marker, words):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).font(.system(size: 15)).foregroundStyle(accent)
                inline(words).font(.system(size: 15)).foregroundStyle(ink)
            }
            .padding(.leading, 6)
        case let .code(body):
            Text(body)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(TerminalPalette.swiftUIColor(scheme.selectionBackground, fallback: .clear),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .rule:
            Rectangle().fill(quiet.opacity(0.4)).frame(height: 0.5).padding(.vertical, 4)
        }
    }

    /// Emphasis, code spans and links, from Foundation. A line it refuses is
    /// drawn as itself — never dropped, and never guessed at.
    private func inline(_ words: String) -> Text {
        if let parsed = try? AttributedString(
            markdown: words,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(parsed)
        }
        return Text(words)
    }
}

/// One shape of thing in a markdown file. Six, because six is what an agent
/// writes; see {@link MarkdownProse}.
enum MarkdownBlock: Equatable {
    case heading(level: Int, String)
    case paragraph(String)
    case bullet(marker: String, String)
    case code(String)
    case rule

    /**
     * Split a document into blocks, in one pass and without a grammar.
     *
     * A fence swallows everything to the next fence, which is the one rule that
     * has to be applied before any other — a `# heading` inside a code block is
     * a shell comment, and a renderer that drew it as a heading would be
     * rewriting somebody's script in their own document. An unterminated fence
     * runs to the end of the file, which is what every renderer does and what
     * the author of a half-written file means.
     */
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var fence: [String] = []
        var fenced = false

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if fenced {
                    blocks.append(.code(fence.joined(separator: "\n")))
                    fence = []
                    fenced = false
                } else {
                    flush()
                    fenced = true
                }
                continue
            }
            if fenced {
                fence.append(line)
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                let rest = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                if hashes <= 6 && !rest.isEmpty {
                    flush()
                    blocks.append(.heading(level: hashes, rest))
                    continue
                }
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flush()
                blocks.append(.bullet(marker: "•", String(trimmed.dropFirst(2))))
                continue
            }
            if let dot = trimmed.firstIndex(of: "."),
               dot > trimmed.startIndex,
               trimmed[trimmed.startIndex..<dot].allSatisfy({ $0.isNumber }),
               trimmed.index(after: dot) < trimmed.endIndex,
               trimmed[trimmed.index(after: dot)] == " " {
                flush()
                blocks.append(.bullet(marker: String(trimmed[trimmed.startIndex...dot]),
                                      String(trimmed[trimmed.index(dot, offsetBy: 2)...])))
                continue
            }
            paragraph.append(trimmed)
        }
        if fenced && !fence.isEmpty { blocks.append(.code(fence.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}
