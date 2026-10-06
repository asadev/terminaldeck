import Foundation
import Testing
@testable import TerminalDeckNativeCore

// The native Settings sections (lane G): the table and the helpers each section
// used on the page, mirroring settings-schema.test.ts, notification-check, the
// About, Linux and Advanced section tests. Fixtures only; nothing is written.

private func json(_ text: String) -> CodingAIJSON { CodingAIJSON.parse(text) }

@Suite("Settings — the table")
struct SettingsSchemaTests {
    @Test func everySectionListsItsRowsInTableOrder() {
        #expect(SettingsSchema.settings(in: "general").map(\.id) == [
            "general.restoreSessions", "general.autoNameSessions", "general.confirmCloseWorking", "general.copyOnSelect",
        ])
        #expect(SettingsSchema.settings(in: "appearance").map(\.id) == [
            "appearance.theme", "appearance.density", "appearance.terminalScheme",
            "appearance.terminalFontSize", "appearance.terminalFontFamily",
        ])
        #expect(SettingsSchema.settings(in: "notifications").count == 6)
        #expect(SettingsSchema.settings(in: "advanced").map(\.id) == ["advanced.debugMode"])
        #expect(SettingsSchema.section("help")?.blurb == "What this app is, how it works, and what to do when it does not.")
        #expect(Set(SettingsSchema.all.map(\.id)).count == SettingsSchema.all.count)
    }

    @Test func coerceKeepsOnlyWhatARowCanHold() {
        let theme = SettingsSchema.setting("appearance.theme")!
        #expect(SettingsSchema.coerce(theme, .string("light")) == .string("light"))
        #expect(SettingsSchema.coerce(theme, .string("purple")) == nil)
        let size = SettingsSchema.setting("appearance.terminalFontSize")!
        #expect(SettingsSchema.coerce(size, .number(30)) == .number(24))
        #expect(SettingsSchema.coerce(size, .number(12.6)) == .number(13))
        #expect(SettingsSchema.coerce(size, .string("12")) == nil)
        let toggle = SettingsSchema.setting("general.copyOnSelect")!
        #expect(SettingsSchema.coerce(toggle, .number(1)) == nil)
        let font = SettingsSchema.setting("appearance.terminalFontFamily")!
        #expect(SettingsSchema.coerce(font, .string(String(repeating: "x", count: 600)))?.string?.count == 512)
    }

    @Test func storedValuesMergeOverDefaultsWithOldNamesAndPreferences() {
        let settings = json(#"{"version": 1, "values": {"general.soundOnFinish": true, "appearance.density": "huge", "custom.key": 5, "general.defaultProvider": "gemini"}}"#)
        let values = SettingsSchema.values(settings: settings, preferences: json(#"{"theme": "light", "defaultProvider": "codex", "restoreSessions": "yes"}"#))
        #expect(values["notifications.onFinishSound"] == .bool(true))    // old name moved
        #expect(values["appearance.density"] == .string("comfortable"))  // impossible value → default
        #expect(values["custom.key"] == .number(5))                      // unknown kept
        #expect(values["appearance.theme"] == .string("light"))          // preference wins
        #expect(values["agents.defaultProvider"] == .string("codex"))    // over the old name too
        #expect(values["general.restoreSessions"] == .bool(true))        // unreadable preference → default
        #expect(values["general.soundOnFinish"] == nil)
        #expect(SettingsSchema.bool(values, "general.copyOnSelect") == false)
        #expect(SettingsSchema.number(values, "appearance.terminalFontSize") == 13)
    }

    @Test func aPatchGoesToTheStoreThatOwnsIt() {
        let split = SettingsSchema.split([
            "appearance.theme": .string("light"),
            "general.copyOnSelect": .bool(true),
            "general.notifyOnAttention": .bool(false),
            "appearance.terminalScheme.custom.mine": .string("{}"),
            "nope": .bool(true),
            "appearance.density": .string("huge"),
        ])
        #expect(split.prefs == ["theme": .string("light")])
        #expect(split.extra == [
            "general.copyOnSelect": .bool(true),
            "notifications.onNeedsInput": .bool(false),
            "appearance.terminalScheme.custom.mine": .string("{}"),
        ])
        #expect(split.unknown == ["appearance.density", "nope"])
        #expect(SettingsSchema.defaultPreferences == [
            "restoreSessions": .bool(true), "theme": .string("dark"),
            "notifyOnComplete": .bool(true), "defaultProvider": .string("claude"),
        ])
    }

    @Test func helpLinesAndNumbers() {
        let font = SettingsSchema.setting("appearance.terminalFontFamily")!
        #expect(SettingsSchema.help(font, value: .string("")) == "A font family name, exactly as your system spells it. Leave empty to use the app's own monospace font.")
        #expect(SettingsSchema.help(font, value: .string("Menlo")) == "A font family name, exactly as your system spells it.")
        let size = SettingsSchema.setting("appearance.terminalFontSize")!
        #expect(SettingsSchema.numberWhileTyping(size, "1") == nil)
        #expect(SettingsSchema.numberWhileTyping(size, " 14 ") == 14)
        #expect(SettingsSchema.numberOnLeaving(size, "1") == 9)
        #expect(SettingsSchema.numberOnLeaving(size, "") == nil)
    }

    @Test func featureOwnedRowsFollowTheFeature() {
        #expect(SettingsFeatures.settingOn("notifications.showInsightAlerts", state: nil))
        #expect(!SettingsFeatures.settingOn("notifications.showInsightAlerts", state: #"{"alerts": "off"}"#))
        #expect(!SettingsFeatures.settingOn("browser.startUrl", state: #"{"browser": "uninstalled"}"#))
        #expect(SettingsFeatures.settingOn("general.copyOnSelect", state: #"{"alerts": "off"}"#))
        #expect(SettingsSaveState.idle.line == "Changes save as you make them.")
        #expect(SettingsSaveState.failed("x").isFailure)
    }

    @Test func theMainWindowIsHandedTheWholeSet() {
        let message = SettingsSchema.changedMessage(["general.copyOnSelect": .bool(true)])
        #expect(message.jsonText == #"{"type":"changed","values":{"general.copyOnSelect":true}}"#)
    }
}

