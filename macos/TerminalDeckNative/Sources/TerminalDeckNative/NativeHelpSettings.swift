import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Settings → About (owner, 15 Nov: the Settings window's look): the app's name and version, then its facts as rows
/// (Licence, Build: their details in info buttons; Source, Website, Releases open their pages), then the help topics.
struct NativeHelpSettings: View {
    @State private var about = NativeAboutModel()

    var body: some View {
        DeckSettingsScaffold(title: "About") {
            NativeAboutSettings(model: about)
            DeckSettingsGroup("Help topics") {
                // lane S's HelpPanel (web: HelpPanel.tsx), without its Shortcuts and About; debug goes to Advanced.
                NativeHelpPanel(hideSections: ["shortcuts", "about"],
                                onOpenDebug: { AppModel.shared.selectSettingsSection("advanced") },
                                autoFocus: false)
                    .padding(DeckSettingsLook.rowPadding)
            }
        }
        .onAppear { about.load() }
    }
}

/// About (`AboutSection.tsx`): the masthead, then one group of facts.
struct NativeAboutSettings: View {
    let model: NativeAboutModel

    var body: some View {
        let about = model.about
        let checkable = about?.updates?.checkable ?? false
        let releases = SettingsAbout.releasesURL(about?.repository)
        VStack(spacing: DeckTokens.Spacing.s4) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage()).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
            Text(about?.name ?? model.fallbackName ?? "This app").font(.system(size: 17, weight: .semibold))
            if let about { Text("Version \(about.version)").font(DeckSettingsLook.rowTitle).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
        DeckSettingsGroup {
            if about == nil { DeckSettingsProblem(text: SettingsAbout.unreadable) }
            let tagline = (about?.tagline).flatMap { $0.isEmpty ? nil : $0 } ?? model.fallbackTagline ?? ""
            DeckSettingsRow("Licence", info: [tagline, SettingsAbout.licenceMore].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                            state: about?.license.flatMap { $0.isEmpty ? nil : $0 } ?? SettingsAbout.notRecorded)
            if let about { DeckSettingsRow("Build", info: about.buildLine + "\n\n" + SettingsAbout.buildMore) }
            if let repository = about?.repository, let url = URL(string: repository) {
                DeckSettingsLinkRow(title: "Source") { NSWorkspace.shared.open(url) }
            }
            if let homepage = about?.homepage, let url = URL(string: homepage) {
                DeckSettingsLinkRow(title: "Website") { NSWorkspace.shared.open(url) }
            }
            // One place per option (26 Oct): "Check for updates" lives in Settings › General › Updates. About keeps the
            // link and the one state line.
            if let releases, let url = URL(string: releases) {
                DeckSettingsLinkRow(title: "Releases", value: model.checked ?? SettingsAbout.updateNote(about, checkable: checkable)) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

@MainActor
@Observable
final class NativeAboutModel {
    private(set) var about: SettingsAbout?
    private(set) var fallbackName: String?
    private(set) var fallbackTagline: String?
    private(set) var checked: String?

    func load() {
        Task {
            if let raw = try? await EngineBridge.shared.invoke("settings:about", []) {
                about = SettingsAbout.parse(CodingAIJSON(raw))
            }
        }
        Task {
            if let raw = try? await EngineBridge.shared.invoke("brand:get", []) {
                let brand = CodingAIJSON(raw)
                if let name = brand["name"].string {
                    fallbackName = name
                    fallbackTagline = brand["tagline"].string ?? ""
                }
            }
        }
    }

    func check() {
        guard let updates = about?.updates else {
            checked = "This build cannot tell whether an update exists."
            return
        }
guard updates.checkable else { checked = updates.detail; return }
        checked = "Checking…"
        Task {
            do {
                let raw = CodingAIJSON(try await EngineBridge.shared.invoke("update:check"))
                let phase = raw["phase"].string ?? "idle"
                if phase == "available", let version = raw["version"].string {
                    checked = "Version \(version) is available: Download is in the side panel, just above Settings."
                } else if phase == "ready", let version = raw["version"].string {
                    checked = "Version \(version) is downloaded: Restart to update is in the side panel, just above Settings."
                } else if phase == "idle" {
                    checked = "You’re up to date."
                } else if phase == "error" || phase == "unsupported" {
                    checked = raw["message"].string ?? raw["reason"].string ?? "Could not check for updates."
                } else {
                    checked = "Update check requested."
                }
            } catch { checked = CodingAIErrorText.from(error, fallback: "Could not check for updates.") }
        }
    }
}
