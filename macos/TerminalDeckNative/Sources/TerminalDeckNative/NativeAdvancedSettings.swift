import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Settings → Advanced (`AdvancedSection.tsx`): Debug mode and the log folder;
/// with debug mode on, the stored values, the diagnostics and the files on disk;
/// and Start over, which resets every setting after asking.
/// Owner, 15 Nov (DESIGN.md section 4): Debug mode (i) · Open logs (the folder is in the info popover) · Access after lock
/// or restart › · Remove old Terminal Deck entries (moved here from Privacy) · Reset all settings (red, (i)). With debug
/// mode on, the stored values, the diagnostics and the files on disk follow as before.
struct NativeAdvancedSettings: View {
    @State private var model = NativeAdvancedModel()
    /// Owner, 14 Nov: "Access after lock or restart" left the Devices page; its content opens from this one row.
    @State private var accessOpen = false
    @State private var cleanupOpen = false
    static let accessTitle = "Access after lock or restart"
    static let cleanupTitle = "Remove old Terminal Deck entries"
    static let resetInfo = "Every setting goes back to its default. Projects, sessions and accounts are kept."
    private let store = NativeSettingsValues.shared

    var body: some View {
        let debug = store.bool("advanced.debugMode")
        let logs = model.paths?.first { $0.key == "logs" }
        let files = model.paths?.filter { $0.key != "logs" } ?? []
        DeckSettingsScaffold(title: "Advanced") {
            DeckSettingsGroup {
                DeckSettingsSchemaRow(id: "advanced.debugMode", title: "Debug mode", info: "Turn on only when asked. It adds the stored values, the diagnostics and the files on disk to this page.")
                DeckSettingsRow("Logs", info: logs.map { "The log folder: " + $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                    + ($0.exists ? "" : ". Nothing has been written there yet; opening it creates it.") }) {
                    Button("Open") { model.open("logs") }.controlSize(.small)
                }
                DeckSettingsLinkRow(title: Self.accessTitle) { accessOpen = true }
                DeckSettingsRow(Self.cleanupTitle, info: "Privacy lists may still show TerminalDeckNativeHelper from older versions. Sessions now use Terminal Deck’s entry, so those can go. Nothing is reset: old bare helpers need the minus button in that list; a reset would not reliably remove their rows.") {
                    Button(cleanupOpen ? "Hide steps" : "Show steps") { cleanupOpen.toggle() }.controlSize(.small)
                }
                if cleanupOpen { NativePrivacyCleanupSteps().padding(DeckSettingsLook.rowPadding) }
            }
            DeckSettingsGroup {
                if model.confirmReset {
                    DeckSettingsRow("Reset every setting to its default?") {
                        HStack(spacing: DeckTokens.Spacing.s8) {
                            Button("Cancel") { model.confirmReset = false }
                            Button("Reset everything", role: .destructive) { model.reset() }.disabled(model.resetting)
                        }
                    }
                } else {
                    DeckSettingsButtonRow(title: "Reset all settings", role: .destructive, info: Self.resetInfo) { model.confirmReset = true }
                        .disabled(model.resetting)
                }
                if let status = model.status { DeckSettingsProblem(text: status, warn: false) }
            }
            if debug {
                // FINAL-CONNECT (SETTINGS-TRUTH row 32): the saved files' own contents, nothing added.
                DeckSettingsGroup("Stored values", info: "Exactly what is saved: settings, then preferences. A setting never changed is not in them and uses its default.") {
                    Text(model.stored ?? "Reading…")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DeckSettingsLook.rowPadding)
                        .task { await model.readStored() }
                }
                DeckSettingsGroup("Diagnostics") {
                    NativeDebugPanel().padding(DeckSettingsLook.rowPadding) // lane T (web: DebugPanel.tsx)
                }
                DeckSettingsGroup("Files on disk", info: "For a bug report. Everything in them is changed in the app, not here.") {
                    if files.isEmpty {
                        DeckSettingsProblem(text: "No config files have been reported yet.", warn: false)
                    } else {
                        ForEach(files) { entry in pathRow(entry).padding(DeckSettingsLook.rowPadding) }
                    }
                }
            }
        }
        .onAppear { store.start(); model.readPaths() }
        .sheet(isPresented: $accessOpen) {
            VStack(spacing: 0) {
                Form { NativeMacReachSettings(fixture: false) }.formStyle(.grouped)
                HStack { Spacer(); Button("Done") { accessOpen = false }.keyboardShortcut(.defaultAction) }.padding(16)
            }
            .frame(width: 600, height: 520)
        }
    }

    private func pathRow(_ entry: SettingsConfigPath) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.label)
                    if !entry.exists { NativeCodingAIBadge(text: "not created yet", quiet: true) }
                }
                Text(entry.purpose).font(DeckSettingsLook.rowSecond).foregroundStyle(.secondary)
                NativeCodingAICommand(text: entry.path)
            }
            Spacer(minLength: 8)
            Button("Copy") { model.copy(entry.path) }
                .help("Copy this path to the clipboard")
            if entry.isFolder {
                Button("Open") { model.open(entry.key) }
                    .help("Open this folder in your file manager")
            } else {
                Button("Reveal") { model.open(entry.key) }
                    .disabled(!entry.exists)
                    .help(entry.exists ? "Show this file in your file manager" : "")
            }
        }
    }
}