@Suite("Settings — section helpers")
struct SettingsSectionsHelperTests {
    @Test func notificationCopy() {
        #expect(SettingsNotifications.turnedOnABanner(["notifications.onComplete": .bool(true)]))
        #expect(!SettingsNotifications.turnedOnABanner(["notifications.onComplete": .bool(false), "general.copyOnSelect": .bool(true)]))
        #expect(SettingsNotifications.soundHelp(playsOnFinish: true) == nil)
        #expect(SettingsNotifications.soundHelp(playsOnFinish: false) == "Nothing plays this while the switch above is off. Test still previews it.")
        let report = SettingsNotifications.report(json(#"{"verdict": "delivered", "at": "2026-10-06T10:11:12"}"#))
        let delivered = SettingsNotifications.deliveryCopy(verdict: report.verdict, at: report.at, test: true)
        #expect(delivered.text == "macOS recorded a banner at 10:11:12. Notifications are working.")
        #expect(delivered.tone == .info && !delivered.offerSettings)
        #expect(SettingsNotifications.report(json(#"{"verdict": "maybe"}"#)).verdict == .unknown)
        let enabled = SettingsNotifications.deliveryCopy(verdict: .unknown, at: nil, test: false)
        #expect(enabled.text.hasPrefix("On. macOS may now ask you to allow notifications."))
        #expect(SettingsNotifications.deliveryCopy(verdict: .absent, at: nil, test: true).offerSettings)
    }

    @Test func soundsAreSynthesised() {
        #expect(SettingsSound.isSoundId("chime") && !SettingsSound.isSoundId("bell"))
        #expect(abs(SettingsSound.duration("chime") - 0.32) < 0.0001)
        let samples = SettingsSound.samples("knock", sampleRate: 8000)
        #expect(samples.count == Int((SettingsSound.duration("knock") * 8000).rounded(.up)))
        #expect(samples.allSatisfy { abs($0) <= 1 })
        #expect(samples.contains { abs($0) > 0.05 })
        #expect(SettingsSound.samples("bell").isEmpty)
    }

    @Test func aboutLines() {
        let about = SettingsAbout.parse(json(#"{"name": "Terminal Deck", "version": "0.18.7", "electron": "38.0", "chromium": "", "node": "22", "platform": "darwin", "arch": "arm64", "repository": "https://github.com/asadev/terminaldeck/", "updates": {"checkable": true, "detail": ""}}"#))
        #expect(about?.buildLine == "Electron 38.0 · Node 22 · darwin arm64")
        #expect(SettingsAbout.releasesURL(about?.repository) == "https://github.com/asadev/terminaldeck/releases")
        #expect(SettingsAbout.releasesURL("https://gitlab.com/x") == nil)
        #expect(SettingsAbout.updateNote(about, checkable: true) == "Press the button to check.")
        #expect(SettingsAbout.updateNote(nil, checkable: false) == "Not while the build details cannot be read.")
        #expect(SettingsAbout.parse(json(#"{"version": "1"}"#)) == nil)
        #expect(SettingsAbout.parse(json(#"{"name": "x"}"#))?.buildLine == "Not reported by this build.")
    }

    @Test func configPaths() {
        let paths = SettingsConfigPath.parse(json(#"[{"key": "logs", "path": "/l", "kind": "folder", "exists": false}, {"key": "settings", "label": "Settings file", "path": "/s.json", "exists": true}, {"path": "/no-key"}]"#))
        #expect(paths.map(\.key) == ["logs", "settings"])
        #expect(paths[0].isFolder && paths[0].label == "logs" && !paths[0].exists)
        #expect(!paths[1].isFolder && paths[1].exists)
        #expect(SettingsConfigPath.openMessage(json("{}")) == "Nothing happened.")
    }

    @Test func linuxSnapshot() {
        let snapshot = SettingsWslSnapshot.parse(json(#"{"supported": true, "state": "ready", "distros": [{"name": "Ubuntu", "version": 2, "running": true, "isDefault": true}, {"name": ""}], "active": "Ubuntu", "home": "/home/me", "read": true}"#))
        #expect(snapshot?.state == .ready && snapshot?.distros.count == 1)
        #expect(snapshot?.distros.first?.note == "Running now.")
        #expect(SettingsWslSnapshot.parse(json(#"{"state": "weird"}"#))?.state == .absent)
        #expect(SettingsWslSnapshot.parse(.null) == nil)
        #expect(SettingsWslSnapshot.remembered("Ubuntu", "PC") == "Sessions in a Linux folder use Ubuntu, remembered for this PC.")
    }

    @Test func fontPicker() {
        let installed = ["SF Mono", "Menlo"]
        let ok = SettingsAppearance.fontChoice(chosen: " Menlo ", installed: installed)
        #expect(!ok.missing && ok.options == installed && ok.help == "Every monospace font found on this computer.")
        let elsewhere = SettingsAppearance.fontChoice(chosen: "Iosevka", installed: installed)
        #expect(elsewhere.missing && elsewhere.options == ["SF Mono", "Menlo", "Iosevka"])
        #expect(elsewhere.title("Iosevka", chosen: "Iosevka") == "Iosevka — not installed here")
        #expect(SettingsAppearance.monoCandidates.count == 30)
    }
}
