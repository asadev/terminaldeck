import AppKit
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore
import UniformTypeIdentifiers

// Context handoff (L5, 11 Oct): a button that asks the seat's own AI (Hoot first) for a handoff
// document about the topic under discussion. The button runs a BACKGROUND turn (nothing is added
// to the visible chat: no bubble, no reply, no "ready" line); the AI writes the document and
// delivers it with the `handoff.present` tool, which saves it with the topic and raises an event; this canvas
// opens on that event beside the chat, with Copy, Save as file… and Regenerate (= ask again).
// Keyed by seat (owner key), so the same button and panel fit Hoot, a lead or an agent.

/// One written handoff.
struct NativeHandoffDoc: Identifiable, Sendable, Equatable {
    var id: String
    /// The topic it was written for (nil = the whole conversation).
    var topicID: String?
    var title: String
    var markdown: String
    var createdAt: Date
    /// True once memory holds a copy with the topic.
    var kept: Bool
    init(id: String = UUID().uuidString, topicID: String?, title: String, markdown: String, createdAt: Date = Date(), kept: Bool = false) {
        self.id = id; self.topicID = topicID; self.title = title; self.markdown = markdown; self.createdAt = createdAt; self.kept = kept
    }
}

/// The calls behind the panel, set once by the lanes that own them. All take the seat's owner key
/// ("hoot", "lead:<project>", "role:<project>/<role>").
@MainActor
enum NativeHandoffActions {
    /// L6 (the chat): run a background turn asking the seat's AI for a handoff of one topic (nil =
    /// the whole conversation). Nothing shows in the chat. `progress` gets short plain lines on what
    /// the AI is doing. Returns when the turn has ended; throws one plain sentence when it failed
    /// or could not start. The document itself arrives through `presented`.
    static var ask: (@MainActor (_ ownerKey: String, _ topicID: String?, _ topicTitle: String, _ progress: @escaping @MainActor (String) -> Void) async throws -> Void)?
    /// L6: stop the background turn writing this seat's handoff (topicID nil = whole conversation).
    static var cancel: (@MainActor (_ ownerKey: String, _ topicID: String?) async -> Void)?
    /// M1 (memory): one stored handoff by the id the `handoff.present` event carries.
    static var load: (@MainActor (_ ownerKey: String, _ id: String) async throws -> NativeHandoffDoc)?
    /// M1: earlier handoffs of this seat for one topic (nil = whole conversation), newest first.
    static var earlier: (@MainActor (_ ownerKey: String, _ topicID: String?) async throws -> [NativeHandoffDoc])?
    /// M1: keep (replace) a document with its topic after the person edited it. Returns the kept copy.
    static var keep: (@MainActor (_ ownerKey: String, _ doc: NativeHandoffDoc) async throws -> NativeHandoffDoc)?

    /// Call when `handoff.present` saved a document (M1's event; also when the person asked in
    /// plain words in the chat): opens the canvas beside the chat on that document.
    static func presented(ownerKey: String, id: String) {
        guard let owner = DeckMemoryOwner(key: ownerKey) else { return }
        NativeHandoffModel.of(owner).presented(id: id)
    }
    /// Optional: the seat's AI finished a turn. A request still waiting then gets "finished
    /// without a handoff" and Try again (the panel also does this itself when `ask` returns).
    static func turnEnded(ownerKey: String) {
        guard let owner = DeckMemoryOwner(key: ownerKey) else { return }
        NativeHandoffModel.of(owner).turnEnded()
    }
}

@MainActor
@Observable
final class NativeHandoffModel {
    private static var models: [String: NativeHandoffModel] = [:]
    static func of(_ owner: DeckMemoryOwner) -> NativeHandoffModel {
        if let found = models[owner.key] { return found }
        let made = NativeHandoffModel(owner: owner)
        models[owner.key] = made
        return made
    }

    enum Phase: Equatable { case idle, writing(String), ready, failed(String) }
    static let whole = "__whole__"

