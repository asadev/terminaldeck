import SwiftUI
import TerminalDeckNativeCore

struct AGTProfileSkills: View {
    @Bindable var model: AGOPTProfileModel
    let giveSkills: () -> Void
    let showSkill: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Turn all skills off", isOn: $model.draft.skillsOff).toggleStyle(.switch)
                    .onChange(of: model.draft.skillsOff) { _, _ in model.changed() }
                    .disabled(model.busy || !AgentCapabilities.enforces(model.profile?.provider, .skillsOff))
                    .help(AgentCapabilities.how(model.profile?.provider, .skillsOff))
                Spacer()
                Button("Give it more skills…", action: giveSkills).buttonStyle(.bordered)
            }
            if model.skills.isEmpty {
                NativePageEmpty(symbol: "sparkles", title: "No skills yet", action: .init(label: "Give it skills…", primary: false, busy: false, perform: giveSkills)) {
                    Text("Skills teach an agent how your project does things.")
                }
            } else {
                AGOPTCard {
                    VStack(spacing: 0) {
                        ForEach(model.skills, id: \.compact) { skill in
                            let id = skill["id"].string ?? ""
                            HStack(spacing: 12) {
                                Image(systemName: "sparkles").font(.system(size: 20)).foregroundStyle(.secondary)
                                    .frame(width: 38, height: 38).background(AGOPTStyle.selection, in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(skill["name"].string ?? id).font(.body.weight(.semibold))
                                    Text(skill["source"].string ?? "Installed skill").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                // SETTINGS-TRUTH row 89: a suggestion in its task brief, not a block on an installed skill.
                                Toggle("Suggest \(skill["name"].string ?? id) in its brief", isOn: Binding(get: {
                                    model.draft.skills.contains(id)
                                }, set: { enabled in
                                    model.draft.skills.removeAll { $0 == id }
                                    if enabled { model.draft.skills.append(id) }
                                    model.changed()
                                })).labelsHidden().toggleStyle(.switch).disabled(model.draft.skillsOff || model.busy)
                                    .help("Suggest this skill in its task brief. It is a suggestion: switching it off does not stop the coding AI using a skill that is installed.")
                                Menu {
                                    Button("Show the skill") { showSkill(id) }
                                    Button("Remove from this agent", role: .destructive) {
                                        model.draft.skills.removeAll { $0 == id }; model.changed()
                                    }
                                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                                    .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
                                    .help("Actions for \(skill["name"].string ?? id)")
                            }.padding(.vertical, 10)
                        }
                    }
                }
            }
        }
    }
}
