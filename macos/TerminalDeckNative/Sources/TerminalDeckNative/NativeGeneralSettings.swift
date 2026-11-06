import SwiftUI
import TerminalDeckNativeCore

struct NativeGeneralSettings: View {
    @State private var about = NativeAboutModel()
    var fixtureState: LidAwakeState? = nil
    var body: some View {
        if let fixtureState {
            NativeSettingsFormFrame(title: "General") {
                Form { sections(power: fixtureState) }.formStyle(.grouped).scrollContentBackground(.hidden)
            }
        } else {
            NativeSettingsPage(sectionId: "general") { sections(power: nil) }.onAppear { about.load() }
        }
    }
    @ViewBuilder private func sections(power: LidAwakeState?) -> some View {
        Section("Sessions") {
            row("general.restoreSessions", label: "Pick up where you left off", help: "Reopens projects and sessions after a restart and carries on cut-off task work. Sessions that kept running are always kept.")
            // TRUTH-B: shown on the Mac (they were compiled out): the delete-session "Don't ask again" points here.
            row("general.autoNameSessions", label: "Name sessions from the conversation", help: "A tab takes the conversation’s title.")
            row("general.confirmCloseWorking", label: "Confirm before closing a session", help: "Asks before a working session is closed. “Don’t ask again” turns this off; turn it back on here.")
            row("general.copyOnSelect", label: "Copy on select", help: "Selecting text in a session copies it.")
        }
        Section("Mac") { NativeMacAwakeSetting(fixtureState: power) }
        Section("Updates") {
            NativeSettingRow(label: "Check for updates") {
                HStack {
                    if let version = about.about?.version { Text(version).foregroundStyle(.secondary) }
                    Button("Check for updates") { about.check() }
                        .disabled(about.about?.updates?.checkable != true)
                }
            }
            if let checked = about.checked { Text(checked).font(.callout).foregroundStyle(.secondary).lineLimit(1).help(checked) }
        }
    }
    @ViewBuilder private func row(_ id: String, label: String, help: String) -> some View {
        if let definition = definition(id, label: label, help: help) {
            NativeSettingControl(setting: definition)
        }
    }
    private func definition(_ id: String, label: String, help: String) -> SettingDefinition? {
        guard var definition = SettingsSchema.setting(id) else { return nil }
        definition.label = label; definition.help = help
        return definition
    }

}