    let owner: DeckMemoryOwner
    let fixture: Bool
    var isOpen = false
    var width: Double = 460
    var phase: Phase = .idle
    var topics: [DeckMemoryTopic] = []
    /// The chosen topic id, or `whole`.
    var topic = NativeHandoffModel.whole
    var doc: NativeHandoffDoc?
    /// The text on the canvas (the person may edit it before copying or saving).
    var text = ""
    var editing = false
    var earlier: [NativeHandoffDoc] = []
    var copied = false
    var note: String?
    @ObservationIgnored private var run = 0
    /// A request was sent and no document has arrived yet.
    @ObservationIgnored private var waiting = false
    var who: String { owner == .hoot ? "Hoot" : "The agent" }
    @ObservationIgnored private var topicChosen = false

    init(owner: DeckMemoryOwner, fixture: Bool = false) { self.owner = owner; self.fixture = fixture }

    var topicID: String? { topic == Self.whole ? nil : topic }
    /// L6: a handoff asked for from one message covers the conversation up to it; the panel says so.
    var upTo: String?
    var topicTitle: String { upTo.map { "Up to: " + $0 } ?? topics.first { $0.id == topic }?.title ?? "Whole conversation" }
    var edited: Bool { doc.map { $0.markdown != text } ?? false }
    var isWriting: Bool { if case .writing = phase { true } else { false } }

    /// The button: open the canvas and, the first time, start writing straight away.
    func toggle() {
        if isOpen { isOpen = false; return }
        isOpen = true
        Task {
            await loadTopics()
            if doc == nil, !isWriting {
                if let latest = earlier.first { show(latest) } else { generate() }
            }
        }
    }

    func loadTopics() async {
        guard !fixture else { return }
        if let found = try? await DeckMemory.ready().topics(owner, includeClosed: false) {
            topics = found.sorted { $0.updatedAt > $1.updatedAt }
        }
        // The topic under discussion: the open topic touched most recently.
        if !topicChosen || (topic != Self.whole && !topics.contains { $0.id == topic }) {
            topic = topics.first?.id ?? Self.whole
        }
        await loadEarlier()
    }

    func choose(_ id: String) {
        upTo = nil
        guard id != topic else { return }
        topic = id; topicChosen = true
        Task {
            await loadEarlier()
            // A topic with a kept handoff opens on it; otherwise the person asks for one.
            if let latest = earlier.first { show(latest) } else if !isWriting { run += 1; doc = nil; text = ""; phase = .idle }
        }
    }

    func loadEarlier() async {
        guard !fixture, let list = NativeHandoffActions.earlier else { return }
        earlier = (try? await list(owner.key, topicID)) ?? []
    }

    func show(_ found: NativeHandoffDoc) {
        run += 1; waiting = false
        doc = found; text = found.markdown; editing = false; phase = .ready
        note = found.kept ? "Saved with this topic" : nil
    }

    /// Ask the seat's AI for the handoff (the button, Try again and Regenerate all land here).
    func generate() {
        guard !fixture else { return }
        upTo = nil
        guard let ask = NativeHandoffActions.ask else {
            phase = .failed("\(who) cannot be asked from here yet.")
            return
        }
        run += 1
        let mine = run, key = owner.key, id = topicID, title = topicTitle
        waiting = true
        phase = .writing("\(who) is writing the handoff…"); note = nil; editing = false
        Task {
            do {
                try await ask(key, id, title) { [weak self] line in
                    guard let self, self.run == mine, self.waiting, !line.isEmpty else { return }
                    self.phase = .writing(line)
                }
                // The turn is over. The document normally arrived before this; give its event a moment.
                try? await Task.sleep(for: .seconds(1.5))
                if run == mine { turnEnded() }
            } catch {
                guard run == mine else { return }
                waiting = false
                let words = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                phase = .failed(words.isEmpty ? "The request could not be sent to \(who)." : words)
            }
        }
    }

    /// Stop: the turn writing it is stopped, and the panel says so (nothing restarts it by itself).
    func stop() {
        guard isWriting else { return }
        run += 1; waiting = false
        let key = owner.key, id = topicID
        phase = .failed("Stopped. Nothing more is written until you ask again.")
        Task { await NativeHandoffActions.cancel?(key, id) }
    }

