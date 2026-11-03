import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Settings → Help (`HelpSection.tsx`): About at the top — what this app is,
/// its version, licence, source, build line and updates — then "How it works".
struct NativeHelpSettings: View {
    @State private var about = NativeAboutModel()

    var body: some View {
        NativeSettingsPage(sectionId: "help") {
            NativeAboutSettings(model: about)
            Section("Help topics") {
                // lane S's HelpPanel (web: HelpPanel.tsx), without its Shortcuts and About; debug goes to Advanced.
                NativeHelpPanel(hideSections: ["shortcuts", "about"],
                                onOpenDebug: { AppModel.shared.selectSettingsSection("advanced") },
                                autoFocus: false)
            }
        }
        .onAppear { about.load() }
    }
}

/// About (`AboutSection.tsx`), the masthead at the top of Help.
struct NativeAboutSettings: View {
    let model: NativeAboutModel

    var body: some View {
        let about = model.about
        let checkable = about?.updates?.checkable ?? false
        let releases = SettingsAbout.releasesURL(about?.repository)
        Section {
            VStack(alignment: .leading, spacing: 3) {
                Text(about?.name ?? model.fallbackName ?? "This app")
                    .font(.title3.weight(.semibold))
                let tagline = (about?.tagline).flatMap { $0.isEmpty ? nil : $0 } ?? model.fallbackTagline ?? ""
                if !tagline.isEmpty {
                    Text(tagline).font(.callout).foregroundStyle(.secondary).lineLimit(1).help(tagline)
                }
                if let about {
                    Text("Version \(about.version)").font(.callout).foregroundStyle(.secondary)
                }
            }
            if about == nil {
                NativeCodingAINotice(tone: .warn, text: SettingsAbout.unreadable)
            }
            fact("Licence", more: SettingsAbout.licenceMore) {
                Text(about?.license.flatMap { $0.isEmpty ? nil : $0 } ?? SettingsAbout.notRecorded)
            }
            fact("Source") {
                if let repository = about?.repository, let url = URL(string: repository) {
                    Link("View source", destination: url)
                } else {
                    Text(SettingsAbout.notRecorded)
                }
            }
            if let homepage = about?.homepage, let url = URL(string: homepage) {
                fact("Website") { Link("Visit website", destination: url) }
            }
            if let about {
                fact("Build", more: SettingsAbout.buildMore) {
                    Text(about.buildLine).textSelection(.enabled)
                }
            }
            // One place per option (26 Oct): "Check for updates" lives in Settings › General › Updates, and a new
            // version shows itself in the side panel just above Settings (release 27). About keeps the link only.
            HStack(spacing: 10) {
                if let releases, let url = URL(string: releases) {
                    Link("Releases", destination: url)
                }
                Text(model.checked ?? SettingsAbout.updateNote(about, checkable: checkable))
                    .lineLimit(1).help(model.checked ?? SettingsAbout.updateNote(about, checkable: checkable))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fact<Value: View>(_ label: String, more: String? = nil, @ViewBuilder value: () -> Value) -> some View {
        LabeledContent {
            value()
        } label: {
            HStack(spacing: 4) {
                Text(label)
                if let more { NativeCodingAIInfo(label: label, text: more) }
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
