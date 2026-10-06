import AppKit
import SwiftUI
import TerminalDeckNativeCore
import UniformTypeIdentifiers

// Lane T — the chat box (`components/ChatComposer.tsx`, `chat/attach/AttachChips.tsx`,
// `chat/attach/AttachMenu.tsx`): one box, its attachments over the words, "Add"
// (or "Path" for a shell) at the foot and the round send button. Enter sends,
// Shift+Enter starts a new line. A dropped or pasted file becomes an attachment;
// one the session cannot read from where it is held is brought in first.
//
// The microphone is not drawn: `plain` withholds it, and the rail panel — the
// only place this box is mounted — is always plain.

struct NativeChatComposer: View {
    var sessionId: String?
    var cwd: String? = nil
    /// A shell: paths are typed, quoted, rather than attached.
    var shell = false
    var plain = false
    /// The rail's one small typing box (`.copilot-rail .cc-input`): one line to start.
    var compact = false
    /// Why there is no "Add" here, in its place (`noAttachReason`).
    var noAttachReason: String? = nil
    var onSend: ((String) -> Void)?

    @State private var text = ""
    @State private var attachments: [ChatAttachment] = []
    @State private var notice: String?
    @State private var noticeTimer: Task<Void, Never>?
    @State private var dragging = false
    @State private var boundary = ChatAttachBoundary.unconfined
    @State private var keys = ComposerKeys()
    @FocusState private var focused: Bool