    /// `handoff.present` saved a document: open the canvas on it.
    func presented(id: String) {
        isOpen = true
        guard let load = NativeHandoffActions.load else {
            waiting = false; phase = .failed("The handoff was written, but it could not be opened here."); return
        }
        run += 1
        let mine = run, key = owner.key
        if doc == nil { phase = .writing("Opening the handoff…") }
        Task {
            do {
                let found = try await load(key, id)
                guard run == mine else { return }
                if topics.isEmpty { await loadTopics() }
                topic = found.topicID.flatMap { id in topics.contains { $0.id == id } ? id : nil } ?? Self.whole
                topicChosen = true
                show(found)
                await loadEarlier()
            } catch {
                guard run == mine else { return }
                waiting = false
                phase = .failed("The handoff was written, but it could not be opened: " + error.localizedDescription)
            }
        }
    }

    /// The AI's turn ended. Still waiting means it never delivered a handoff.
    func turnEnded() {
        guard waiting, isWriting else { return }
        waiting = false; run += 1
        phase = .failed("\(who) finished without writing a handoff.")
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.6)); copied = false }
    }

    /// "Handoff - <topic> - 2026-10-11.md"
    var fileName: String {
        let day = Date().formatted(.iso8601.year().month().day())
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: " -_"))
        let clean = String(topicTitle.unicodeScalars.filter { allowed.contains($0) }).trimmingCharacters(in: .whitespaces)
        return "Handoff - \(clean.isEmpty ? "conversation" : String(clean.prefix(60))) - \(day).md"
    }

    func saveAsFile() {
        let panel = NSSavePanel()
        panel.title = "Save the handoff"
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        let body = text
        panel.begin { [weak self] answer in
            guard answer == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try body.write(to: url, atomically: true, encoding: .utf8)
                    self?.note = "Saved to " + url.lastPathComponent
                } catch {
                    self?.note = "Could not save the file: " + error.localizedDescription
                }
            }
        }
    }

    /// Keep the edited text with the topic.
    func keepEdit() {
        guard var changed = doc, let keep = NativeHandoffActions.keep else { editing = false; return }
        changed.markdown = text
        let key = owner.key
        Task {
            do {
                let kept = try await keep(key, changed)
                doc = kept; text = kept.markdown; editing = false; note = "Saved with this topic"
                await loadEarlier()
            } catch {
                note = "Could not keep the change: " + error.localizedDescription
            }
        }
    }
}

/// The header button. Drop it on any seat's page: `NativeHandoffButton(ownerKey: "hoot")`.
struct NativeHandoffButton: View {
    let model: NativeHandoffModel
    var disabled = false
    init(owner: DeckMemoryOwner, disabled: Bool = false) { model = .of(owner); self.disabled = disabled }
    init(ownerKey: String, disabled: Bool = false) { self.init(owner: DeckMemoryOwner(key: ownerKey) ?? .hoot, disabled: disabled) }
    var body: some View {
        Button { model.toggle() } label: {
            Image(systemName: "doc.text").symbolVariant(model.isOpen ? .fill : .none)
                .frame(width: 28, height: 28).contentShape(.rect)
        }
        .buttonStyle(.borderless).disabled(disabled)
        .help("Context handoff: ask for a written summary of the topic under discussion, to read, copy or save")
        .accessibilityLabel("Context handoff")
    }
}

/// The canvas with its resize bar, for an `HStack` beside the chat. Draws nothing while closed.
struct NativeHandoffSide: View {
    let model: NativeHandoffModel
    @State private var dragWidth: Double?
    init(owner: DeckMemoryOwner) { model = .of(owner) }
    init(ownerKey: String) { self.init(owner: DeckMemoryOwner(key: ownerKey) ?? .hoot) }
    var body: some View {
        if model.isOpen {
            Divider()
            Color.clear.frame(width: 4).contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    if dragWidth == nil { dragWidth = model.width }
                    model.width = min(900, max(340, (dragWidth ?? model.width) - drag.translation.width))
                }.onEnded { _ in dragWidth = nil })
                .nativeHoverCursor(.resizeLeftRight)
                .help("Drag to resize the handoff")
            NativeHandoffPanel(model: model).frame(width: model.width)
        }
    }
}