@MainActor
@Observable
final class NativeAdvancedModel {
    private(set) var paths: [SettingsConfigPath]?
    /// The saved settings and preferences as stored, with no defaults merged in.
    private(set) var stored: String?
    func readStored() async {
        let settings = (try? await EngineBridge.shared.invoke("settings:get", [])) ?? [:]
        let prefs = (try? await EngineBridge.shared.invoke("prefs:get", [])) ?? [:]
        let saved = (settings as? [String: Any])?["values"] ?? settings
        let object: [String: Any] = ["settings": saved, "preferences": prefs]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { stored = "{}"; return }
        stored = String(decoding: data, as: UTF8.self)
    }
    private(set) var status: String?
    var confirmReset = false
    private(set) var resetting = false

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    func readPaths() {
        Task {
            do {
                paths = SettingsConfigPath.parse(try await call("settings:paths"))
            } catch {
                status = CodingAIErrorText.from(error, fallback: "Could not read where the files live.")
            }
        }
    }

    func open(_ key: String) {
        Task {
            do {
                status = SettingsConfigPath.openMessage(try await call("settings:open-path", [key]))
            } catch {
                status = CodingAIErrorText.from(error, fallback: "Could not open that.")
            }
        }
    }

    func copy(_ path: String) {
        NSPasteboard.general.clearContents()
        status = NSPasteboard.general.setString(path, forType: .string) ? "Path copied." : "Could not copy that."
    }

    /// The settings file back to its defaults, then the preferences, then everything read again.
    func reset() {
        confirmReset = false
        resetting = true
        Task {
            var settingsReset = false
            do {
                _ = try await call("settings:reset")
                settingsReset = true
                _ = try await call("prefs:set", [SettingsSchema.defaultPreferences.mapValues(\.foundation)])
                status = "Everything is back to its default."
            } catch {
                status = Self.resetProblem(error, settingsReset: settingsReset)
            }
            resetting = false
            // Read back, and hand the main window what is now stored.
            async let prefs = try? call("prefs:get")
            async let extra = try? call("settings:get")
            let (prefsValue, extraValue) = await (prefs, extra)
            NativeSettingsValues.shared.handBack(SettingsSchema.values(settings: extraValue ?? .null, preferences: prefsValue ?? .null))
            NativeSettingsValues.shared.load()
        }
    }

    /// Says which half of the reset went through: after the settings file is reset, "nothing may have changed" is untrue.
    static func resetProblem(_ error: Error, settingsReset: Bool) -> String {
        guard settingsReset else { return CodingAIErrorText.from(error, fallback: "Could not reset everything — nothing may have changed.") }
        return "Your settings are back to their defaults, but your preferences were not reset ("
            + CodingAIErrorText.from(error, fallback: "no answer") + "). Reset again to finish."
    }

}
