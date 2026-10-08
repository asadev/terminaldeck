import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TerminalDeckNativeCore

@MainActor @Observable final class NativeHootChatModel {
    static let shared = NativeHootChatModel()
    private(set) var rows: [HootChatRow] = []
    private(set) var pending: [NativeRPCValue] = []
    private(set) var busy = false
    private(set) var sending = false
    private(set) var loading = true
    private(set) var problem: String?
    var draft = ""
    var attachments: [(name: String, value: NativeRPCValue)] = []
    @ObservationIgnored private var subscription: EngineSubscription?
    @ObservationIgnored private var sequence = -1
    @ObservationIgnored private var conversationID = ""
    func start() async {
        if subscription == nil {
            subscription = EngineBridge.shared.on("hoot:chat:changed") { [weak self] values in
                if let value = values.first { self?.accept(value) }
            }
        }
        do { accept(try await EngineBridge.shared.invoke("hoot:chat:read", [NSNull(), 500])) }
        catch { problem = error.localizedDescription; loading = false }
    }
    private func accept(_ raw: Any) {
        do {
            let value = try NativeRPCValue.fromFoundation(raw)
            let id = value["conversationId"].string ?? "", next = Int(value["sequence"].number ?? 0)
            guard conversationID != id || next >= sequence else { return }
            conversationID = id; sequence = next
            let events = try (value["events"].elements ?? []).map(HootChatEvent.init(wire:))
            rows = HootChatProjection.rows(events).filter { $0.kind != .approval }
            pending = value["pending"].elements ?? []; busy = value["busy"].bool == true
            problem = value["problem"].string; loading = false
        } catch { problem = error.localizedDescription; loading = false }
    }
    func send() {
        guard !busy, !sending else { return }
        let text = draft, blocks = attachments
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !blocks.isEmpty else { return }
        sending = true; problem = nil; draft = ""; attachments = []
        Task {
            defer { sending = false }
            do {
                accept(try await EngineBridge.shared.invoke("hoot:chat:say", [text, blocks.map { $0.value.foundation ?? NSNull() }]))
                NativeHootModel.shared.refresh()
            } catch {
                problem = error.localizedDescription
                if draft.isEmpty { draft = text; attachments = blocks }
            }
        }
    }
    func stop() {
        Task {
            do { accept(try await EngineBridge.shared.invoke("hoot:chat:stop")); NativeHootModel.shared.refresh() }
            catch { problem = error.localizedDescription }
        }
    }
    func answer(_ id: String, allowed: Bool) {
        Task {
            do { accept(try await EngineBridge.shared.invoke("hoot:chat:answer", [id, allowed])) }
            catch { problem = error.localizedDescription }
        }
    }
    func attach() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .pdf]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    guard attachments.count < 4 else { throw NativeRPCError.invalidArguments("Attach up to four files.") }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    guard data.count <= 500_000 else { throw NativeRPCError.invalidArguments("Use a file smaller than 500 KB.") }
                    let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "pdf": "application/pdf"]
                    guard let media = types[url.pathExtension.lowercased()] else { throw NativeRPCError.invalidArguments("Choose an image or PDF.") }
                    let block = NativeRPCValue.object([.init("type", .string(media == "application/pdf" ? "document" : "image")),
                        .init("source", .object([.init("type", .string("base64")), .init("media_type", .string(media)), .init("data", .string(data.base64EncodedString()))]))])
                    attachments.append((url.lastPathComponent, block))
                } catch { problem = error.localizedDescription }
            }
        }
    }
}

struct NativeHootChat: View {
    @State private var model = NativeHootChatModel.shared
    var compact = false
    var body: some View {
        VStack(spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if model.loading { ProgressView("Loading Hoot…").frame(maxWidth: .infinity) }
                        else if model.rows.isEmpty {
                            Text("Ask Hoot about your sessions, a plan, or a review.").foregroundStyle(.secondary).padding(.vertical, 24)
                        }
                        ForEach(model.rows) { row in chatRow(row) }
                        if model.busy || model.sending { ProgressView(model.pending.isEmpty ? "Hoot is working…" : "Hoot is waiting for you").controlSize(.small) }
                        Color.clear.frame(height: 1).id("hoot-end")
                    }.padding(compact ? 12 : 20)
                }
                .onChange(of: model.rows) { _, _ in proxy.scrollTo("hoot-end", anchor: .bottom) }
            }
            if let problem = model.problem { Text(problem).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal) }
            ForEach(model.pending, id: \.compact) { request in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hoot is waiting for you").font(.headline)
                    Text(request["name"].string ?? request["subtype"].string ?? "Permission")
                    DisclosureGroup("Details") { Text(request["input"].compact).font(.caption.monospaced()).textSelection(.enabled) }
                    HStack {
                        Button("Deny") { model.answer(request["requestId"].string ?? "", allowed: false) }
                        Button("Approve") { model.answer(request["requestId"].string ?? "", allowed: true) }.buttonStyle(.borderedProminent)
                    }
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(model.attachments.enumerated()), id: \.offset) { index, attachment in
                    HStack { Image(systemName: "paperclip"); Text(attachment.name).lineLimit(1); Button("Remove", systemImage: "xmark") { model.attachments.remove(at: index) }.labelStyle(.iconOnly) }.font(.caption)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    Button("Attach", systemImage: "paperclip") { model.attach() }.labelStyle(.iconOnly).disabled(model.busy || model.sending)
                    TextField("Message Hoot", text: $model.draft, axis: .vertical).lineLimit(1...5).textFieldStyle(.plain)
                        .onSubmit { model.send() }.disabled(model.sending)
                    if model.busy || model.sending { Button("Stop", systemImage: "stop.fill") { model.stop() }.labelStyle(.iconOnly) }
                    else { Button("Send", systemImage: "arrow.up") { model.send() }.labelStyle(.iconOnly).buttonStyle(.borderedProminent)
                        .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachments.isEmpty) }
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
            }.padding(.horizontal, compact ? 12 : 20).padding(.bottom, 12)
        }.task { await model.start() }
    }
    @ViewBuilder private func chatRow(_ row: HootChatRow) -> some View {
        if row.kind == .toolCall {
            DisclosureGroup {
                Text(row.value["input"].compact).font(.caption.monospaced()).textSelection(.enabled)
                if row.value.has("output") { Text(row.value["output"].string ?? row.value["output"].compact).font(.caption.monospaced()).textSelection(.enabled) }
            } label: {
                Label(row.value["name"].string ?? "Tool", systemImage: row.value["finished"].bool == true ? "checkmark.circle" : "gearshape")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.kind == .user ? "You" : row.kind == .error ? "Error" : "Hoot").font(.caption).foregroundStyle(.secondary)
                Text(row.value["text"].string ?? (row.kind == .interrupted ? "Stopped." : "")).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if let count = row.value["attachmentCount"].number, count > 0 { Text("\(Int(count)) attachment(s)").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
