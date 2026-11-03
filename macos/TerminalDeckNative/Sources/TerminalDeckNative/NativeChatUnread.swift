import AppKit
import SwiftUI
import TerminalDeckNativeCore

struct ChatUnreadScrollGeometry: Equatable {
    let rect: CGRect; let bottom: Bool
    /// The conversation's height: a change here is new content (a sent message, a streamed word), never the person scrolling.
    var contentHeight: CGFloat? = nil
}

@MainActor @Observable final class NativeChatUnreadViewport {
    var position = ScrollPosition(edge: .bottom)
    private(set) var dividerID: String?
    private(set) var dividerCount = 0
    private(set) var seen = 0
    private(set) var messages: [ChatUnreadMessage] = []
    private(set) var conversation = ""
    var bottom = true
    /// 30 Oct (Asad, "the chat doesn't move up"): the chat follows the newest content while this is on. Content growing
    /// (a sent message, a streamed answer) keeps it on; only the person scrolling away from the bottom turns it off,
    /// and coming back to the bottom, sending, or "Jump to latest" turns it on again.
    private(set) var following = true
    @ObservationIgnored private var contentHeight: CGFloat?
    /// "Jump to latest" shows when the person scrolled up to read and no "N new messages" pill already offers the way down.
    var showsJumpToLatest: Bool { !following && !bottom && pillCount == 0 }
    var active = false { didSet { scheduleSeen() } }
    var visibleRect = CGRect.zero
    var frames: [String: CGRect] = [:]
    @ObservationIgnored private var appeared = false
    @ObservationIgnored private var opened = false
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var landing: Task<Void, Never>?
    @ObservationIgnored var save: ((Int, String) async throws -> Void)?
    var problem: String?
    var pending: [ChatUnreadMessage] { messages.filter { $0.sequence > seen } }
    var pillCount: Int { !bottom && dividerID == nil ? pending.count : 0 }
    var firstUnseenTarget: String? { pending.first?.id }
    func appear() { appeared = true; opened = false }
    func disappear() { appeared = false; opened = false; active = false; timer?.cancel(); landing?.cancel() }
    func receive(conversation id: String, seen marker: Int, messages next: [ChatUnreadMessage]) {
        if conversation != id { conversation = id; seen = marker; opened = false; dividerID = nil; frames = [:] }
        seen = max(seen, marker); messages = next
        if dividerID != nil { dividerCount = pending.count }
        if let dividerID, !pending.contains(where: { $0.id == dividerID }) {
            withAnimation(.easeOut(duration: 0.35)) { self.dividerID = nil }
        }
        guard appeared, !id.isEmpty else { return }
        if !opened {
            opened = true
            if let first = pending.first { reveal(first.id) }
            else { position.scrollTo(edge: .bottom) }
        } else if following, dividerID == nil {
            position.scrollTo(edge: .bottom)
        }
        scheduleSeen()
    }
    func revealFirst() { if let first = pending.first { reveal(first.id) } }
    private func reveal(_ id: String) {
        dividerID = id; dividerCount = pending.count; bottom = false; following = false
        landing?.cancel()
        position.scrollTo(id: "unread:" + id, anchor: .top)
        landing = Task { @MainActor in
            // The page expands to include the target before the second layout pass.
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, appeared, dividerID == id else { return }
            position.scrollTo(id: "unread:" + id, anchor: .top)
        }
    }
    func geometry(_ rect: CGRect, bottom atBottom: Bool, contentHeight height: CGFloat? = nil) {
        let changed = height != nil && contentHeight != nil && height != contentHeight
        if let height { contentHeight = height }
        visibleRect = rect; bottom = atBottom
        if atBottom { following = true }
        else if !changed { following = false } // the person scrolled up to read
        else if following, dividerID == nil { position.scrollTo(edge: .bottom) } // new content: keep the newest in view
        scheduleSeen()
    }
    /// Sending, "Jump to latest", or coming back to a chat with nothing unread: the newest content, followed from here.
    func jumpToLatest() {
        landing?.cancel()
        if dividerID != nil { withAnimation(.easeOut(duration: 0.35)) { dividerID = nil } }
        following = true
        position.scrollTo(edge: .bottom)
    }
    /// The chat is on show again (a switch back to it): it opens at the bottom unless unread messages wait above.
    func returned() {
        guard appeared else { return }
        if pending.isEmpty { jumpToLatest() } else { revealFirst() }
    }
    func layout(_ next: [String: CGRect]) { frames = next; scheduleSeen() }
    private var visibleMessages: [ChatUnreadMessage] {
        pending.filter { message in frames[message.id].map { $0.intersects(visibleRect) } ?? false }
    }
    private var dividerVisible: Bool {
        guard let dividerID, let frame = frames["unread:" + dividerID] else { return false }
        return visibleRect.contains(frame)
    }
    @ObservationIgnored private var timedIDs: [String] = []
    @ObservationIgnored private var visit = ChatUnreadVisit()
    private func scheduleSeen() {
        let visible = visibleMessages
        let ids = visible.map(\.id)
        let eligible = appeared && active && !visible.isEmpty && (dividerID == nil || dividerVisible)
        guard eligible else {
            timer?.cancel(); timer = nil; timedIDs = []
            visit.update(active: false, visible: false, now: Date.timeIntervalSinceReferenceDate)
            return
        }
        // Scrolling/streaming updates never extend an unchanged exposure or spawn a poller.
        if timer != nil, ids == timedIDs { return }
        timer?.cancel(); timedIDs = ids
        visit.update(active: false, visible: false, now: Date.timeIntervalSinceReferenceDate)
        visit.update(active: true, visible: true, now: Date.timeIntervalSinceReferenceDate)
        let chat = conversation
        timer = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled, appeared, active, conversation == chat,
                  dividerID == nil || dividerVisible, visit.ready(now: Date.timeIntervalSinceReferenceDate) else { return }
            let sequence = visibleMessages.map(\.sequence).max() ?? seen
            guard sequence > seen else { return }
            do {
                try await save?(sequence, chat)
                guard conversation == chat else { return }
                seen = max(seen, sequence); problem = nil
                withAnimation(.easeOut(duration: 0.35)) { dividerID = nil }
            } catch { problem = "Couldn’t save which messages you’ve seen. " + error.localizedDescription }
            timer = nil; timedIDs = []; scheduleSeen()
        }
    }
}

