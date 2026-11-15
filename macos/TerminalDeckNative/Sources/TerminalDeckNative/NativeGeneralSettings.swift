import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Settings › General (owner, 15 Nov; DESIGN.md section 4): Sessions · This Mac · Folder · Updates. Every row without
/// its sentence (it is in the row's info button). "Terminal text size" moved here from Appearance.
struct NativeGeneralSettings: View {
    @State private var about = NativeAboutModel()
    var fixtureState: LidAwakeState? = nil
    private let store = NativeSettingsValues.shared
    static let textSizeSetting = "appearance.terminalFontSize"
    static let textSizeTitle = "Terminal text size"

    var body: some View {
        DeckSettingsScaffold(title: "General") {
            if let error = store.loadError { DeckSettingsGroup { DeckSettingsProblem(text: error) } }
            DeckSettingsGroup("Sessions") {
                DeckSettingsSchemaRow(id: "general.whenOpens", title: "When Terminal Deck opens")
                DeckSettingsSchemaRow(id: "general.restoreSessions", title: "Reopen sessions after a restart",
                                      info: "Sessions and cut-off task work carry on. Running sessions are always kept.")
                // TRUTH-B: shown on the Mac (they were compiled out): the delete-session "Don't ask again" points here.
                DeckSettingsSchemaRow(id: "general.autoNameSessions", title: "Name sessions from the conversation",
                                      info: "A tab takes the conversation’s title.")
                DeckSettingsSchemaRow(id: "general.confirmCloseWorking", title: "Confirm before closing a session",
                                      info: "Asks before a working session is closed. “Don’t ask again” turns this off; turn it back on here.")
                DeckSettingsSchemaRow(id: "general.copyOnSelect", title: "Copy on select", info: "Selecting text in a session copies it.")
                textSize
            }
            let power = fixtureState
            DeckSettingsGroup("This Mac") { NativeMacAwakeSetting(fixtureState: power) }
            // Project folders (owner, 14 Nov): where new project folders are made on this Mac. Never travels.
            DeckSettingsGroup("Folder") { NativeTerminalDeckFolderSetting(fixture: fixtureState != nil) }
            DeckSettingsGroup("Updates") {
                DeckSettingsRow("Check for updates", state: about.about?.version) {
                    Button("Check now") { about.check() }.disabled(about.about?.updates?.checkable != true)
                }
                if let checked = about.checked { DeckSettingsProblem(text: checked, warn: false) }
            }
        }
        .onAppear { if fixtureState == nil { store.start(); about.load() } }
    }

    /// The size every session's text uses (9 to 24 pt). The font itself keeps its present choice.
    private var textSize: some View {
        let size = Int(store.number(Self.textSizeSetting))
        return DeckSettingsRow(Self.textSizeTitle, state: "\(size) pt") {
            Stepper(Self.textSizeTitle, value: Binding(get: { size }, set: { store.save([Self.textSizeSetting: .number(Double($0))]) }), in: 9...24)
        }
        .disabled(store.loading && fixtureState == nil)
    }
}

/// Settings › General › "Terminal Deck folder": the folder new project folders are made in (its Projects folder), on
/// this Mac only. Changed by his own folder choice; folders already made stay where they are. While folders could not
/// be made (a full disk, a place that cannot be written) one calm line says so; it is tried again by itself.
struct NativeTerminalDeckFolderSetting: View {
    var fixture = false
    @State private var folder: String?
    @State private var problem: String?
    var body: some View {
        DeckSettingsRow("Terminal Deck folder", info: "New project folders are made in this folder on this Mac. Folders already made stay where they are.",
                        state: PROJPAGEStyle.shortPath(folder ?? (fixture ? NSHomeDirectory() + "/Terminal Deck" : "…"))) {
            Button("Change…") { choose() }.disabled(fixture)
        }
        .task { await load() }
        if let problem { DeckSettingsProblem(text: problem) }
    }
    private func load() async {
        guard !fixture, let raw = try? await EngineBridge.shared.invoke("project-folders:list", [[String: Any]()]) as? [String: Any] else { return }
        folder = raw["terminalDeckFolder"] as? String
        problem = raw["problem"] as? String
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let path = panel.url?.path else { return }
                Task { @MainActor in
                    do {
                        let raw = try await EngineBridge.shared.invoke("project-folders:set-base", [["folder": path]]) as? [String: Any]
                        folder = raw?["terminalDeckFolder"] as? String ?? path
                        problem = nil
                    } catch { problem = error.localizedDescription }
                }
            }
        }
    }
}
