import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Mirrors the pure parts of BrowserSection.test.tsx and the parsers it leans on.

@Suite("Settings → Browser")
struct BrowserSettingsTests {
    private func json(_ text: String) -> CodingAIJSON { CodingAIJSON.parse(text) }

    @Test func blockedBrowsers() {
        #expect(BrowserSettings.blockedNote([]) == nil)
        #expect(BrowserSettings.blockedNote([BrowserSettingsDetected(id: "c", name: "Chrome", access: .blocked)])
                == "Chrome’s data is protected by the system. Grant Full Disk Access to read it.")
        #expect(BrowserSettings.blockedNote([BrowserSettingsDetected(id: "c", name: "Chrome", access: .blocked, note: "Own words.")]) == "Own words.")
        let three = ["Chrome", "Brave", "Arc"].map { BrowserSettingsDetected(id: $0, name: $0, access: .blocked) }
        #expect(BrowserSettings.blockedNote(three)?.hasPrefix("macOS will not let this app read Chrome, Brave and Arc until") == true)
    }

    @Test func buttonsAndNotes() {
        #expect(BrowserSettings.buttonLabel(BrowserSettingsDetected(id: "c", name: "Chrome", profiles: ["a", "b", "c", "d"])) == "Chrome (4 profiles)")
        #expect(BrowserSettings.buttonLabel(BrowserSettingsDetected(id: "c", name: "Chrome", access: .blocked, profiles: ["a", "b"])) == "Chrome")
        #expect(BrowserSettings.buttonLabel(BrowserSettingsDetected(id: "c", name: "Chrome", profiles: ["a"])) == "Chrome")
        let hit = BrowserSettingsDevUrl(url: "http://localhost:3000", title: "App", source: "session", detail: "Open tab", approximate: true)
        #expect(BrowserSettings.noteFor(hit) == "Open tab · App · approximate")
    }

    @Test func readersAreForgiving() {
        let browsers = BrowserSettings.browsers(json(#"[{"id":"chrome","name":"Chrome","access":"ok","profiles":[{"id":"Default"},{"id":"P1"}]},{"name":"no id"},{"id":"arc","access":"weird"}]"#))
        #expect(browsers.map(\.id) == ["chrome", "arc"] && browsers[1].access == .missing && browsers[0].profiles.count == 2)
        let scan = BrowserSettings.scan(json(#"{"urls":[{"url":"http://a"},{"url":"http://a"},{"url":"http://b","source":"bogus"}],"problems":[{"message":"x"},{"message":"x"},{"message":""}]}"#))
        #expect(scan.urls.map(\.url) == ["http://a", "http://b"] && scan.urls[1].source == "history" && scan.problems == ["x"])
        #expect(BrowserSettings.profiles(json(#"{"profiles":[]}"#)) == nil)
        let profiles = BrowserSettings.profiles(json(#"{"profiles":[{"id":"d","name":"Default","isDefault":true},{"id":"w","name":"Work"}],"activeId":"gone"}"#))
        #expect(profiles?.activeId == "d", "an unknown active profile falls back to the first")
        #expect(BrowserSettings.logins(json(#"[{"origin":"https://x.com","username":"me"},{"origin":""}]"#)).count == 1)
        #expect(BrowserSettings.passwordStore(json(#"{"available":true,"fault":"tampered"}"#))?.fault == .tampered)
        #expect(BrowserSettings.passwordStore(.null) == nil)
    }

    @Test func cookieImportLines() {
        let sources = BrowserSettings.cookieSources(json(#"[{"browserId":"c","browserName":"Chrome","profileId":"Default","profileName":"Default","keychainItem":true},{"browserId":"c","profileId":"P1","profileName":"Work"},{"browserId":"b","browserName":"Brave","profileId":"Default"}]"#))
        let groups = BrowserSettings.groupSources(sources)
        #expect(groups.map(\.browserName) == ["Chrome", "Brave"] && groups[0].profiles.count == 2)
        #expect(BrowserSettings.profileOptionLabel(sources[0]) == "Default")
        #expect(BrowserSettings.profileOptionLabel(sources[1]) == "Work (P1)")
        let none = BrowserSettingsImports(present: 0, recorded: 0, importedAt: nil, source: "", supported: true)
        #expect(BrowserSettings.importedSummary(none, now: 0) == "No cookies have been imported.")
        let all = BrowserSettingsImports(present: 3, recorded: 3, importedAt: 0, source: "Chrome", supported: true)
        #expect(BrowserSettings.importedSummary(all, now: 5 * 60_000) == "3 imported cookies from Chrome. Last imported 5 minutes ago.")
        let some = BrowserSettingsImports(present: 1, recorded: 4, importedAt: nil, source: "", supported: true)
        #expect(BrowserSettings.importedCount(some) == "1 of 4 imported cookies are still here — the rest have expired.")
        #expect(BrowserSettings.whenImported(0, now: 20_000) == "just now")
        #expect(BrowserSettings.whenImported(0, now: 3 * 3_600_000) == "3 hours ago")
        #expect(BrowserSettings.removedImported(1) == "Removed 1 imported cookie. Sign-ins made inside the browser tab are untouched.")
    }

    @Test func keptProfilesAndPasswords() {
        #expect(BrowserSettings.keptSummary(BrowserSettingsStored(cookieCount: 0, domainCount: 0, cacheBytes: 0)) == "Nothing kept yet.")
        #expect(BrowserSettings.keptSummary(BrowserSettingsStored(cookieCount: 0, domainCount: 0, cacheBytes: 2048)) == "No cookies, and 2.0 KB of cached pages.")
        #expect(BrowserSettings.keptSummary(BrowserSettingsStored(cookieCount: 1, domainCount: 1, cacheBytes: 0)) == "1 cookie from 1 site, and nothing cached.")
        #expect(BrowserSettings.keptSummary(BrowserSettingsStored(cookieCount: 9, domainCount: 2, cacheBytes: 3 * 1024 * 1024)) == "9 cookies from 2 sites, and 3.0 MB of cached pages.")
        let def = BrowserSettingsProfile(id: "d", name: "Default", isDefault: true)
        #expect(BrowserSettings.profileCaption(def, activeId: "d") == "New tabs open in this one · Cannot be deleted")
        #expect(BrowserSettings.profileCaption(BrowserSettingsProfile(id: "w", name: "Work", isDefault: false), activeId: "d") == "")
        #expect(BrowserSettings.savedSummary(0, profileName: "Work") == "Nothing saved in Work yet. Signing in to a site in the browser offers to remember it.")
        #expect(BrowserSettings.savedSummary(2, profileName: "Work") == "2 saved logins in Work.")
        #expect(BrowserSettings.forgetAllConfirm(1) == "Forget the one saved password? This is across every profile and cannot be undone.")
        #expect(BrowserSettings.forgetAllConfirm(0, faulted: true).hasPrefix("Delete the saved-login file?"))
        #expect(BrowserSettings.loginLabel(BrowserSettingsLogin(profileId: "", origin: "https://x.com", username: "me", updatedAt: 0)) == "x.com — me")
        #expect(BrowserSettings.loginLabel(BrowserSettingsLogin(profileId: "", origin: "http://y.com", username: "", updatedAt: 0)) == "http://y.com")
        #expect(BrowserSettings.errorText("Error invoking remote method 'x': Error: Nope.", fallback: "f") == "Nope.")
        #expect(BrowserSettings.errorText("  ", fallback: "f") == "f")
    }
}
