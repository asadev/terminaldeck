import SwiftUI
import TerminalDeckNativeCore

extension Routines21ReportsModel {
    func acceptReports(_ raw: CodingAIJSON) {
        entries = (raw["entries"].array ?? []).map(Routines21Report.init).sorted { $0.sequence < $1.sequence }
    }
}

struct NativeRoutineFollowScroll<Message: View>: View {
    let entries: [Routines21Report]
    @Bindable var viewport: NativeChatFollowViewport
    var loading = false
    @ViewBuilder let message: (Routines21Report) -> Message
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if entries.isEmpty && !loading { Text("Reports appear here after each run. Ask a question below any time.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 28) }
                ForEach(entries) { entry in
                    message(entry).id(entry.id)
                }
            }.scrollTargetLayout().padding(.horizontal, 10).padding(.top, 10).background(NativeChatFollowScroll(viewport: viewport))
        }.scrollPosition($viewport.position)
        .defaultScrollAnchor(.bottom)
        .onScrollPhaseChange { _, phase in viewport.interacting = phase == .interacting || phase == .decelerating }
        .frame(height: 230).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor enum NativeRoutineChatFollow {
    static var views: [String: [UUID: NativeChatFollowViewport]] = [:]
    static func attach(_ viewport: NativeChatFollowViewport, routine: String) {
        views[routine, default: [:]][viewport.id] = viewport
        viewport.latest()
    }
    static func detach(_ viewport: NativeChatFollowViewport, routine: String) {
        views[routine]?[viewport.id] = nil
        if views[routine]?.isEmpty == true { views[routine] = nil }
    }
    static func tool(_ routine: String, _ action: String) throws -> NativeRPCValue {
        guard ["read", "latest", "earlier", "later"].contains(action) else { throw NativeRPCError.invalidArguments("Choose read, latest, earlier or later.") }
        let open = (views[routine] ?? [:]).values.map { $0 }
        for viewport in open {
            if action == "latest" { viewport.latest() }
            if action == "earlier" { viewport.page(-1) }
            if action == "later" { viewport.page(1) }
        }
        return .object([.init("views", .array(open.map(\.receipt)))])
    }
}
