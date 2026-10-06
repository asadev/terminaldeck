import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Settings → Advanced (`AdvancedSection.tsx`): Debug mode and the log folder;
/// with debug mode on, the stored values, the diagnostics and the files on disk;
/// and Start over, which resets every setting after asking.
struct NativeAdvancedSettings: View {
    @State private var model = NativeAdvancedModel()
    private let store = NativeSettingsValues.shared

    var body: some View {
        let debug = store.bool("advanced.debugMode")
        let logs = model.paths?.first { $0.key == "logs" }
        let files = model.paths?.filter { $0.key != "logs" } ?? []
        NativeSettingsPage(sectionId: "advanced") {
            Section("When something goes wrong") {
                NativeSettingsList(section: "advanced")
                HStack(spacing: 8) {
                    Button("Open the log folder") { model.open("logs") }
                    if let logs { NativeCodingAICommand(text: logs.path) }
                }
                if let logs, !logs.exists {
                    NativeCodingAINotice(tone: .info, text: "Nothing has been written there yet. Opening it creates the folder.")
                }
            }

            if debug {
                Section("Stored values") {
                    Text("Exactly what is on disk.")
                        .foregroundStyle(.secondary)
                        .help("Includes keys written by other versions of the app.")
                    Text(NativeAdvancedModel.pretty(store.values))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section("Diagnostics") {
                    NativeDebugPanel(enabled: true) // lane T (web: DebugPanel.tsx)
                }
                Section("Files on disk") {
                    NativeSettingsProse(text: "For a bug report. Everything in them is changed in the app, not here.")
                    if files.isEmpty {
                        NativeSettingsProse(text: "No config files have been reported yet.")
                    } else {
                        ForEach(files) { entry in pathRow(entry) }
                    }
                }
            }

            Section("Start over") {
                NativeSettingsProse(text: "Every setting in this window goes back to its default. Projects, sessions and accounts are untouched.")
                if model.confirmReset {
                    HStack(spacing: 8) {
                        Text("Reset every setting to its default?")
                        Button("Reset everything", role: .destructive) { model.reset() }
                            .disabled(model.resetting)
                        Button("Cancel") { model.confirmReset = false }
                    }
                } else {
                    Button("Reset all settings", role: .destructive) { model.confirmReset = true }
                        .disabled(model.resetting)
                }
            }

            if let status = model.status {
                Section { NativeCodingAINotice(tone: .info, text: status) }
            }
        }
        .onAppear { model.readPaths() }
    }

    private func pathRow(_ entry: SettingsConfigPath) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.label)
                    if !entry.exists { NativeCodingAIBadge(text: "not created yet", quiet: true) }
                }
                Text(entry.purpose).font(.callout).foregroundStyle(.secondary)
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
            do {
                _ = try await call("settings:reset")
                _ = try await call("prefs:set", [SettingsSchema.defaultPreferences.mapValues(\.foundation)])
                status = "Everything is back to its default."
            } catch {
                status = CodingAIErrorText.from(error, fallback: "Could not reset everything — nothing may have changed.")
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

    static func pretty(_ values: [String: CodingAIJSON]) -> String {
        let object = values.mapValues(\.foundation)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