struct NativeChatUnreadDivider: View {
    let count: Int
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().frame(height: 1)
            Text(count > 1 ? "New messages (\(count))" : "New messages")
                .font(.system(size: 11.5, weight: .semibold)).fixedSize()
            Rectangle().frame(height: 1)
        }.foregroundStyle(Color.accentColor).padding(.vertical, 5)
        .accessibilityAddTraits(.isHeader)
    }
}

struct NativeChatUnreadFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func unreadChatFrame(_ id: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: NativeChatUnreadFrames.self,
                value: [id: proxy.frame(in: .named("unread21-content"))])
        })
    }
}

/// Tracks this window, rather than the main window or whichever chat model is shared with a pop-out.
struct NativeChatUnreadWindow: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> WindowProbe { WindowProbe(changed: changed) }
    func updateNSView(_ view: WindowProbe, context: Context) { view.changed = changed; view.report() }
    @MainActor final class WindowProbe: NSView {
        var changed: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("Not used") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            report()
        }
        func report() {
            let value = window?.isKeyWindow == true && window?.isVisible == true && NSApp.isActive && !isHiddenOrHasHiddenAncestor
            Task { @MainActor [weak self] in self?.changed(value) }
        }
        isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

extension HootChatItem {
    var unreadMessageIDs: [String] {
        switch self {
        case .row(let row): [row.id]
        case .reply(_, let answer, _, _): answer.map { ($0.value["combinedMessageIDs"].elements ?? []).compactMap(\.string).isEmpty ? [$0.id] : ($0.value["combinedMessageIDs"].elements ?? []).compactMap(\.string) } ?? []
        }
    }
}

extension NativeHootChatModel {
    func saveSeen(_ sequence: Int, conversation: String) async throws {
        guard !fixtureMode else { return }
        _ = try await EngineBridge.shared.invoke(source.channel("read"), source.arguments([NSNull(), 500, sequence, conversation]))
    }
}
