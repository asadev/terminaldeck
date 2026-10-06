import AppKit
import SwiftUI
import TerminalDeckNativeCore

// What the island shows when it grows, drawn in Swift (lane B) — renderer/island/
// IslandPage.tsx with hoot-panel's AllSessions: the line, Hoot's last few lines,
// a box to ask it, Start when it is not running, and every session (a press opens
// it in the app). Lane I's IslandView draws this in place of the island's page when
// "island" is in NativeScreens.registered; the main page hands the session list
// over as `island-snapshot` (WebBridge, lane B line).

/// The main page's latest snapshot for the island.
@MainActor
@Observable
final class NativeIslandFeed {
    static let shared = NativeIslandFeed()
    private(set) var snapshot: IslandSnapshot?
    private init() {}

    /// True when `body` was the snapshot message (taken here, well-formed or not).
    @discardableResult
    func accept(_ body: Any) -> Bool {
        guard IslandContent.isSnapshotMessage(body) else { return false }
        if let next = IslandContent.snapshot(body), next != snapshot { snapshot = next }
        return true
    }
}

/// Hoot's conversation as the island follows it: read whole once, then the tail
/// each time Hoot's session changes state.
@MainActor
@Observable
final class NativeIslandChat {
    static let shared = NativeIslandChat()

    private(set) var messages: [IntentChatLine] = []
    var draft = ""
    private(set) var sending = false
    private(set) var problem: String?
    @ObservationIgnored private var home: String?
    @ObservationIgnored private var homeFor: String?
    @ObservationIgnored private var readFrom: String?
    @ObservationIgnored private var subscription: EngineSubscription?
    private init() {}

    private var hoot: NativeHootModel { NativeHootModel.shared }

    func start() {
        hoot.start()
        if subscription == nil {
            subscription = EngineBridge.shared.on("session:status") { [weak self] args in
                guard let self, let event = IntentHoot.statusEvent(args), event.id == self.hoot.state?.sessionId else { return }
                self.follow(whole: false)
            }
        }
        follow(whole: true)
    }

    /// `hootRunsIn`, asked again whenever the running Hoot changes.
    private func folder() async -> String? {
        let id = hoot.state?.sessionId
        let configured = hoot.state?.paths.root
        if id == homeFor, let home { return home }
        var next = configured
        if id != nil, let list = try? await EngineBridge.shared.invoke("session:list") {
            next = IslandContent.hootRunsIn(list, hootId: id, configured: configured)
        }
        home = next
        homeFor = id
        return next
    }

    func follow(whole asked: Bool) {
        Task {
            guard let cwd = await folder() else { return }
            // A different folder (Hoot restarted elsewhere) is read whole, as the page's effect did.
            let whole = asked || cwd != readFrom
            readFrom = cwd
            guard let raw = try? await EngineBridge.shared.invoke(whole ? "chat:load" : "chat:tail", [["cwd": cwd]]) else { return }
            let update = IslandContent.lines(raw)
            messages = IslandContent.merge(messages, update.lines, reset: whole || update.reset)
        }
    }

    /// Enter in the box: start Hoot if it is not running, type the words, then Return.
    func ask(name: String) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        problem = nil
        Task {
            defer { sending = false }
            var id = hoot.state?.sessionId
            if id == nil, let raw = try? await EngineBridge.shared.invoke("copilot:ensure") {
                id = (raw as? [String: Any])?["sessionId"] as? String
                if id?.isEmpty == true { id = nil }
                hoot.refresh()
            }
            guard let id else {
                problem = IslandContentWords.couldNotStart(name)
                return
            }
            let writes = ChatAttach.terminalWrites(text)
            for (index, data) in writes.enumerated() {
                EngineBridge.shared.send("session:write", [id, data])
                if index < writes.count - 1 { try? await Task.sleep(for: .milliseconds(ChatAttach.submitGapMs)) }
            }
            draft = ""
            follow(whole: false)
        }
    }
}

struct NativeIslandContent: View {
    /// The island page is drawn here instead (the page is then never loaded).
    static var isNative: Bool { NativeScreens.registered.contains("island") }

    let expanded: Bool
    @State private var chat = NativeIslandChat.shared
    @FocusState private var asking: Bool

    private var feed: IslandSnapshot? { NativeIslandFeed.shared.snapshot }
    private var name: String { feed?.assistant ?? CopilotWords.assistant }
    private var stopped: Bool { NativeHootModel.shared.stage == .stopped && !NativeHootModel.shared.loading }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HootMark(size: 18)
                Text(feed?.line ?? name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if expanded {
                conversation
                askRow
                if let problem = chat.problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                NativeIslandSessions(sessions: IslandContent.inOrder(feed?.sessions ?? [])) { id in show(id) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.primary)
        .onAppear { chat.start() }
        .onChange(of: expanded, initial: true) { _, grown in asking = grown }
    }

    private var conversation: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if chat.messages.isEmpty {
                        Text(IslandContentWords.quiet(name, stopped: stopped))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    } else {
                        ForEach(chat.messages, id: \.id) { message in
                            Text(message.text)
                                .font(.callout)
                                .lineSpacing(2)
                                .foregroundStyle(message.role == .you ? .secondary : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(message.id)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .accessibilityLabel(IslandContentWords.conversation(name))
            .onChange(of: chat.messages.last?.id) { _, last in
                if let last { reader.scrollTo(last, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var askRow: some View {
        HStack(spacing: 8) {
            if stopped {
                Button(IslandContentWords.start(name)) { NativeHootModel.shared.ensure() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
            }
            TextField("", text: $chat.draft, prompt: Text(IslandContentWords.ask(name)))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.callout)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
                .focused($asking)
                .disabled(chat.sending)
                .accessibilityLabel(IslandContentWords.ask(name))
                .onSubmit { chat.ask(name: name) }
        }
    }

    /// A press opens the session in the app: the island settles, the window comes forward.
    private func show(_ id: String) {
        IslandController.shared.collapse()
        AppModel.shared.select(id)
        NSApp.activate()
    }
}

/// `AllSessions`: one row each, scrolling when there are more than fit.
private struct NativeIslandSessions: View {
    let sessions: [IslandSessionRow]
    let onOpen: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if sessions.isEmpty {
                    Text(IslandContentWords.noSessions)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    ForEach(sessions) { session in Row(session: session) { onOpen(session.id) } }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .frame(maxHeight: .infinity)
        .accessibilityLabel(IslandContentWords.allSessions)
    }

    private struct Row: View {
        let session: IslandSessionRow
        let open: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: open) {
                HStack(spacing: 8) {
                    Circle().fill(dot).frame(width: 6, height: 6)
                    Text(session.label)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(IslandContent.what(session.status))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 8).fill(hovered ? Color.white.opacity(0.1) : .clear))
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help(IslandContentWords.rowTitle(session))
        }

        /// Needs you: the owl's orange; working: white; anything else: muted.
        private var dot: Color {
            switch session.status {
            case "input": return Color(red: 0xf7 / 255, green: 0x88 / 255, blue: 0x2f / 255)
            case "working": return .white
            default: return .white.opacity(0.4)
            }
        }
    }
}
