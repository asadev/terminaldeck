import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

// Sessions in the Cloud, step 1 (owner, 15 Nov: "don't make it too busy with too many cards, too many tags and buttons
// and options"): another machine's session is drawn as this Mac's own rows are (its type icon and its name, nothing
// else: DESIGN-SESSION-ROWS, 15 Nov). Opening one shows its chat read from the Cloud, read only, with one line on top. No other new button.

/// Another machine's session in the side panel's list, drawn as this Mac's own (Asad, 15 Nov; DESIGN-SESSION-ROWS):
/// the type icon and the name, one line; the orange dot only while it needs him. Where it runs is on its page.
struct SIDEBARCloudSessionRow: View {
    let row: BackendCloudSessionsRead.Row
    let project: PROJProject?
    let highlighted: Bool
    let onAccent: Bool
    let selection: AnyView
    let open: () -> Void
    static var minHeight: CGFloat { DeckSidebar.rowHeight }

    var title: String { row.name?.isEmpty == false ? row.name! : "Session" }
    var chat: Bool { row.kind == "chat" || row.kind == "hoot" }
    var machine: String { row.machineName?.isEmpty == false ? row.machineName! : "Another Mac" }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                SIDEBARSessionTypeIcon(chat: chat, onAccent: onAccent)
                Text(title).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(onAccent ? Color.white : Color.primary)
                Spacer(minLength: 4)
                SIDEBARNeedsYouDot(needsYou: SIDEBARNeedsYouDot.needsYou(status: row.status), onAccent: onAccent)
                    .frame(width: 22).padding(.trailing, -2)
            }
            .accessibilityElement(children: .combine)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .leading)
            .background(selection).contentShape(.rect)
        }
        .buttonStyle(DeckSidebarRowStyle())
        .help(title)
    }
}

/// "Earlier chats": one quiet row, no picture, no count.
struct SIDEBAREarlierChatsRow: View {
    let onAccent: Bool
    let selection: AnyView
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            Text(NativeCloudChats.earlierTitle).font(.system(size: 11))
                .foregroundStyle(onAccent ? Color.white : Color.secondary)
                .padding(.leading, 34).padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .background(selection).contentShape(.rect)
        }
        .buttonStyle(DeckSidebarRowStyle())
        .help("Chats of sessions that were closed, kept in your Cloud")
    }
}

/// A chat read from the Cloud: the newest page, older pages as he scrolls up, new messages every 15 s while open.
@MainActor @Observable
final class NativeCloudChatReader {
    private(set) var events: [HootChatEvent] = []
    private(set) var first = 0
    private(set) var loaded = false
    @ObservationIgnored private var gen = 0
    @ObservationIgnored private var loadingOlder = false
    @ObservationIgnored var fetch: @MainActor (_ ref: String, _ before: Int?, _ after: Int?) async -> BackendCloudSessionsRead.ChatPage? = { ref, before, after in
        await NativeCloudChats.shared.chat(ref: ref, before: before, after: after)
    }
    var hasOlder: Bool { first > 0 }

    /// The readable messages only: what he wrote and what the AI answered (plus an error line).
    static func shown(_ event: HootChatEvent) -> Bool {
        [.user, .message, .error].contains(event.record.kind) && !(event.record.value["text"].string ?? "").isEmpty
    }

    func open(_ ref: String) async {
        guard let page = await fetch(ref, nil, nil) else { loaded = true; return }
        apply(newest: page)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let next = await fetch(ref, nil, first + events.count) else { continue }
            if next.gen != gen { apply(newest: await fetch(ref, nil, nil) ?? next); continue }
            let known = Set(events.map(\.id))
            events += next.events.filter { !known.contains($0.id) }
        }
    }
    func apply(newest page: BackendCloudSessionsRead.ChatPage) {
        gen = page.gen; first = page.first; events = page.events; loaded = true
    }
    func older(_ ref: String) async {
        guard hasOlder, !loadingOlder else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        guard let page = await fetch(ref, first, nil), page.gen == gen else { return }
        first = page.first
        events = page.events + events
    }
}

/// Another machine's session, opened: its chat from the Cloud, read only, with "Runs on <machine>" on top.
struct NativeCloudChatPage: View {
    let ref: String
    @State private var reader = NativeCloudChatReader()
    /// Pictures only: what to draw instead of the account's lists and live links (nothing is read or dialled).
    var preview: NativeCloudLivePreview? = nil
    private var row: BackendCloudSessionsRead.Row? { preview?.row ?? NativeCloudChats.shared.row(ref: ref) }