    private var root: String { cwd ?? "" }
    private var idle: Bool { onSend == nil }
    private var empty: Bool { ChatAttach.compose(attachments, typed: text).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            NativeAttachChips(attachments: attachments, notice: notice) { path in
                attachments = ChatAttach.remove(attachments, path: path)
            }
            box
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    if let noAttachReason {
                        Text(noAttachReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        NativeAttachMenu(pathMode: shell, disabled: idle,
                                         startIn: boundary.browseStart(root: root),
                                         onAdd: { addPicks($0) }, onNotice: { say($0) },
                                         onClose: { focused = true })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                sendButton
            }
        }
        .padding(compact ? 8 : 12)
        // A press on the frame itself, not on anything in it, puts the caret in the box.
        .background {
            RoundedRectangle(cornerRadius: compact ? 12 : 18, style: .continuous)
                .fill(idle ? Color(nsColor: .windowBackgroundColor) : dragging ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                      : Color(nsColor: .controlBackgroundColor))
                .onTapGesture { if !idle { focused = true } }
        }
        .overlay(RoundedRectangle(cornerRadius: compact ? 12 : 18, style: .continuous)
            .strokeBorder(dragging ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: 1)
            .allowsHitTesting(false))
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { dragging }, set: { dragging = $0 && !idle })) { providers in
            guard !idle else { return false }
            dropped(providers)
            return true
        }
        .padding(compact ? 8 : 12)
        .task(id: sessionId) { await readBoundary() }
        .onChange(of: root) {
            attachments = []
            notice = nil
        }
        .onAppear {
            keys.install(focused: { focused }, send: { send() }, pasteFiles: { pasteFiles() })
        }
        .onDisappear {
            keys.remove()
            noticeTimer?.cancel()
        }
    }

    // MARK: The box

    private var lineHeight: CGFloat { NSFont.preferredFont(forTextStyle: .body).boundingRectForFont.height }

    private var box: some View {
        let minHeight = compact ? 22 : 76
        let maxHeight = max(CGFloat(minHeight), min(lineHeight * CGFloat(ChatAttach.maxRows), (NSScreen.main?.frame.height ?? 900) * (compact ? 0.3 : 0.4)))
        return ZStack(alignment: .topLeading) {
            // The words again, invisible, so the box grows with what is typed.
            Text(text.isEmpty ? " " : text + (text.hasSuffix("\n") ? " " : ""))
                .font(.body)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(0)
                .accessibilityHidden(true)
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($focused)
                .disabled(idle)
                .accessibilityLabel(ChatComposerText.label(shell: shell))
            if text.isEmpty {
                Text(ChatComposerText.placeholder(idle: idle, shell: shell))
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: CGFloat(minHeight), maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(idle || empty ? Color.secondary : Color.white)
                .background(Circle().fill(idle || empty ? Color(nsColor: .quaternaryLabelColor) : Color.accentColor))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(idle || empty)
        .help(ChatComposerText.send)
        .accessibilityLabel("Send")
    }

    // MARK: Sending

    private func send() {
        let message = ChatAttach.compose(attachments, typed: text)
        guard !message.isEmpty, let onSend else { return }
        onSend(ChatAttach.terminalPayload(message))
        text = ""
        attachments = []
    }

    // MARK: Adding

    private func say(_ line: String?) {
        noticeTimer?.cancel()
        notice = line
        guard line != nil else { return }
        noticeTimer = Task {
            try? await Task.sleep(for: .milliseconds(Int(ChatAttach.noticeMs)))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    private func add(_ picks: [ChatPick]) {
        guard !picks.isEmpty else { return }
        if shell {
            for pick in picks { text = ChatAttach.append(text, TerminalText.shellQuote(pick.path)) }
            return
        }
        let result = ChatAttach.add(attachments, root: root, picks: picks, scope: .anywhere)
        attachments = result.attachments
        say(result.notice)
    }

    /// `addPicks`: what the session can read goes on; the rest is copied in first.
    private func addPicks(_ picks: [ChatPick]) {
        guard !picks.isEmpty else { return }
        let split = boundary.split(picks)
        if split.refused.isEmpty {
            add(split.allowed)
            return
        }
        guard let sessionId, !sessionId.isEmpty else {
            if !split.allowed.isEmpty { add(split.allowed) }
            say(ChatOutside.refusal(split.refused.count))
            return
        }
        Task {
            let answer = try? await EngineBridge.shared.invoke("attach:bring-in", [sessionId, split.refused.map(\.path)])
            let brought = answer == nil ? ([], split.refused.count) : ChatOutside.broughtIn(answer, picks: split.refused)
            add(split.allowed + brought.0)
            let line = ChatOutside.refusal(brought.1)
            if !line.isEmpty { say(line) }
        }
    }

    private func readBoundary() async {
        boundary = .unconfined
        guard let sessionId, !sessionId.isEmpty else { return }
        let answer = try? await EngineBridge.shared.invoke("attach:boundary", [sessionId])
        boundary = ChatAttachBoundary.decode(answer)
    }

    /// `picksFromDrop`: the paths, stated by the engine (a folder and an empty file look alike).
    private func inspect(_ paths: [String]) async -> [ChatPick] {
        guard !paths.isEmpty else { return [] }
        return ChatOutside.picks(try? await EngineBridge.shared.invoke("attach:inspect", [paths]))
    }

    private func dropped(_ providers: [NSItemProvider]) {
        Task {
            var paths: [String] = []
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                    paths.append(url.path)
                } else if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    paths.append(url.path)
                }
            }
            let picks = await inspect(paths)
            if picks.isEmpty {
                say(ChatOutside.unreadableDrop)
                return
            }
            addPicks(picks)
        }
    }

    /// ⌘V with a file or a picture on the clipboard: an attachment, not text.
    /// False leaves the paste to the box.
    private func pasteFiles() -> Bool {
        let board = NSPasteboard.general
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let types = board.types ?? []
        let image = types.contains(.png) || types.contains(.tiff)
        guard !urls.isEmpty || image else { return false }
        Task {
            let dropped = await inspect(urls.map(\.path))
            if !dropped.isEmpty {
                addPicks(dropped)
                return
            }
            switch ChatOutside.pasted(try? await EngineBridge.shared.invoke("attach:paste", [])) {
            case .failed(let message): say(message)
            case .picked(let picks): addPicks(picks)
            case .nothing: break
            }
        }
        return true
    }
}

/// Return and ⌘V in the box, ahead of the text view: Return without Shift sends
/// (not while an input method is composing), and a paste carrying files attaches them.
@MainActor
private final class ComposerKeys {
    private var monitor: Any?

