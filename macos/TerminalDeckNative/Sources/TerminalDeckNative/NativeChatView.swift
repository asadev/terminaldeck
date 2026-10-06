import AppKit
import SwiftUI
import TerminalDeckNativeCore

// Lane T — a session read as a conversation (`components/ChatView.tsx`): the
// transcript the agent writes, read with `chat:load` and followed with
// `chat:tail` whenever the folder's transcripts change (`cost:update`), or every
// two seconds when nothing pushes. The user's turns sit right in a light fill,
// the agent's are the page's markdown; a message sent from the box shows as an
// echo until the transcript says it. The box is under it all.

struct NativeChatView: View {
    let sessionId: String?
    let cwd: String?
    /// The session the conversation must be the transcript of (`SessionScope`).
    var session: SessionScope? = nil
    var provider: String? = nil
    var plain = false
    /// The rail's narrower measurements (`.copilot-rail .chat-view`).
    var compact = false
    var onSend: ((String) -> Void)? = nil

    var body: some View {
        NativeChatPane(model: NativeChatModel(sessionId: sessionId, cwd: cwd, scope: session, provider: provider),
                       plain: plain, compact: compact, onSend: onSend)
            .id("\(sessionId ?? "")|\(cwd ?? "")|\(session?.startedAt ?? 0)|\(session?.resumed ?? false)|\(session?.agentSessionId ?? "")|\(provider ?? "")")
    }
}

/// `cost:watch` per folder, counted, so one reader letting go never stops another's.
@MainActor
enum NativeCostWatch {
    private static var counts: [String: Int] = [:]

    /// Counted at once; the task answers whether the engine is watching (`summary.watching`).
    @discardableResult
    static func retain(_ cwd: String) -> Task<Bool, Never> {
        counts[cwd, default: 0] += 1
        return Task {
            let summary = try? await EngineBridge.shared.invoke("cost:watch", [cwd]) as? [String: Any]
            return summary?["watching"] as? Bool == true
        }
    }

    static func release(_ cwd: String) {
        let count = counts[cwd] ?? 0
        if count <= 1 {
            counts[cwd] = nil
            Task { _ = try? await EngineBridge.shared.invoke("cost:unwatch", [cwd]) }
        } else {
            counts[cwd] = count - 1
        }
    }
}

// MARK: - The model

@MainActor
@Observable
final class NativeChatModel {
    let sessionId: String?
    let cwd: String?
    let scope: SessionScope?
    let provider: String?

    private(set) var messages: [ChatMessage] = []
    private(set) var found: Bool?
    private(set) var partial = false
    private(set) var unattributable = false
    private(set) var lookup: ChatLookup = .loading
    private(set) var folderSessions: [TerminalSessionInfo] = []
    private(set) var screenPresence: Bool?
    private(set) var pending: [PendingEcho] = []
    private(set) var now: Double = 0
    /// Bumped on every change to what the column draws, for the scroll to follow.
    private(set) var version = 0

    @ObservationIgnored private static var drawn = ChatDrawnMemory()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var watchedCwd: String?
    @ObservationIgnored private var watched = false
    @ObservationIgnored private var loadedKey: String?
    @ObservationIgnored private var path = ""
    @ObservationIgnored private var tailing = false
    @ObservationIgnored private var nudgedAt: Double = 0
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var tailTimer: Task<Void, Never>?
    @ObservationIgnored private var echoTicker: Task<Void, Never>?
    @ObservationIgnored private var folderQueued: Task<Void, Never>?
    @ObservationIgnored private var presenceSettle: Task<Void, Never>?
    @ObservationIgnored private var known = Set<String>()
    @ObservationIgnored private var seenAgent = false
    @ObservationIgnored private var echoSeq = 0

