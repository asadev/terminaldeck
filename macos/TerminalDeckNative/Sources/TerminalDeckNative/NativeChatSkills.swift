import SwiftUI
import TerminalDeckNativeCore

enum NativeChatSkillInvocation {
    static func command(_ skill: ROUTINESSkill, installed: [ROUTINESSkill], commands: [HootSlashCommand], current: String) throws -> String {
        guard current.isEmpty else { throw NativeRPCError.invalidArguments("Keep or send the current draft before preparing a skill command.") }
        guard skill.name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_:-]{0,79}$"#, options: .regularExpression) != nil,
              skill.clash == nil, installed.filter({ $0.name == skill.name }).count == 1,
              commands.contains(where: { $0.name == skill.name && $0.opensInApp == nil }) else {
            throw NativeRPCError(code: "unavailable", message: "This provider has not advertised an unambiguous command for this installed skill.")
        }
        return "/" + skill.name + " "
    }
}
extension NativeHootChatModel {
    func installedChatSkills() async throws -> [ROUTINESSkill] {
        let result = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("skills:list", [["installed": true]]))
        return (result["skills"].elements ?? []).compactMap(ROUTINESSkill.decode)
    }
    func prepareChatSkill(_ skill: ROUTINESSkill, installed: [ROUTINESSkill]) throws {
        guard !loading, !changingConversation else { throw NativeRPCError(code: "unavailable", message: "Wait for this chat's command catalogue.") }
        try setDraftText(NativeChatSkillInvocation.command(skill, installed: installed, commands: catalogue.commands, current: composerDraft.text))
    }
    func skillTool(_ action: String, request: String?) async throws -> NativeRPCValue {
        let installed = try await installedChatSkills()
        if action == "open" { chatSkillsVisible = true }
        if action == "close" { chatSkillsVisible = false }
        if let request {
            guard let skill = installed.first(where: { $0.id == request }) else { throw NativeRPCError.invalidArguments("Choose an installed skill ID from read.") }
            if action == "insert" { try prepareChatSkill(skill, installed: installed) }
            else if action == "read" { return try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("skills:preview", [["skill": skill.id]])) }
        } else if action == "insert" { throw NativeRPCError.invalidArguments("Name the installed skill ID.") }
        return .object([.init("skills", .array(installed.map { skill in
            let command = try? NativeChatSkillInvocation.command(skill, installed: installed, commands: catalogue.commands, current: "")
            return skill.wire.setting("advertisedCommand", command.map(NativeRPCValue.string) ?? .null).setting("providerAppliedSource", .null)
        })), .init("notice", .string("Installed source details come from Skills. Commands resolve through the current provider's catalogue; its exact applied skill path is not reported here."))])
    }
}
struct NativeChatSkillsView: View {
    let model: NativeHootChatModel
    @State private var installed: [ROUTINESSkill] = []
    @State private var query = ""
    @State private var loading = true
    @State private var problem: String?
    @State private var preview: NativeRPCValue?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Installed skills").font(.headline); Spacer(); NativeSessionButton("Manage skills") { model.chatSkillsVisible = false; AppModel.shared.select("agents-skills") } }
            NativeSessionTextField("Find installed skills", text: $query)
            Text("Prepare adds the provider's advertised command to an empty text draft. Sending resolves it through that provider; installed paths are not applied-source receipts.").font(.caption).foregroundStyle(.secondary)
            if loading { ProgressView("Reading installed skills…") }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(installed.filter { query.isEmpty || ($0.name + " " + $0.summary).localizedStandardContains(query) }) { skill in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(skill.name).font(.headline); Text(skill.summary).font(.caption)
                            Text("\(skill.source) · \(skill.folder)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            HStack {
                                NativeSessionButton("Details") { Task { do { preview = try await model.skillTool("read", request: skill.id) } catch { problem = error.localizedDescription } } }
                                if let command = try? NativeChatSkillInvocation.command(skill, installed: installed, commands: model.catalogue.commands, current: "") {
                                    NativeSessionButton("Prepare " + command.trimmingCharacters(in: .whitespaces)) { do { try model.prepareChatSkill(skill, installed: installed); problem = "Command prepared. Add instructions, then Send." } catch { problem = error.localizedDescription } }
                                        .disabled(!model.composerDraft.text.isEmpty || model.readOnly || model.loading)
                                } else { Text("No unambiguous command advertised").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if !loading && installed.isEmpty { Text("No installed skills reported.").foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 280)
            if let preview { ScrollView { Text(preview["markdown"].string ?? preview["summary"].string ?? "No instructions reported.").font(.caption.monospaced()).textSelection(.enabled) }.frame(height: 150) }
            if let problem { Text(problem).font(.caption).textSelection(.enabled) }
        }.padding(16).frame(width: 560)
            .task { defer { loading = false }; do { installed = try await model.installedChatSkills() } catch { problem = error.localizedDescription } }
    }
}