    func install(focused: @escaping () -> Bool, send: @escaping () -> Void, pasteFiles: @escaping () -> Bool) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let composing = (event.window?.firstResponder as? NSTextView).map { $0.hasMarkedText() }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            let isPaste = flags == .command && event.charactersIgnoringModifiers?.lowercased() == "v"
            let taken = MainActor.assumeIsolated { () -> Bool in
                guard let composing, focused() else { return false }
                if isReturn {
                    if flags.contains(.shift) || composing { return false }
                    send()
                    return true
                }
                return isPaste && pasteFiles()
            }
            return taken ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Attachment chips (`AttachChips`)

struct NativeAttachChips: View {
    let attachments: [ChatAttachment]
    let notice: String?
    let remove: (String) -> Void

    var body: some View {
        if !attachments.isEmpty || notice != nil {
            FlowRow(spacing: 6) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        Text(ChatAttach.chipMark(attachment.kind))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(ChatAttach.basename(attachment.relPath))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if attachment.outside {
                            Text("outside")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .background(.quaternary, in: .rect(cornerRadius: 3))
                        }
                        Button { remove(attachment.path) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove")
                        .accessibilityLabel("Remove \(attachment.relPath)")
                    }
                    .font(.callout)
                    .frame(maxWidth: 240)
                    .padding(.leading, 8)
                    .padding(.trailing, 4)
                    .frame(height: 22)
                    .background(.quaternary.opacity(0.7), in: .capsule)
                    .help(ChatAttach.chipHelp(attachment))
                }
                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .padding(.horizontal, 8)
        }
    }
}

/// Wraps its children onto as many lines as they need (`flex-wrap`).
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.init(width: width, height: nil))
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.init(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y + (line > size.height ? 0 : 0)), proposal: .init(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - The attach menu (`AttachMenu`)

struct NativeAttachMenu: View {
    let pathMode: Bool
    let disabled: Bool
    let startIn: String
    let onAdd: ([ChatPick]) -> Void
    let onNotice: (String) -> Void
    let onClose: () -> Void

    @State private var open = false
    @State private var busy: ChatAttachMenu.Surface?

    var body: some View {
        Button {
            if open { close() } else { open = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                Text(ChatAttachMenu.word(pathMode: pathMode))
            }
            .font(.footnote)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(ChatAttachMenu.label(pathMode: pathMode))
        .accessibilityLabel(ChatAttachMenu.label(pathMode: pathMode))
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ChatAttachMenu.items(pathMode: pathMode), id: \.surface) { item in
                    Button { browse(item.surface) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: Self.symbol(item.surface))
                                .font(.system(size: 14))
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.label)
                                Text(busy == item.surface ? ChatAttachMenu.opening : item.hint)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy != nil)
                }
            }
            .padding(6)
            .frame(width: 336)
            .accessibilityLabel(ChatAttachMenu.title(pathMode: pathMode))
        }
    }

    static func symbol(_ surface: ChatAttachMenu.Surface) -> String {
        switch surface {
        case .file: return "doc"
        case .folder: return "folder"
        case .image: return "photo"
        }
    }

    private func close() {
        open = false
        onClose()
    }

    /// The Mac's own open panel, as the engine's dialog was: files (several), a folder,
    /// or images only, starting where the session can read.
    private func browse(_ surface: ChatAttachMenu.Surface) {
        busy = surface
        let panel = NSOpenPanel()
        let folder = surface == .folder
        panel.canChooseFiles = !folder
        panel.canChooseDirectories = folder
        panel.allowsMultipleSelection = !folder
        panel.title = folder ? "Add a folder" : surface == .image ? "Add an image" : "Add files"
        panel.prompt = "Add"
        if surface == .image {
            panel.allowedContentTypes = ChatAttach.imageExtensions.compactMap { UTType(filenameExtension: $0) }
        }
        if !startIn.isEmpty { panel.directoryURL = URL(fileURLWithPath: startIn, isDirectory: true) }
        let done: (NSApplication.ModalResponse) -> Void = { response in
            busy = nil
            guard response == .OK else { return }
            let picks = panel.urls.map { url in
                ChatPick(path: url.path, isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
            }
            guard !picks.isEmpty else { return }
            onAdd(picks)
            close()
        }
        open = false
        if let window = AppModel.shared.web.webView.window {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            panel.begin(completionHandler: done)
        }
    }
}