    init(sessionId: String?, cwd: String?, scope: SessionScope?, provider: String?) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.scope = scope
        self.provider = provider
    }

    var scoped: Bool { scope != nil }
    var paneKey: String { sessionId ?? cwd ?? "" }
    var target: String? { scoped ? lookup.path : nil }
    /// What `chat:load` is asked: the session's transcript, or the folder's.
    var key: String { target ?? (scoped ? "" : cwd ?? "") }
    var liveSessionId: String? { ChatFolder.liveSessionId(folderSessions, provided: sessionId) }

    var effectiveProvider: String? {
        let exited = sessionId.map { ChatFolder.exited(folderSessions, id: $0) } ?? false
        let settled = SessionPresence.fromSession(provider: provider, exited: exited)
        return SessionPresence.runningProvider(provider, agentRunning: settled ?? screenPresence)
    }

    var shell: Bool { effectiveProvider == "shell" }

    func empty(canType: Bool) -> ChatEmptyState? {
        ChatEmptyState.of(shell: shell, wired: true, messages: messages.count, scoped: scoped, hasTarget: target != nil,
                          lookup: lookup, key: key, found: found, unattributable: unattributable)
    }

    private var request: [String: Any] {
        if let target { return ["transcriptPath": target] }
        if !scoped, let cwd, !cwd.isEmpty { return ["cwd": cwd] }
        return [:]
    }

    // MARK: Start and stop

    func start() {
        guard !started else { return }
        started = true
        let drawn = Self.drawn.recall(paneKey)
        if !drawn.isEmpty {
            messages = drawn
            found = true
        }
        let bridge = EngineBridge.shared
        if let cwd, !cwd.isEmpty {
            readFolder()
            subscriptions.append(bridge.on("session:created") { [weak self] _ in self?.soon() })
            subscriptions.append(bridge.on("session:status") { [weak self] args in self?.sighting(args.first as? String) })
            subscriptions.append(bridge.on("session:exit") { [weak self] args in
                if let id = args.first as? String { self?.known.remove(id) }
                self?.soon()
            })
            if scoped { look() }
            watch(cwd)
        }
        if let sessionId, SessionPresence.fromSession(provider: provider, exited: false) == nil {
            readPresence()
            subscriptions.append(bridge.on("session:data") { [weak self] args in
                guard args.first as? String == sessionId else { return }
                self?.presenceSoon()
            })
        }
        reload()
        tick()
    }

    func stop() {
        started = false
        for subscription in subscriptions { subscription.cancel() }
        subscriptions = []
        for task in [lookupTask, tailTimer, echoTicker, folderQueued, presenceSettle] { task?.cancel() }
        lookupTask = nil
        tailTimer = nil
        echoTicker = nil
        folderQueued = nil
        presenceSettle = nil
        if !path.isEmpty { EngineBridge.shared.send("chat:close", [path]) }
        path = ""
        loadedKey = nil
        watched = false
        tailing = false
        if let watchedCwd { NativeCostWatch.release(watchedCwd) }
        watchedCwd = nil
    }

    // MARK: The transcript

    /// Load again when what is asked changed (`useEffect([key, request])`).
    private func reload() {
        guard started, loadedKey != key else { return }
        if !path.isEmpty { EngineBridge.shared.send("chat:close", [path]) }
        path = ""
        loadedKey = key
        guard !key.isEmpty else { return }
        if messages.isEmpty { messages = Self.drawn.recall(paneKey) }
        if found != true { found = nil }
        partial = false
        unattributable = false
        version += 1
        let asked = key
        let request = self.request
        Task { [weak self] in
            let answer = try? await EngineBridge.shared.invoke("chat:load", [request])
            guard let self, self.started, self.loadedKey == asked else { return }
            if !self.apply(answer) { self.found = false }
        }
    }

    @discardableResult
    private func apply(_ raw: Any?) -> Bool {
        guard let update = ChatUpdate.decode(raw) else { return false }
        found = update.found
        partial = update.startedMidFile
        unattributable = update.unattributable != nil
        path = update.transcriptPath
        messages = update.reset ? update.messages : ChatRules.merge(messages, update.messages)
        Self.drawn.remember(paneKey, messages)
        pending = ChatRules.settle(pending, against: messages)
        version += 1
        return true
    }

    private func tail() {
        guard started, !key.isEmpty, !tailing else { return }
        tailing = true
        let asked = key
        let request = self.request
        Task { [weak self] in
            let raw = try? await EngineBridge.shared.invoke("chat:tail", [request])
            guard let self else { return }
            self.tailing = false
            guard self.started, self.loadedKey == asked, let update = ChatUpdate.decode(raw),
                  !update.messages.isEmpty || update.reset else { return }
            self.apply(raw)
        }
    }

    /// A transcript in the folder changed: read the end, and ask again which one is ours.
    private func transcriptChanged() {
        tail()
        let at = Date().timeIntervalSince1970 * 1000
        guard at - nudgedAt >= ChatRules.reattributeMs else { return }
        nudgedAt = at
        if scoped { look() }
    }

    /// `useTranscriptChanges`: the folder's usage watch says when a transcript moved.
    private func watch(_ cwd: String) {
        watchedCwd = cwd
        subscriptions.append(EngineBridge.shared.on("cost:update") { [weak self] args in
            guard let self, let summary = args.first as? [String: Any], summary["sessions"] is [Any],
                  Self.sameProject(summary["cwd"] as? String ?? "", cwd) else { return }
            self.watched = true
            self.transcriptChanged()
        })
        let watching = NativeCostWatch.retain(cwd)
        Task { [weak self] in
            if await watching.value { self?.watched = true }
        }
    }

    static func sameProject(_ a: String, _ b: String) -> Bool {
        func trim(_ s: String) -> String {
            var s = s
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return !a.isEmpty && trim(a) == trim(b)
    }

    /// Every two seconds while nothing pushes changes; the echo clock every second while one waits.
    private func tick() {
        tailTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int(ChatRules.refreshMs)))
                guard let self, !Task.isCancelled else { return }
                if !self.watched { self.tail() }
            }
        }
    }

    // MARK: Which transcript is the session's (`useSessionTranscript`)

    private func look() {
        lookupTask?.cancel()
        guard let cwd, let scope else { return }
        let others = ChatFolder.siblingStarts(folderSessions, own: scope.startedAt)
        lookupTask = Task { [weak self] in
            while !Task.isCancelled {
                let files = BoardRules.transcriptFiles(try? await EngineBridge.shared.invoke("insights:list", [cwd]))
                guard let self, !Task.isCancelled else { return }
                let next = ChatLookup(TranscriptVerdict.attribute(files, scope: scope, others: others))
                if next != self.lookup {
                    self.lookup = next
                    self.version += 1
                    self.reload()
                }
                let wait = next.path != nil ? ChatRules.lookupRecheckMs : ChatRules.lookupWaitMs
                try? await Task.sleep(for: .milliseconds(Int(wait)))
            }
        }
    }

    // MARK: The folder's sessions (`useFolderSessions`)

    private func readFolder() {
        guard let cwd else { return }
        Task { [weak self] in
            guard let list = try? await EngineBridge.shared.invoke("session:list") as? [Any], let self else { return }
            let all = list.compactMap(TerminalSessionInfo.decode)
            for session in all { self.known.insert(session.id) }
            let mine = all.filter { $0.cwd == cwd }
            guard mine != self.folderSessions else { return }
            let starts = ChatFolder.siblingStarts(self.folderSessions, own: self.scope?.startedAt)
            self.folderSessions = mine
            // The others' start times are part of the question (`othersKey`).
            if self.scoped, self.started, ChatFolder.siblingStarts(mine, own: self.scope?.startedAt) != starts { self.look() }
        }
    }

    private func sighting(_ id: String?) {
        guard let id, !known.contains(id) else { return }
        known.insert(id)
        soon()
    }

    private func soon() {
        guard folderQueued == nil else { return }
        folderQueued = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(ChatRules.resolveCoalesceMs)))
            guard let self, !Task.isCancelled else { return }
            self.folderQueued = nil
            self.readFolder()
        }
    }

    // MARK: Is an agent running in a shell session (`useAgentPresence`)

    private func presenceSoon() {
        presenceSettle?.cancel()
        presenceSettle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.readPresence()
        }
    }

    private func readPresence() {
        guard let sessionId else { return }
        Task { [weak self] in
            let answer = try? await EngineBridge.shared.invoke("agent:controls:read", [["sessionId": sessionId]])
            guard let self, let reading = TerminalControls.decode(answer), reading.agentSaid else { return }
            self.screenPresence = SessionPresence.settle(previous: self.screenPresence, reading: reading.agentRunning,
                                                         seenAgent: self.seenAgent)
            if reading.agentRunning { self.seenAgent = true }
        }
    }

    // MARK: The echo

    /// A message from the box: sent, and drawn until the transcript says it.
    func sent(_ text: String, echoing: Bool) {
        guard echoing else { return }
        let at = Date().timeIntervalSince1970 * 1000
        echoSeq += 1
        now = at
        pending.append(PendingEcho(id: "echo:\(echoSeq)", text: text, at: at))
        version += 1
        guard echoTicker == nil else { return }
        echoTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.now = Date().timeIntervalSince1970 * 1000
                if self.pending.isEmpty {
                    self.echoTicker = nil
                    return
                }
            }
        }
    }
}