/// The reading canvas: topic picker, the document (or its writing / failed state), the buttons.
struct NativeHandoffPanel: View {
    @Bindable var model: NativeHandoffModel
    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .background(DeckTokens.page)
    }

    private var bar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text("Context handoff").font(.headline)
                Spacer()
                Button { model.isOpen = false } label: { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(.rect) }
                    .buttonStyle(.borderless).help("Close").accessibilityLabel("Close the handoff")
            }
            HStack(spacing: 8) {
                Text("About").foregroundStyle(.secondary)
                Picker("Topic", selection: Binding(get: { model.topic }, set: { model.choose($0) })) {
                    ForEach(Array(model.topics.enumerated()), id: \.element.id) { index, topic in
                        Text(index == 0 ? topic.title + " (current topic)" : topic.title).tag(topic.id)
                    }
                    if !model.topics.isEmpty { Divider() }
                    Text("Whole conversation").tag(NativeHandoffModel.whole)
                }.labelsHidden().disabled(model.isWriting)
                Spacer(minLength: 0)
                if !model.earlier.isEmpty {
                    Menu("Earlier (\(model.earlier.count))") {
                        ForEach(model.earlier) { old in
                            Button(NativeMemoryStore.when(old.createdAt) + (old.id == model.doc?.id ? "  ✓" : "")) { model.show(old) }
                        }
                    }.fixedSize().help("Handoffs written earlier for this topic")
                }
            }.font(.callout)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private var canvas: some View {
        switch model.phase {
        case .writing(let line):
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                Text(line).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("About: " + model.topicTitle).font(.caption).foregroundStyle(.tertiary)
                Button("Stop") { model.stop() }.help("Stop writing this handoff")
            }.padding(24)
        case .failed(let why):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(DeckTokens.warn)
                Text(why).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                // A plain button: the shared "Try again" presses itself 0.6 s after it appears, which re-asked Hoot right
                // after a Stop (M25, 11 Oct). A handoff costs an AI turn; it is only written again when the person asks.
                Button("Try again") { model.generate() }.buttonStyle(.borderedProminent)
            }.padding(24)
        case .idle:
            VStack(spacing: 12) {
                Image(systemName: "doc.text").font(.title2).foregroundStyle(.secondary)
                Text("A handoff is a written summary of where this topic stands, ready to give to another AI or person.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button("Ask \(model.who) for a handoff") { model.generate() }.buttonStyle(.borderedProminent)
            }.padding(24)
        case .ready:
            if model.editing {
                TextEditor(text: $model.text).font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden).padding(10)
            } else if model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 12) {
                    Text("The handoff came back empty.").foregroundStyle(.secondary)
                    Button("Try again") { model.generate() }.buttonStyle(.borderedProminent)
                }.padding(24)
            } else {
                ScrollView {
                    NativeChatMarkdown(text: model.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18).padding(.vertical, 16)
                }
            }
        }
    }

    private var footer: some View {
        let ready = model.phase == .ready && !model.text.isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { model.copy() } label: {
                    Label(model.copied ? "Copied" : "Copy", systemImage: model.copied ? "checkmark" : "doc.on.doc")
                }.buttonStyle(.borderedProminent).disabled(!ready)
                    .help("Copy the whole document as Markdown")
                Button("Save as file…") { model.saveAsFile() }.disabled(!ready)
                if model.editing {
                    Button("Done") { if model.edited { model.keepEdit() } else { model.editing = false } }.disabled(!ready)
                } else {
                    Button("Edit") { model.editing = true }.disabled(!ready).help("Change the text before copying or saving")
                }
                Spacer(minLength: 0)
                Button { model.generate() } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                    .disabled(model.isWriting).help("Ask \(model.who) to write it again from the conversation as it is now")
            }
            if let note = model.note, model.phase == .ready {
                Label(note, systemImage: note.hasPrefix("Could not") ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if model.phase == .ready, model.edited {
                Text("Edited here. Copy and Save use your text.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
