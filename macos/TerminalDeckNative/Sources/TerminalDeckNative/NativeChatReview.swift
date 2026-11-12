import AppKit
import SwiftUI
import TerminalDeckNativeCore

struct NativeChatReviewFinding: Identifiable {
    let id: String, recordID: String, title: String, body: String
    let path: String?
    let line: Double?
    var wire: NativeRPCValue { .object([.init("id", .string(id)), .init("recordId", .string(recordID)), .init("title", .string(title)), .init("body", .string(body)), .init("path", path.map(NativeRPCValue.string) ?? .null), .init("line", line.map(NativeRPCValue.number) ?? .null)]) }
}
enum NativeChatReview {
    static func command(provider: String?, offered: Bool, scope: String, custom: String, draftEmpty: Bool) throws -> String {
        guard provider == "codex", offered else { throw NativeRPCError(code: "unavailable", message: "This chat has not advertised the native Codex review operation.") }
        guard draftEmpty else { throw NativeRPCError.invalidArguments("Keep or send your current draft before preparing a review.") }
        if scope == "uncommitted" { return "/review" }
        guard scope == "custom", !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, custom.utf8.count <= 16_384 else { throw NativeRPCError.invalidArguments("Choose uncommitted changes or provide custom review instructions (up to 16 KiB).") }
        return "/review " + custom
    }
    static func findings(_ events: [HootChatEvent]) -> [NativeChatReviewFinding] {
        let start = events.lastIndex { $0.record.kind == .user && ($0.record.value["text"].string == "/review" || $0.record.value["text"].string?.hasPrefix("/review ") == true) } ?? 0
        func collect(_ value: NativeRPCValue, depth: Int) -> [NativeRPCValue] {
            guard depth < 10 else { return [] }
            if let findings = value["findings"].elements { return findings }
            if let fields = value.fields { return fields.flatMap { collect($0.value, depth: depth + 1) } }
            if let values = value.elements { return values.flatMap { collect($0, depth: depth + 1) } }
            if let text = value.string, text.utf8.count <= 2_097_152, let decoded = try? NativeRPCValue.parseJSON(Data(text.utf8)) { return collect(decoded, depth: depth + 1) }
            return []
        }
        return events.dropFirst(start).filter { [.message, .toolResult, .completed, .session].contains($0.record.kind) }.flatMap { event in
            collect(event.record.value, depth: 0).enumerated().compactMap { index, finding in
                guard let title = finding["title"].string, !title.isEmpty else { return nil }
                let reportedLine = finding["code_location"]["line_range"]["start"].number ?? finding["line"].number
                let line = reportedLine.flatMap { $0 >= 1 && $0 < Double(Int.max) && $0.rounded(.towardZero) == $0 ? $0 : nil }
                return NativeChatReviewFinding(id: event.id + ":finding:\(index)", recordID: event.id, title: title, body: finding["body"].string ?? finding["description"].string ?? "",
                    path: finding["code_location"]["absolute_file_path"].string ?? finding["path"].string, line: line)
            }
        }
    }
}
extension NativeHootChatModel {
    func reviewTool(_ action: String, request: String?, text: String?) throws -> NativeRPCValue {
        if action == "insert" {
            guard !loading, !busy, !sending, !changingConversation else { throw NativeRPCError.invalidArguments("Wait until this chat is ready.") }
            try setDraftText(NativeChatReview.command(provider: reportedChatProvider, offered: catalogue.commands.contains { $0.name == "review" }, scope: request ?? "", custom: text ?? "", draftEmpty: !composerDraft.canSend))
        }
        let findings = chatReviewFindings
        if action == "open" || action == "reveal" {
            if let request {
                guard let finding = findings.first(where: { $0.id == request }) else { throw NativeRPCError.invalidArguments("Choose an emitted finding ID.") }
                if action == "reveal" {
                    guard let path = finding.path, path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { throw NativeRPCError(code: "missing-file", message: "This finding has no available absolute file path.") }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } else { _ = try detailTool("open", query: String(decoding: NativeRPCValue.string(finding.recordID).encodedJSON(), as: UTF8.self)); chatReviewVisible = false }
            } else if action == "open" { chatReviewVisible = true }
            else { throw NativeRPCError.invalidArguments("Choose a finding to reveal.") }
        }
        if action == "close" { chatReviewVisible = false }
        return .object([.init("supportedScopes", .array(reportedChatProvider == "codex" && catalogue.commands.contains { $0.name == "review" } ? [.string("uncommitted"), .string("custom")] : [])),
            .init("findings", .array(findings.map(\.wire))), .init("scope", .string("Structured findings emitted since the latest /review command")),
            .init("helperNeeded", .array([.string("Native base-branch and commit review targets"), .string("Forward provider review-output/findings records")]))])
    }
}
struct NativeChatReviewPanel: View {
    @Bindable var model: NativeHootChatModel
    @State private var scope = "uncommitted"
    @State private var custom = ""
    @State private var outcome: String?
    var body: some View {
        let available = model.reportedChatProvider == "codex" && model.catalogue.commands.contains { $0.name == "review" }
        let findings = NativeChatReview.findings(model.transcriptExportEvents)
        VStack(alignment: .leading, spacing: 12) {
            Text("Review changes").font(.headline)
            if available {
                Picker("Scope", selection: $scope) { Text("Uncommitted changes").tag("uncommitted"); Text("Custom instructions").tag("custom") }
                if scope == "custom" { NativeSessionTextField("What should this review examine?", text: $custom, axis: .vertical).lineLimit(3...6) }
                NativeSessionButton("Prepare review command") { do { _ = try model.reviewTool("insert", request: scope, text: custom); outcome = "Review command prepared. Send it when ready." } catch { outcome = error.localizedDescription } }
                    .disabled(model.composerDraft.canSend || model.busy || model.readOnly)
            } else { Text("This chat has not advertised the native Codex review operation.").font(.caption).foregroundStyle(.secondary) }
            Text("Native branch/base/commit targets and provider review-output records still need the helper connection. Only emitted structured findings are indexed below.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(findings) { finding in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(finding.title).font(.callout.weight(.semibold)); Text(finding.body).font(.caption).textSelection(.enabled)
                            if let path = finding.path { Text(path + (finding.line.map { ":\(Int($0))" } ?? "")).font(.caption.monospaced()).lineLimit(2) }
                            HStack {
                                NativeSessionButton("Recorded finding") { run("open", finding.id) }
                                if finding.path?.hasPrefix("/") == true { NativeSessionButton("Reveal file") { run("reveal", finding.id) } }
                            }
                        }
                    }
                    if findings.isEmpty { Text("No structured findings reported for this review.").foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 280)
            if let outcome { Text(outcome).font(.caption) }
        }.padding(16).frame(width: 570)
    }
    private func run(_ action: String, _ id: String) { do { _ = try model.reviewTool(action, request: id, text: nil) } catch { outcome = error.localizedDescription } }
}