// MARK: - The pane

private struct NativeChatPane: View {
    @State var model: NativeChatModel
    let plain: Bool
    let compact: Bool
    let onSend: ((String) -> Void)?

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var stick = true
    @State private var behind = false
    @State private var width: CGFloat = 400

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                scroll
                if behind {
                    Button(ChatRules.jump) { jump() }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 16)
                        .frame(height: 28)
                        .background(.regularMaterial, in: .capsule)
                        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                        .padding(.bottom, 20)
                }
            }
            NativeChatComposer(sessionId: model.liveSessionId, cwd: model.cwd, shell: model.shell, plain: plain,
                               compact: compact, onSend: onSend == nil ? nil : { text in send(text) })
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var echoing: Bool { onSend != nil && !model.shell }

    private func send(_ text: String) {
        onSend?(text)
        model.sent(text, echoing: echoing)
        stick = true
        behind = false
    }

    private func jump() {
        position.scrollTo(edge: .bottom)
        stick = true
        behind = false
    }

    private var scroll: some View {
        ScrollView {
            let state = model.empty(canType: onSend != nil && !model.shell)
            VStack(spacing: 0) {
                if let state, model.pending.isEmpty {
                    NativeChatEmpty(state: state, canType: onSend != nil && !model.shell)
                        .padding(.vertical, compact ? 16 : 0)
                        .padding(.horizontal, compact ? 12 : 0)
                } else {
                    if model.partial {
                        Text(ChatRules.partial)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                            NativeChatBubble(message: message,
                                             heading: ChatRules.dayBreak(message.at, previous: index > 0 ? model.messages[index - 1].at : 0),
                                             bubbleWidth: width * 0.8)
                        }
                        ForEach(model.pending) { echo in
                            NativeEchoBubble(echo: echo, now: model.now, bubbleWidth: width * 0.8)
                        }
                    }
                }
            }
            .frame(maxWidth: compact ? .infinity : 720)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, compact ? 8 : 24)
            .padding(.top, compact ? 8 : 32)
            .padding(.bottom, compact ? 12 : 40)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: Bool.self, of: { geometry in
            geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height <= ChatRules.stickDistance
        }, action: { _, near in
            stick = near
            if near { behind = false }
        })
        .onChange(of: model.version) {
            guard !model.messages.isEmpty || !model.pending.isEmpty else { return }
            if stick { position.scrollTo(edge: .bottom) } else { behind = true }
        }
    }
}

