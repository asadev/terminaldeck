import SwiftUI
import TerminalDeckNativeCore

enum NativeChatCommands {
    static func command(in text: String) -> String? {
        guard text.hasPrefix("/"), let word = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        let name = String(word.dropFirst())
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || "-_:".contains($0) }) else { return nil }
        return name
    }
    static func resolve(_ text: String, offered: [HootSlashCommand]) throws -> HootSlashCommand? {
        guard let name = command(in: text) else { return nil }
        guard let command = offered.first(where: { $0.name == name }) else { throw NativeRPCError.invalidArguments("/\(name) is not offered by this Chat surface. Open Commands for current provider support; nothing was sent.") }
        if command.opensInApp != nil, text.trimmingCharacters(in: .whitespacesAndNewlines) != "/" + name { throw NativeRPCError.invalidArguments("/\(name) opens an app control. Choose its value there; inline arguments are not applied.") }
        return command
    }
    /// What the composer's Send does with freshly typed text: only an offered command that opens an app
    /// control (model, effort, permissions, config, account…) is handled here. Everything else, including
    /// "/tmp is full" and every queued message, goes to the provider as plain text, exactly as the
    /// sessions_chat say tool sends it (review chat-backend #1, chat-ui #2).
    static func appControl(in text: String, offered: [HootSlashCommand]) throws -> HootSlashCommand? {
        guard let name = command(in: text), let command = offered.first(where: { $0.name == name }), command.opensInApp != nil else { return nil }
        return try resolve(text, offered: offered)
    }
    static func wire(reported: NativeRPCValue, provider: String?, hoot: Bool) -> NativeRPCValue {
        .object([.init("provider", provider.map(NativeRPCValue.string) ?? .null), .init("surface", .string(hoot ? "Hoot structured Chat" : "Native session Chat")), .init("basis", .string("Current provider-reported command snapshot; no CLI/desktop parity is inferred")), .init("commands", .array((reported.elements ?? []).compactMap { row in
            guard let name = row["name"].string else { return nil }
            return .object([.init("name", .string(name)), .init("description", row["description"]), .init("dispatch", .string(HootSlashCommand.terminalOnly.contains(name) ? "unavailable-in-chat" : HootSlashCommand.appControls[name] != nil ? "app-control" : "provider-chat-command")), .init("destination", HootSlashCommand.appControls[name].map(NativeRPCValue.string) ?? .null)])
        }))])
    }
}
extension NativeHootChatModel {
    func routeSlashCommand(_ command: HootSlashCommand) {
        if ["model", "effort", "reasoning", "permissions", "approve", "config"].contains(command.name) {
            do { _ = try controlsTool("open", request: command.name) } catch { chatAccountProblem = error.localizedDescription; chatAccountVisible = true }
        } else { routeAccountCommand(command) }
    }
    func commandsTool(_ action: String, request: String?, text: String?) throws -> NativeRPCValue {
        if action == "open" { chatCommandsVisible = true }
        if action == "close" { chatCommandsVisible = false }
        if action == "prepare" {
            guard let request, let command = catalogue.commands.first(where: { $0.name == request }) else { throw NativeRPCError.invalidArguments("Choose a currently offered command from the matrix.") }
            let value = "/" + request + ((text?.isEmpty == false) ? " " + text! : "")
            _ = try NativeChatCommands.resolve(value, offered: catalogue.commands)
            if command.opensInApp != nil { routeSlashCommand(command) }
            else { guard !composerDraft.canSend else { throw NativeRPCError.invalidArguments("Keep or clear the existing draft before preparing a command.") }; try setDraftText(value) }
        }
        return NativeChatCommands.wire(reported: chatReportedCommands, provider: reportedChatProvider, hoot: source.isHoot)
    }
}
struct NativeChatCommandsPopover: View {
    @Bindable var model: NativeHootChatModel
    @State private var problem: String?
    var body: some View {
        Color.clear
            .popover(isPresented: $model.chatCommandsVisible) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Commands for this provider and Chat surface").font(.headline)
                    Text("App controls open directly. Provider commands prepare a draft; Send runs the actual provider Chat operation. Terminal-only commands are unavailable here.").font(.caption).foregroundStyle(.secondary)
                    ScrollView { LazyVStack(alignment: .leading, spacing: 10) {
                        if model.chatReportedCommands.elements?.isEmpty != false { Text("No command snapshot has been reported yet.").foregroundStyle(.secondary) }
                        ForEach(Array((model.chatReportedCommands.elements ?? []).enumerated()), id: \.offset) { _, row in
                            let name = row["name"].string ?? ""
                            VStack(alignment: .leading, spacing: 3) {
                                Text("/" + name).font(.callout.monospaced())
                                Text(row["description"].string ?? "").font(.caption)
                                if HootSlashCommand.terminalOnly.contains(name) { Text("Unavailable in Chat").font(.caption).foregroundStyle(.secondary) }
                                else { Button(HootSlashCommand.appControls[name] == nil ? "Prepare command" : "Open control") { do { _ = try model.commandsTool("prepare", request: name, text: nil); problem = nil } catch { problem = error.localizedDescription } } }
                            }
                        }
                    } }.frame(maxHeight: 350)
                    if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                }.padding(16).frame(width: 530)
            }
    }
}
