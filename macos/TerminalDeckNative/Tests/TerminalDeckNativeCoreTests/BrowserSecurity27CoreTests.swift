import Foundation
import Testing
@testable import TerminalDeckNativeCore

@MainActor
@Suite("Browser 27 security fences")
struct BrowserSecurity27CoreTests {
    @Test func privateFilesAreNeverUploadedThroughEitherPathSpelling() {
        let home = "/Users/test"
        let privatePaths = [".ssh/id_ed25519", ".aws/credentials", ".claude/.credentials.json", ".codex/auth.json", ".gemini/oauth_creds.json",
            "Library/Keychains/login.keychain-db", "Library/Application Support/terminaldeck/remote/access-keys.json", "Library/Cookies/cookies.binarycookies",
            "repo/.env", "repo/.env.production", "repo/.env.example", "repo/.envrc", "repo/.npmrc", "repo/.git-credentials", "repo/.pgpass",
            "repo/server.pem", "repo/client.key", "repo/key.p8", "repo/key.p12", "repo/key.pfx", "repo/key.jks", "repo/key.keystore", "repo/key.asc", "repo/key.ppk",
            "repo/state.tfstate.backup", "repo/prod.tfvars.json", "repo/service-account-prod.json", "repo/secrets.yaml", "repo/prod.secrets.toml",
            "Library/Safari/History.db", "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
            "Library/Application Support/Firefox/Profiles/dummy.default/cookies.sqlite", "Library/Application Support/Firefox/Profiles/dummy.default/logins.json",
            "Library/Application Support/Google/Chrome/Default/Network/Cookies", "Library/Application Support/Google/Chrome/Default/Login Data",
            "Library/Application Support/Chromium/Local State", "Library/Application Support/Microsoft Edge/Default/Login Data",
            "Library/Application Support/BraveSoftware/Brave-Browser/Default/Network/Cookies", "Library/Application Support/Arc/User Data/Local State",
            "Library/Application Support/Company/The Browser Company/Arc/User Data/Default/Preferences", "Library/Application Support/Dia/User Data/Default/Preferences",
            "Library/Application Support/LibreWolf/Profiles/dummy/key4.db", "Library/Application Support/Waterfox/Profiles/dummy/cookies.sqlite",
            "Library/Application Support/Zen/Profiles/dummy/cookies.sqlite", "Library/Application Support/Vivaldi/Default/Login Data",
            "Library/Application Support/com.operasoftware.Opera/Cookies", "Library/Application Support/Thunderbird/Profiles/dummy/logins.json",
            "Documents/profile-copy/cookies.sqlite", "Documents/profile-copy/cookies.sqlite-wal", "Documents/profile-copy/Login Data-journal",
            "Documents/profile-copy/Login Data For Account", "Documents/profile-copy/Network/Cookies", "Documents/profile-copy/Web Data",
            "Documents/profile-copy/Local State", "Documents/profile-copy/logins.json", "Documents/profile-copy/key4.db", "Documents/profile-copy/cert9.db",
            "repo/id_ed25519_sk", "repo/credentials/login.txt", "repo/.claude/token", "repo/gcloud/application_default_credentials.json"]
        for relative in privatePaths {
            let path = home + "/" + relative
            #expect(BrowserUploadPolicy.refusal(path: path, resolved: path, home: home, protectedRoots: []) != nil, "\(relative) refused")
            #expect(BrowserUploadPolicy.refusal(path: home + "/Pictures/innocent.png", resolved: path, home: home, protectedRoots: []) != nil, "symlink to \(relative) refused")
            #expect(BrowserUploadPolicy.refusal(path: path, resolved: home + "/Pictures/innocent.png", home: home, protectedRoots: []) != nil, "private alias refused")
        }
        #expect(BrowserUploadPolicy.refusal(path: "/scratch/data/remote/auth.json", resolved: "/scratch/data/remote/auth.json", home: home, protectedRoots: ["/scratch/data"]) != nil)
        for path in [home + "/Pictures/photo.png", home + "/Documents/contract.pdf", home + "/Desktop/table.csv", "/tmp/fixture.txt"] {
            #expect(BrowserUploadPolicy.refusal(path: path, resolved: path, home: home, protectedRoots: []) == nil)
        }
    }

    @Test func powerfulControlsRequireATemporaryStoreAndMediaAlwaysNeedsThePerson() {
        for op in ["evaluate", "storage", "route", "requests", "console", "dialogs", "emulate"] {
            #expect(BrowserAutomationPolicy.refusal(operation: op, arguments: .object([]), isolated: false) != nil)
            #expect(BrowserAutomationPolicy.refusal(operation: op, arguments: .object([]), isolated: true) == nil)
        }
        let function = NativeRPCValue.object([.init("for", .string("function"))])
        #expect(BrowserAutomationPolicy.refusal(operation: "wait", arguments: function, isolated: false) != nil)
        #expect(BrowserAutomationPolicy.refusal(operation: "wait", arguments: function, isolated: true) == nil)
        #expect(BrowserAutomationPolicy.refusal(operation: "wait", arguments: .object([.init("for", .string("load"))]), isolated: false) == nil)
        for isolated in [false, true] {
            for media in ["camera", "microphone"] {
                #expect(BrowserAutomationPolicy.refusal(operation: "permissions", arguments: .object([.init(media, .string("allow"))]), isolated: isolated) != nil)
                #expect(BrowserAutomationPolicy.refusal(operation: "permissions", arguments: .object([.init(media, .string("ask"))]), isolated: isolated) == nil)
            }
        }
    }

    @Test func clipboardShortcutsAndTypingKeysCannotReachSecrets() async throws {
        let engine = FakeEngine()
        await engine.call("browser_open", ["url": "https://example.invalid/"])
        for key in ["Meta+V", "Control+V", "Meta+C", "Control+C", "Meta+X", "Shift+Insert", "Control+Insert", "Shift+Delete"] {
            #expect(BrowserKeyChord.usesClipboard(try BrowserKeyChord.parse(key)))
            #expect(resultError(await engine.call("browser_step", ["verb": "press", "key": key]))?.contains("clipboard") == true)
        }
        for type in ["password", "cc-number", "one-time-code"] {
            engine.host.probeAnswer["secret"] = true
            engine.host.probeAnswer["type"] = type
            engine.host.probeAnswer["editable"] = true
            for verb in ["type", "press", "clear"] {
                #expect(resultError(await engine.call("browser_step", ["verb": verb, "selector": "#secret", "value": "dummy", "key": "a", "force": true])) != nil)
            }
        }
        #expect(engine.host.typed.isEmpty)
        #expect(engine.host.keys.isEmpty)
    }
}
