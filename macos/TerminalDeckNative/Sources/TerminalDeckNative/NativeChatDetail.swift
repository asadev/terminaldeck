import SwiftUI
import TerminalDeckNativeCore

extension NativeHootChatModel {
    func detailRecords(_ query: String) -> [HootChatEvent] {
        chatDetailRecords.filter { query.isEmpty || $0.text.localizedStandardContains(query) }.map(\.event)
    }
    func detailTool(_ action: String, query: String? = nil, recordID: String? = nil) throws -> NativeRPCValue {
        if let query { chatDetailQuery = query; chatDetailIndex = 0 }
        if action == "open" { chatDetailsVisible = true }
        if action == "close" { chatDetailsVisible = false }
        let records = detailRecords(chatDetailQuery)
        if !records.isEmpty {
            if action == "next" { chatDetailIndex = (chatDetailIndex + 1) % records.count }
            if action == "previous" { chatDetailIndex = (chatDetailIndex + records.count - 1) % records.count }
        }
        chatDetailIndex = min(chatDetailIndex, max(0, records.count - 1))
        let selected: HootChatEvent?
        if let recordID {
            guard let record = transcriptExportEvents.first(where: { $0.id == recordID }) else { throw NativeRPCError.invalidArguments("Choose an emitted event ID.") }; selected = record
        } else { selected = records.indices.contains(chatDetailIndex) ? records[chatDetailIndex] : nil }
        if action == "copy" {
            guard let selected else { throw NativeRPCError.invalidArguments("Choose a recorded event to copy.") }; DeckProject.copy(NativeChatDetail.text(selected))
        }
        return .object([.init("mode", .string(chatDetailsVisible ? "events" : "normal")), .init("available", .array([.string("normal"), .string("events")])),
            .init("scope", .string("App-recorded provider-neutral events; no unreported reasoning or provider raw stream")),
            .init("total", .number(Double(transcriptExportEvents.count))), .init("matches", .number(Double(records.count))),
            .init("selected", selected.map { .object([.init("id", .string($0.id)), .init("text", .string(NativeChatDetail.text($0)))]) } ?? .null)])
    }
}
enum NativeChatDetail {
    static func text(_ event: HootChatEvent) -> String {
        (try? String(decoding: event.wireValue.encodedJSON(pretty: true), as: UTF8.self)) ?? "Event could not be encoded."
    }
}
struct NativeChatDetailView: View {
    @Bindable var model: NativeHootChatModel
    @State private var outcome: String?
    var body: some View {
        let records = model.detailRecords(model.chatDetailQuery)
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Recorded transcript details").font(.headline); Spacer(); NativeSessionButton("Normal conversation") { model.chatDetailsVisible = false } }
            Text("Only app-recorded events, tool values and emitted metadata are available. Provider records outside this journal are not shown.").font(.caption).foregroundStyle(.secondary)
            HStack {
                NativeSessionTextField("Find in recorded events", text: $model.chatDetailQuery).onChange(of: model.chatDetailQuery) { _, _ in model.chatDetailIndex = 0 }
                Text("\(records.count) records").font(.caption).monospacedDigit()
                NativeSessionButton { _ = try? model.detailTool("previous") } label: { Image(systemName: "chevron.up") }.help("Previous matching record").disabled(records.isEmpty)
                NativeSessionButton { _ = try? model.detailTool("next") } label: { Image(systemName: "chevron.down") }.help("Next matching record").disabled(records.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(records) { record in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { Text("\(record.sequence) · \(record.record.kind.rawValue) · \(record.provider.rawValue)").font(.caption).foregroundStyle(.secondary); Spacer(); NativeSessionButton("Copy") { do { _ = try model.detailTool("copy", recordID: record.id); outcome = "Record copied." } catch { outcome = error.localizedDescription } } }
                                Text(NativeChatFindText.highlight(AttributedString(model.chatDetailText(record)), query: model.chatDetailQuery))
                                    .font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(10).background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 8)).id(record.id)
                        }
                    }
                }.frame(height: 400)
                    .onChange(of: model.chatDetailIndex) { _, index in if records.indices.contains(index) { proxy.scrollTo(records[index].id, anchor: .top) } }
            }
            if let outcome { Text(outcome).font(.caption) }
        }.padding(16).frame(width: 620)
    }
}
