import SwiftUI
import TerminalDeckNativeCore

extension Routines21ReportsModel {
    var unreadMessages: [ChatUnreadMessage] {
        RoutineChatUnread.messages(entries, id: { $0.id }, kind: { $0.kind }, sequence: { $0.sequence })
    }
    func acceptUnread(_ raw: CodingAIJSON) {
        entries = (raw["entries"].array ?? []).map(Routines21Report.init).sorted { $0.sequence < $1.sequence }
        seenSequence = Int(raw["unread"]["seenSequence"].number ?? 0)
        unreadCount = Int(raw["unread"]["count"].number ?? 0)
    }
    func saveSeen(_ sequence: Int, conversation: String) async throws {
        guard !fixture, conversation == "routine:" + routineID else { return }
        let snapshot = try await call("routines:reports-chat", [routineID, sequence])
        acceptUnread(snapshot)
    }
}

struct NativeRoutineUnreadScroll<Message: View>: View {
    let entries: [Routines21Report]
    @Bindable var viewport: NativeChatUnreadViewport
    var loading = false
    @ViewBuilder let message: (Routines21Report) -> Message
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if entries.isEmpty && !loading { Text("Reports appear here after each run. Ask a question below any time.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 28) }
                ForEach(entries) { entry in
                    if viewport.dividerID == entry.id {
                        NativeChatUnreadDivider(count: viewport.dividerCount)
                            .id("unread:" + entry.id).unreadChatFrame("unread:" + entry.id).transition(.opacity)
                    }
                    message(entry).id(entry.id).unreadChatFrame(entry.id)
                }
                Color.clear.frame(height: viewport.dividerID == nil ? 1 : max(1, viewport.visibleRect.height - 50))
            }.scrollTargetLayout().padding(10).coordinateSpace(name: "unread21-content")
        }.scrollPosition($viewport.position)
        .onScrollGeometryChange(for: ChatUnreadScrollGeometry.self) { geometry in
            .init(rect: geometry.visibleRect, bottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 40)
        } action: { _, value in viewport.geometry(value.rect, bottom: value.bottom) }
        .onPreferenceChange(NativeChatUnreadFrames.self) { viewport.layout($0) }
        .frame(height: 230).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
    }
}
