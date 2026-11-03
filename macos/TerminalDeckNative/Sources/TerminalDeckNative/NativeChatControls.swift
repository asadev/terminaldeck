import SwiftUI
import TerminalDeckNativeCore

enum NativeChatControls {
    static func target(_ command: String) throws -> String {
        switch command {
        case "model": return "model"
        case "effort", "reasoning": return "effort"
        case "permissions", "approve": return "permissions"
        case "config": return "config"
        case "status": return "status"
        case "login", "logout": return "account"
        default: throw NativeRPCError.invalidArguments("This slash command has no supported Chat control. Use the command catalogue for supported actions.")
        }
    }
}
extension NativeHootChatModel {
    func controlsTool(_ action: String, request: String?) throws -> NativeRPCValue {
        if action == "close" { chatControlTarget = nil }
        if action == "open" {
            let target = try NativeChatControls.target(request ?? "model")
            switch target {
            case "config": if !fixtureMode { AppModel.shared.requestSettings() }
            case "account": if !fixtureMode { NativeChatAccount.openSettings(provider: reportedChatProvider) }
            case "status": chatAccountVisible = true
            default: chatControlTarget = target
            }
        }
        return .object([.init("openControl", chatControlTarget.map(NativeRPCValue.string) ?? .null), .init("model", .string(composerDraft.modelID)), .init("effort", .string(composerDraft.effort)), .init("permissionMode", .string(composerDraft.permissionMode.rawValue)), .init("mutationTool", .string("sessions_chat options; existing approval rules apply"))])
    }
}
struct NativeChatControlsPopover: View {
    @Bindable var model: NativeHootChatModel
    @State private var risky: HootPermissionMode?
    var body: some View {
        Color.clear
            .popover(isPresented: Binding(get: { model.chatControlTarget != nil }, set: { if !$0 { model.chatControlTarget = nil } })) {
                VStack(alignment: .leading, spacing: 12) {
                    let target = model.chatControlTarget ?? "model"
                    Text(target == "model" ? "Chat model" : target == "effort" ? "Reasoning effort" : "Chat permissions").font(.headline)
                    if target == "model" {
                        let models = model.catalogue.models + model.catalogue.featured + model.catalogue.more
                        let unique = models.reduce(into: [HootComposerModel]()) { result, candidate in if !result.contains(where: { $0.id == candidate.id }) { result.append(candidate) } }
                        if unique.isEmpty { Text("The provider has not reported model choices.").foregroundStyle(.secondary) }
                        ForEach(unique) { item in Button { model.changeModel(item.id) } label: { Label(item.title, systemImage: model.catalogue.isChosen(item, savedID: model.composerDraft.modelID) ? "checkmark.circle" : "circle") }.buttonStyle(.plain) }
                    } else if target == "effort" {
                        if model.catalogue.efforts.isEmpty { Text("This provider/model has not reported effort choices.").foregroundStyle(.secondary) }
                        ForEach(model.catalogue.efforts, id: \.self) { effort in Button { model.changeEffort(effort) } label: { Label(HootComposerModel.effortName(effort), systemImage: model.composerDraft.effort == effort ? "checkmark.circle" : "circle") }.buttonStyle(.plain) }
                    } else {
                        ForEach(HootPermissionMode.allCases, id: \.self) { mode in Button { if mode.risky { risky = mode } else { model.changePermission(mode) } } label: { Label(mode.fullName, systemImage: model.composerDraft.permissionMode == mode ? "checkmark.circle" : "circle") }.buttonStyle(.plain).help(mode.hint) }
                    }
                    if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red) }
                }.padding(16).frame(width: 400).disabled(model.readOnly || model.loading || model.changingConversation)
            }
            .confirmationDialog(risky?.fullName ?? "Change permissions?", isPresented: Binding(get: { risky != nil }, set: { if !$0 { risky = nil } })) {
                if let mode = risky { Button(mode.fullName) { model.changePermission(mode); risky = nil } }
                Button("Cancel", role: .cancel) { risky = nil }
            } message: { Text(risky?.hint ?? "") }
    }
}