// MARK: - Empty, one turn, an echo

struct NativeChatEmpty: View {
    let state: ChatEmptyState
    let canType: Bool

    var body: some View {
        VStack(spacing: 6) {
            Text(state.title)
                .font(.title3.weight(.semibold))
            let detail = state.detail(canType: canType)
            if !detail.isEmpty {
                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
    }
}

/// `ChatBubble`: the day over the first turn of a day, the words, and under them
/// the time and the copy button (the whole turn's source text).
struct NativeChatBubble: View {
    let message: ChatMessage
    let heading: String?
    let bubbleWidth: CGFloat

    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: message.role == .you ? .trailing : .leading, spacing: 4) {
            if let heading {
                Text(heading)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
            }
            if message.role == .you {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
                    .frame(maxWidth: bubbleWidth, alignment: .trailing)
            } else {
                NativeChatMarkdown(text: message.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            foot
        }
        .frame(maxWidth: .infinity, alignment: message.role == .you ? .trailing : .leading)
        .padding(.bottom, 24)
        .onHover { hovering = $0 }
        .driveAnchor(DriveAnchor.message(messageId: message.id).id)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .milliseconds(Int(ChatRules.copiedMs)))
            copied = false
        }
    }

    private var foot: some View {
        HStack(spacing: 6) {
            if message.role == .you { copy }
            Text(ChatRules.time(message.at))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if message.role == .agent { copy }
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 20)
    }

    private var copy: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.text, forType: .string)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(hovering || copied ? 1 : 0)
        .help(copied ? "Copied" : "Copy this message")
        .accessibilityLabel(copied ? "Copied" : "Copy this message")
    }
}

struct NativeEchoBubble: View {
    let echo: PendingEcho
    let now: Double
    let bubbleWidth: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(echo.text)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
                .opacity(0.62)
                .frame(maxWidth: bubbleWidth, alignment: .trailing)
            Text(ChatRules.echoNote(waitedMs: now - echo.at))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.bottom, 24)
    }
}

// MARK: - Markdown, drawn

/// An agent's turn: `marked` with the pane's renderer — code folded under its
/// label, links and images as their words with the address in the tooltip only.
struct NativeChatMarkdown: View {
    let text: String

    var body: some View {
        NativeChatBlocks(blocks: ChatMarkdown.parse(text))
            .textSelection(.enabled)
    }

    /// Inline markdown, with links made inert (dotted, not clickable) and code in a tint.
    static func inline(_ source: String) -> AttributedString {
        let prepared = ChatMarkdown.inlineSource(source)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard var out = try? AttributedString(markdown: prepared, options: options) else { return AttributedString(source) }
        var links: [Range<AttributedString.Index>] = []
        var codes: [Range<AttributedString.Index>] = []
        for run in out.runs {
            if run.link != nil { links.append(run.range) }
            if run.inlinePresentationIntent?.contains(.code) == true { codes.append(run.range) }
        }
        for range in links {
            out[range].link = nil
            out[range].underlineStyle = Text.LineStyle(pattern: .dot, color: .secondary)
        }
        for range in codes {
            out[range].font = .system(size: NSFont.systemFontSize * 0.86, design: .monospaced)
            out[range].backgroundColor = Color.secondary.opacity(0.14)
        }
        return out
    }
}

