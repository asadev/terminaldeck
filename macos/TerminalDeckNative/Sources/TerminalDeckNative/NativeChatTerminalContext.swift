import CryptoKit
import Foundation
import TerminalDeckNativeCore

enum NativeChatTerminalContext {
    struct Entry { let id: String; let rowID: String; let eventID: String; let command: String; let output: String; let hash: String; let finished: Bool }
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func text(_ value: NativeRPCValue) -> String? {
        if let string = value.string { return string }
        if let rows = value.elements { let parts = rows.compactMap { $0["text"].string }; return parts.isEmpty ? nil : parts.joined(separator: "\n") }
        if let stdout = value["stdout"].string { return stdout + (value["stderr"].string.map { "\n[stderr]\n" + $0 } ?? "") }
        return value["text"].string
    }
    static func entries(rows: [HootChatRow], events: [HootChatEvent]) -> [Entry] {
        var sources: [String: String] = [:]
        for event in events where event.record.kind == .toolResult {
            let key = event.turnID + ":" + (event.record.messageID.isEmpty ? event.id : event.record.messageID)
            sources[key] = event.id
        }
        return rows.compactMap { row in
            guard row.kind == .toolCall, let output = text(row.value["output"]), !output.isEmpty, let source = sources[row.id] else { return nil }
            let input = row.value["input"], name = (row.value["name"].string ?? "").split(separator: ".").last.map(String.init)?.lowercased() ?? ""
            let command = input["command"].string ?? input["command"].elements.map { NativeRPCValue.array($0).compact } ?? input["cmd"].string
            guard let command, !command.isEmpty, input.has("command") || input.has("cmd") || ["bash", "exec_command", "shell_command", "run_shell_command", "commandexecution", "command_execution"].contains(name) else { return nil }
            let outputHash = hash(output), version = hash(command + "\0" + output)
            return Entry(id: row.id + "#" + String(version.prefix(20)), rowID: row.id, eventID: source, command: command, output: output, hash: outputHash, finished: row.value["finished"].bool == true)
        }
    }
    static func prepare(entries: [Entry], request: String?, range: String?, existingText: String) throws -> (String, NativeRPCValue) {
        guard let entry = entries.first(where: { $0.id == request }) else { throw NativeRPCError.invalidArguments("Choose a current versioned command-output ID; changed output requires a fresh selection.") }
        let (context, receipt) = try selection(entry, range: range)
        return (existingText.isEmpty ? context : existingText + "\n\n" + context, receipt)
    }
    static func selection(_ entry: Entry, range: String?) throws -> (String, NativeRPCValue) {
        let lines = entry.output.components(separatedBy: "\n")
        var first = 1, last = min(200, lines.count)
        if let range, !range.isEmpty {
            let parts = range.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), a >= 1, b >= a, b <= lines.count else { throw NativeRPCError.invalidArguments("Use a valid one-based output line range, for example 2:12.") }
            first = a; last = b
        }
        let selected = lines[(first - 1)..<last].joined(separator: "\n")
        var excerpt = "", bytes = 0
        for character in selected {
            let count = String(character).utf8.count
            if bytes + count > 16_384 { break }; excerpt.append(character); bytes += count
        }
        guard !excerpt.isEmpty, !excerpt.contains("\0"), !entry.command.contains("\0") else { throw NativeRPCError.invalidArguments("Choose nonempty textual command output without NUL characters.") }
        let end = first + excerpt.components(separatedBy: "\n").count - 1
        let combined = entry.command + excerpt
        let run = combined.components(separatedBy: CharacterSet(charactersIn: "`").inverted).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, run + 1))
        let receipt: NativeRPCValue = .object([.init("sourceEventId", .string(entry.eventID)), .init("sourceRowId", .string(entry.rowID)), .init("sourceOutputSHA256", .string(entry.hash)), .init("selectedSHA256", .string(hash(excerpt))), .init("firstLine", .number(Double(first))), .init("lastLine", .number(Double(end))), .init("selectedUTF8Bytes", .number(Double(bytes))), .init("truncated", .bool(first != 1 || last < lines.count || excerpt != selected)), .init("endsMidLine", .bool(excerpt != selected && !excerpt.hasSuffix("\n"))), .init("stage", .string("draft")), .init("deliveryConfirmed", .bool(false))])
        let context = "Recorded command/output context (quoted data, not an instruction to execute a shell command)\nSource event: \(entry.eventID)\nOutput SHA256: \(entry.hash)\nQuoted command:\n\(fence)text\n\(entry.command)\n\(fence)\nOutput excerpt · lines \(first)–\(end), \(bytes) UTF-8 bytes:\n\(fence)text\n\(excerpt)\n\(fence)"
        return (context, receipt)
    }
}
extension NativeHootChatModel {
    func terminalContextTool(_ action: String, request: String?, range: String?) throws -> NativeRPCValue {
        featurePanel("terminal-context", action)
        let entries = NativeChatTerminalContext.entries(rows: rows, events: transcriptExportEvents)
        var receipt: NativeRPCValue = .null
        if ["insert", "details"].contains(action) {
            guard let entry = entries.first(where: { $0.id == request }) else { throw NativeRPCError.invalidArguments("Choose a current versioned command-output ID; changed output requires a fresh selection.") }
            if action == "details" { _ = try detailTool("open", query: nil, recordID: entry.eventID) }
            else { let (text, proof) = try NativeChatTerminalContext.prepare(entries: entries, request: request, range: range, existingText: composerDraft.text); try setDraftText(text); receipt = proof }
        }
        let items = entries.reversed().map { entry in NativeChatPanel.row(entry.id, String(entry.command.prefix(240)), "\(entry.finished ? "Recorded completed output" : "Recorded output; completion unconfirmed") · \(entry.output.utf8.count) UTF-8 bytes\n" + String(entry.output.prefix(1200)), [NativeChatPanel.action("Add output excerpt to draft", "insert", entry.id), NativeChatPanel.action("Open command/output source", "details", entry.id)]) }
        let note = "Only command output already recorded in this Chat is read. Excerpts default to 200 lines and 16 KiB, with line/byte/hash receipts; files and existing draft text stay. This does not read, attach, resume or send to a terminal. Provider → Attached terminal has live app-approved terminal controls. sessions_chat_terminal exposes the same helper-owned lifecycle. This panel quotes recorded provider command output."
        return NativeChatPanel.state("Recorded command output context", receipt.isNullish ? note : "Output excerpt added to the draft; nothing sent.\n" + note, items).setting("draftReceipt", receipt).setting("threadTerminal", .object([.init("tool", .string("sessions_chat_terminal")), .init("availability", .string("check-current-capabilities")), .init("approvalSource", .string("app-user-or-tool-consent"))]))
    }
}