    var body: some View {
        let row = self.row
        let reader = preview?.reader ?? self.reader
        // Live use from another Mac (15 Nov): that machine on and listing this session = the live session, by itself.
        let live = NativeCloudLiveChoice.choose(row: row, links: preview?.links ?? NativeMachineLinks.shared.snapshot)
        let machine = row?.machineName?.isEmpty == false ? row!.machineName! : "another Mac"
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row?.name ?? "Session").font(.title3.weight(.semibold)).lineLimit(1)
                NativeCloudMoveLine(state: NativeCloudMoveLine.state(row: row, machine: machine,
                                                                     move: NativeCloudChats.shared.moveLine(ref: ref, sessionId: row?.sessionId)),
                                    onSwitch: { NativeCloudChats.shared.switchHere(ref: ref) },
                                    onCancel: { NativeCloudChats.shared.cancelMove(ref: ref) })
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
            if let line = NativeCloudLiveChoice.problemLine(live, row: row, problem: preview?.problem ?? NativeReachLive.shared.problem) {
                Text(line).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 10)
            }
            if case .chat(let machineId, let chatId) = live {
                NativeMachineChatLivePage(machineId: machineId, chatId: chatId, preview: preview?.live)
            } else {
                NativeCloudChatMessages(reader: reader, ref: ref, terminal: row?.ai == "shell" || row?.readable == false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DeckTokens.frame)
        .task(id: ref) { if preview == nil { await reader.open(ref) } }
        .task(id: ref + (row?.machineOn == false ? " off" : " on")) {
            if preview == nil, row?.machineOn != false, row?.closedAt == nil { NativeReachLive.shared.want(machine: row?.machineName) }
        }
        .task(id: live) { if preview == nil, case .terminal(let tab) = live { AppModel.shared.select(tab) } }
    }
}

/// "Switch to this Mac" (step 2; owner, 15 Nov: "don't make it too busy"): the one grey line under the title, with ONE
/// small button at its end, nowhere else. While it moves: the line, a small spinner and Cancel in the same spot. Every
/// other sentence of the move takes the line's place once. None on Hoot's chat or an Earlier chat.
struct NativeCloudMoveLine: View {
    enum State: Equatable {
        case plain(String, canSwitch: Bool)
        case moving(String)
        case said(String, canSwitch: Bool)
    }
    let state: State
    var onSwitch: () -> Void = {}
    var onCancel: () -> Void = {}

    static func state(row: BackendCloudSessionsRead.Row?, machine: String, move: (line: String, moving: Bool)?) -> State {
        let canSwitch = row != nil && row?.closedAt == nil && row?.mine != true && row?.kind != "hoot"
        // A sentence of a finished move stands in the line's place; the button stays (he may move it back).
        if let move { return move.moving ? .moving(move.line) : .said(move.line, canSwitch: canSwitch) }
        return .plain(NativeCloudChats.runsOn(machine, on: row?.machineOn != false, closed: row?.closedAt != nil), canSwitch: canSwitch)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch state {
            case .plain(let text, let canSwitch), .said(let text, let canSwitch):
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if canSwitch {
                    Button(BackendCloudSessionMoveWords.button, action: onSwitch)
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Stop it there and continue it here, with its chat and its code")
                }
            case .moving(let text):
                Text(text).font(.callout).foregroundStyle(.secondary)
                ProgressView().controlSize(.small).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Button(BackendCloudSessionMoveWords.cancelButton, action: onCancel).buttonStyle(.borderless).controlSize(.small)
            }
        }
        .lineLimit(3)
    }
}

/// The messages, as the chat view draws an AI's answer (its markdown) and the person's message (a tinted bubble).
struct NativeCloudChatMessages: View {
    let reader: NativeCloudChatReader
    let ref: String
    var terminal = false
    var body: some View {
        let shown = reader.events.filter(NativeCloudChatReader.shown)
        if terminal || (reader.loaded && shown.isEmpty) {
            Text(terminal ? "A terminal, nothing to read." : "Nothing to read yet.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if reader.hasOlder {
                        // Scrolled to the top: the page before comes by itself (no button).
                        Color.clear.frame(height: 1).onAppear { Task { await reader.older(ref) } }
                    }
                    ForEach(shown) { event in NativeCloudChatMessage(event: event) }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
        }
    }
}

struct NativeCloudChatMessage: View {
    let event: HootChatEvent
    var body: some View {
        let text = event.record.value["text"].string ?? ""
        switch event.record.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(text).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.14), in: .rect(cornerRadius: 12))
            }
        case .error:
            Text(text).font(.callout).foregroundStyle(.secondary)
        default:
            NativeChatMarkdown(text: text).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "Earlier chats": the kept chats of closed sessions, the chosen project's first, then every other project's.
struct NativeCloudEarlierChatsPage: View {
    let project: String
    var body: some View {
        let cloud = NativeCloudChats.shared
        let projects = SIDEBARProjectStore.shared.projects
        let keys = cloud.earlier.keys.sorted { a, b in a == project ? true : b == project ? false : name(a, projects) < name(b, projects) }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(NativeCloudChats.earlierTitle).font(.title3.weight(.semibold))
                if keys.isEmpty { Text("No earlier chats.").font(.callout).foregroundStyle(.secondary) }
                ForEach(keys, id: \.self) { key in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name(key, projects)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 8)
                        ForEach(cloud.earlier[key] ?? []) { row in
                            SIDEBARCloudSessionRow(row: row, project: projects.first { $0.id == row.project?.cloudRef }, highlighted: false,
                                                   onAccent: false, selection: AnyView(Color.clear),
                                                   open: { AppModel.shared.select(SIDEBARCloudRows.sessionPrefix + row.ref) })
                        }
                    }
                }
            }
            .padding(24).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DeckTokens.frame)
    }
    func name(_ key: String, _ projects: [PROJProject]) -> String {
        if key.isEmpty { return "Independent" }
        return projects.first { $0.id == key }?.name
            ?? NativeCloudChats.shared.earlier[key]?.first?.project?.name ?? key
    }
}