// MARK: - A line with links in it: their addresses as tooltips

extension NativeChatMarkdown {
    static var bodyFont: NSFont { NSFont.preferredFont(forTextStyle: .body) }
    static var headlineFont: NSFont { NSFont.preferredFont(forTextStyle: .headline) }
    static var subheadlineFont: NSFont {
        NSFontManager.shared.convert(NSFont.preferredFont(forTextStyle: .subheadline), toHaveTrait: .boldFontMask)
    }
    static func calloutFont(bold: Bool) -> NSFont {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        return bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
    }

    /// The same inline markdown for a text view, when it has a link: the link
    /// inert and dotted, with its address as the run's tooltip (`.cv-link`'s
    /// `title`). Nil when there is no link, and SwiftUI's Text draws it.
    static func rich(_ source: String, font: NSFont) -> NSAttributedString? {
        let prepared = ChatMarkdown.inlineSource(source)
        guard prepared.contains("](") || prepared.contains("<http") else { return nil }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: prepared, options: options),
              parsed.runs.contains(where: { $0.link != nil }) else { return nil }
        let out = NSMutableAttributedString()
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        let manager = NSFontManager.shared
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor, .paragraphStyle: style]
            var runFont = font
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                runFont = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.86, weight: .regular)
                attributes[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.14)
            }
            if intent.contains(.stronglyEmphasized) { runFont = manager.convert(runFont, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { runFont = manager.convert(runFont, toHaveTrait: .italicFontMask) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.toolTip] = link.absoluteString
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                attributes[.underlineColor] = NSColor.tertiaryLabelColor
            }
            attributes[.font] = runFont
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return out
    }
}

/// Inline markdown: SwiftUI's Text, or — when there is a link — a text view that
/// can show each link's address on hover.
private struct NativeChatInline: View {
    let source: String
    let font: Font
    let nsFont: NSFont

    var body: some View {
        if let rich = NativeChatMarkdown.rich(source, font: nsFont) {
            NativeChatLinkText(text: rich)
        } else {
            Text(NativeChatMarkdown.inline(source)).font(font)
        }
    }
}

private struct NativeChatLinkText: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        if view.textStorage?.isEqual(to: text) != true { view.textStorage?.setAttributedString(text) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = proposal.width.map { $0.isFinite ? $0 : 10_000 } ?? 10_000
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: proposal.width?.isFinite == true ? width : ceil(used.width), height: ceil(used.height))
    }
}

private struct NativeChatBlocks: View {
    let blocks: [ChatBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                NativeChatBlockView(block: block)
            }
        }
    }
}

private struct NativeChatBlockView: View {
    let block: ChatBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            NativeChatInline(source: text, font: .body, nsFont: NativeChatMarkdown.bodyFont)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            NativeChatInline(source: text, font: level <= 2 ? .headline : .subheadline.weight(.semibold),
                             nsFont: level <= 2 ? NativeChatMarkdown.headlineFont : NativeChatMarkdown.subheadlineFont)
                .padding(.top, 4)
        case .code(let language, let text):
            NativeChatCode(label: ChatMarkdown.codeLabel(language: language, text: text), text: text)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(start + index)." : "•")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        NativeChatBlocks(blocks: item)
                    }
                }
            }
            .padding(.leading, 4)
        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.quaternary).frame(width: 3)
                NativeChatBlocks(blocks: inner).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let header, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            NativeChatInline(source: cell, font: .callout.weight(.semibold), nsFont: NativeChatMarkdown.calloutFont(bold: true))
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                NativeChatInline(source: cell, font: .callout, nsFont: NativeChatMarkdown.calloutFont(bold: false))
                            }
                        }
                        if index < rows.count - 1 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }
                .font(.callout)
            }
            .scrollIndicators(.automatic)
        }
    }
}

/// `<details class="cv-code">`: shut until opened, at most 320 points tall, wrapped.
private struct NativeChatCode: View {
    let label: String
    let text: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(open ? "▾" : "▸")
                    Text(label)
                    Spacer(minLength: 0)
                }
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                ScrollView(.vertical) {
                    Text(text)
                        .font(.system(size: NSFont.systemFontSize * 0.92, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
    }
}
