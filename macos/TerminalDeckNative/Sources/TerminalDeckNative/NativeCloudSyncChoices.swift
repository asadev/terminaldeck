import Foundation
import Observation
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Settings › Cloud › "Keep in sync on this Mac" (owner, 15 Nov): one switch per kind, all on by default, kept on this
/// device only (`CloudSyncChoices`). A switch takes effect at once: the Cloud parts of this device are stopped and
/// started again with the kinds that are on (`NativeCloudBrainRegistration.choicesChanged`). Saved passwords stop at
/// once and join again at the next start of Cloud here; Code backup's automatic backups stop and start at once.
@MainActor @Observable
final class NativeCloudSyncChoices {
    static let shared = NativeCloudSyncChoices()
    private(set) var choices = CloudSyncChoices()
    /// The app's data folder, once Cloud was set up in this run (nil: the list is shown all on and changes nothing).
    @ObservationIgnored private(set) var dataRoot: URL?
    /// Seals this identity's saved passwords (set by the account assembly while they are wired).
    @ObservationIgnored var sealSecrets: (@Sendable () async -> Void)?

    nonisolated static func file(dataRoot: URL) -> URL { CloudSyncChoices.file(cloudFolder: NativeCloudLaunch.folder(dataRoot)) }
    nonisolated static func load(dataRoot: URL) -> CloudSyncChoices { CloudSyncChoices.load(file(dataRoot: dataRoot)) }
    nonisolated static func isOn(_ kind: CloudSyncKind, dataRoot: URL) -> Bool { load(dataRoot: dataRoot).isOn(kind) }

    func use(dataRoot: URL) {
        self.dataRoot = dataRoot
        let loaded = Self.load(dataRoot: dataRoot)
        if loaded != choices { choices = loaded }
    }
    func isOn(_ kind: CloudSyncKind) -> Bool { choices.isOn(kind) }
    /// His press. Saved first; nothing is deleted on any device, either way.
    func set(_ kind: CloudSyncKind, on: Bool) {
        guard kind.exists, choices.isOn(kind) != on else { return }
        let next = choices.setting(kind, on: on)
        if let dataRoot { try? next.save(Self.file(dataRoot: dataRoot)) }
        choices = next
        NativeCloudAccount.log("cloud choices: " + kind.rawValue + (on ? " on" : " off") + " on this Mac")
        switch kind {
        case .secrets:
            if !on, let seal = sealSecrets { sealSecrets = nil; Task { await seal() } }
        case .codeBackup:
            Task {
                guard let actions = await BackendCodeBackupHolder.shared.actions else { return }
                if on { await actions.start() } else { await actions.stop() }
            }
        case .sessions: break
        default: NativeCloudBrainRegistration.choicesChanged()
        }
    }
}

/// The one compact list (owner, 15 Nov; DESIGN.md section 3): "Keep in sync on this Mac", "Use Cloud on this Mac" first
/// (when given), then a switch per kind in his words with its count right after the name ("3,176 notes", never "All
/// saved ·"). The kinds are off while Cloud is off here.
struct NativeCloudSyncChoicesSection: View {
    var model = NativeCloudSyncChoices.shared
    let cloudOn: Bool
    var useCloud: Binding<Bool>? = nil
    var counts: BackendCloudPageCounts? = NativeCloudPageCounts.shared.counts
    var body: some View {
        DeckSettingsGroup(CloudSyncChoices.title) {
            if let useCloud {
                DeckSettingsToggleRow(NativeCloudSettings.useCloudToggle, info: NativeCloudSettings.useCloudNote, isOn: useCloud)
            }
            ForEach(CloudSyncKind.shown, id: \.self) { kind in
                // The same guarded page press as the page's other Cloud switches (never taken from remote control).
                DeckSettingsToggleRow(kind.title, note: Self.count(kind, counts), isOn: Binding(get: { model.isOn(kind) }, set: { on in
                    NativeCloudSheetGuard.shared.pagePress { model.set(kind, on: on) }
                }))
                .disabled(!cloudOn)
            }
        }
    }
    /// The count beside a kind's name, from what is really on this Mac now (nil while not known).
    static func count(_ kind: CloudSyncKind, _ counts: BackendCloudPageCounts?) -> String? {
        guard let here = counts?.here else { return nil }
        let unit: (BackendCloudPageCounts.Unit, String, String)?
        switch kind {
        case .memory: unit = (.notes, "note", "notes")
        case .projects: unit = (.projects, "project", "projects")
        case .agents: unit = (.agents, "agent", "agents")
        case .instructionFiles: unit = (.instructionFiles, "file", "files")
        case .tasks: unit = (.tasks, "task", "tasks")
        case .settings: unit = (.appSettings, "setting", "settings")
        case .cloudFolder: unit = (.cloudFolder, "file", "files")
        case .artifacts: unit = (.artifacts, "artifact", "artifacts")
        default: unit = nil
        }
        guard let unit, let n = here[unit.0] else { return nil }
        return BackendCloudPageCounts.number(n) + " " + (n == 1 ? unit.1 : unit.2)
    }
}
