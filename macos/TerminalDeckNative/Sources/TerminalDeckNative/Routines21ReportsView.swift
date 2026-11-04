import SwiftUI
import TerminalDeckNativeCore

struct Routines21Report: Identifiable {
    let id: String
    let kind: String
    let at: Double
    let status: String
    let text: String
    let deliveries: [CodingAIJSON]
    let sequence: Int
    init(_ value: CodingAIJSON) {
        id = value["id"].text ?? UUID().uuidString
        kind = value["kind"].text ?? "report"
        at = value["at"].number ?? 0
        status = value["status"].text ?? "ok"
        text = value["text"].text ?? ""
        deliveries = value["deliveries"].array ?? []
        sequence = Int(value["sequence"].number ?? 0)
    }
}

@MainActor @Observable final class Routines21ReportsModel {
    let routineID: String
    var entries: [Routines21Report] = []
    var draft = ""
    var loading = true
    var sending = false
    var problem: String?
    var reportID: String?
    var fixture = false
    @ObservationIgnored var call: @MainActor (String, [Any?]) async throws -> CodingAIJSON
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var generation = 0
    init(routineID: String, call: @escaping @MainActor (String, [Any?]) async throws -> CodingAIJSON) {
        self.routineID = routineID; self.call = call
    }
    func start() {
        guard !fixture else { return }
        if subscriptions.isEmpty {
            // Every report write names its routine: only that routine's chat reads again, not one per row.
            subscriptions.append(EngineBridge.shared.on("routines:reports-changed") { [weak self] args in
                guard let self, Routines21ReportsModel.concerns(args, routineID: self.routineID) else { return }
                self.load()
            })
        }
        load()
    }
    func stop() { subscriptions.forEach { $0.cancel() }; subscriptions.removeAll(); generation += 1 }
    /// A change event without a routine id still concerns every chat.
    nonisolated static func concerns(_ args: [Any], routineID: String) -> Bool {
        guard let changed = args.first as? String else { return true }
        return changed == routineID
    }
    func load() {
        guard !fixture else { return }
        generation += 1; let mine = generation
        Task {
            do {
                let raw = try await call("routines:reports-chat", [routineID])
                guard mine == generation else { return }
                acceptReports(raw)
                loading = false; problem = nil
            } catch {
                guard mine == generation else { return }
                loading = false; problem = "Couldn’t read this routine’s reports. Try again."
            }
        }
    }
    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true; problem = nil
        defer { sending = false }
        do {
            let raw = try await call("routines:follow-up", [routineID, text, reportID])
            guard raw["ok"].isTrue else { problem = "The question could not be sent. Try again."; return }
            draft = ""; reportID = nil; load()
        } catch { problem = "The question could not be sent. Try again." }
    }
}

struct Routines21ReportsView: View {
    let name: String
    let agentID: String
    var live = true
    @State private var model: Routines21ReportsModel
    @State private var followViewport = NativeChatFollowViewport()
    init(name: String, agentID: String, model: Routines21ReportsModel, live: Bool = true) {
        self.name = name; self.agentID = agentID; self.live = live; _model = State(initialValue: model)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(.secondary)
                Text("Reports").font(.callout.weight(.semibold))
                Spacer()
                Text("Each question starts a fresh job").font(.caption).foregroundStyle(.secondary)
            }
            NativeRoutineFollowScroll(entries: model.entries, viewport: followViewport, loading: model.loading) { entry in bubble(entry) }
                .overlay { if model.loading { skeleton } }
            if let id = model.reportID {
                HStack { Text("Asking about a report").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Clear") { model.reportID = nil } }
                    .accessibilityValue(id)
            }
            if let problem = model.problem {
                HStack { Text(problem).font(.caption).foregroundStyle(ROUTINESKit.bad); Spacer(); Button("Try again") { model.load() } }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about \(name)…", text: $model.draft, axis: .vertical).lineLimit(1...4).textFieldStyle(.plain)
                    .onSubmit { Task { await model.send() } }
                Button { Task { await model.send() } } label: {
                    if model.sending { ProgressView().controlSize(.small).frame(width: 18, height: 18) }
                    else { Image(systemName: "arrow.up").font(.body.weight(.semibold)).frame(width: 18, height: 18) }
                }.buttonStyle(.borderedProminent).disabled(model.sending || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Ask the routine’s agent").accessibilityLabel("Send question")
            }.padding(10).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        }.padding(.horizontal, 14).padding(.bottom, 14)
        .task { if live { model.start() } }
        .onAppear { NativeRoutineChatFollow.attach(followViewport, routine: model.routineID) }
        .onChange(of: model.sending) { _, sending in if sending { followViewport.latest() } }
        .onDisappear { NativeRoutineChatFollow.detach(followViewport, routine: model.routineID); if live { model.stop() } }
    }
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<3) { index in RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.10)).frame(width: index == 2 ? 180 : 280, height: 12) }
        }.padding(.vertical, 25).accessibilityLabel("Loading reports")
    }
    private func bubble(_ entry: Routines21Report) -> some View {
        HStack(alignment: .top, spacing: 9) {
            if entry.kind == "question" { Spacer(minLength: 50) }
            else { ROUTINESKit.avatar(agentID: agentID, size: 24) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(entry.kind == "question" ? "You" : entry.kind == "answer" ? "Follow-up answer" : "Run report").font(.caption.weight(.semibold))
                    Text(Date(timeIntervalSince1970: entry.at / 1_000).formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    if entry.kind != "question" {
                        Label(entry.status == "failed" ? "Failed" : entry.status == "pending" ? "Working…" : "OK", systemImage: entry.status == "failed" ? "xmark.circle" : entry.status == "pending" ? "clock" : "checkmark.circle")
                            .font(.caption).foregroundStyle(entry.status == "failed" ? ROUTINESKit.bad : entry.status == "pending" ? Color.secondary : ROUTINESKit.good)
                    } else if entry.status == "pending" {
                        Label("Agent is working…", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Text(entry.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(entry.deliveries.enumerated()), id: \.offset) { _, delivery in
                    let failed = delivery["status"].text == "failed"
                    Label((delivery["label"].text ?? "Destination") + ": " + (failed ? "not sent" : "sent") + (failed ? ", " + (delivery["message"].text ?? "try again later") : ""), systemImage: failed ? "exclamationmark.circle" : "checkmark")
                        .font(.caption).foregroundStyle(failed ? ROUTINESKit.warn : Color.secondary)
                }
                if entry.kind == "report" { Button("Ask about this report") { model.reportID = entry.id }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor) }
            }.padding(entry.kind == "question" ? 14 : 0)
                .background(entry.kind == "question" ? Color.accentColor.opacity(0.12) : .clear,
                    in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18))
            if entry.kind != "question" { Spacer(minLength: 20) }
        }
    }
}
