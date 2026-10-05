import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Ready line parser")
struct ReadyLineTests {
    @Test func readyLineWithToken() throws {
        let signal = EngineLineParser.parse("TD_NATIVE_READY http://127.0.0.1:51234/?t=abc123")
        #expect(signal == .ready(try #require(URL(string: "http://127.0.0.1:51234/?t=abc123"))))
    }

    @Test func toleratesSurroundingWhitespaceAndCRLF() throws {
        let signal = EngineLineParser.parse("  TD_NATIVE_READY   http://127.0.0.1:8080/?t=x \r\n")
        #expect(signal == .ready(try #require(URL(string: "http://127.0.0.1:8080/?t=x"))))
    }

    @Test func failedLineKeepsTheExactReason() {
        #expect(EngineLineParser.parse("TD_NATIVE_FAILED port 0 refused: EADDRINUSE") == .failed("port 0 refused: EADDRINUSE"))
    }

    @Test func failedWithoutReasonStillFails() {
        guard case .failed(let reason) = EngineLineParser.parse("TD_NATIVE_FAILED") else {
            Issue.record("expected .failed"); return
        }
        #expect(!reason.isEmpty)
    }

    @Test func ordinaryOutputIsNotAProtocolLine() {
        #expect(EngineLineParser.parse("[main] window created") == nil)
        #expect(EngineLineParser.parse("") == nil)
        #expect(EngineLineParser.parse("TD_NATIVE_READYX http://127.0.0.1:1/") == nil)
        #expect(EngineLineParser.parse("prefix TD_NATIVE_READY http://127.0.0.1:1/") == nil)
    }

    @Test func readyWithNonLocalAddressIsAFailure() {
        for bad in ["https://127.0.0.1:443/", "http://example.com:80/", "http://127.0.0.1/", "http://10.0.0.5:3000/", "file:///etc/passwd", "not a url"] {
            guard case .failed = EngineLineParser.parse("TD_NATIVE_READY \(bad)") else {
                Issue.record("\(bad) should be refused"); continue
            }
        }
    }

    @Test func readyWithoutAddressIsAFailure() {
        guard case .failed = EngineLineParser.parse("TD_NATIVE_READY") else {
            Issue.record("expected .failed"); return
        }
    }

    @Test func errorsNeverEchoTheToken() {
        guard case .failed(let reason) = EngineLineParser.parse("TD_NATIVE_READY http://evil.example:80/?t=SECRET") else {
            Issue.record("expected .failed"); return
        }
        #expect(!reason.contains("SECRET"))
        #expect(EngineLineParser.redacted(URL(string: "http://127.0.0.1:5/?t=SECRET")!) == "http://127.0.0.1:5/?…")
    }
}

@Suite("Line buffer")
struct LineBufferTests {
    @Test func splitsAcrossChunks() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("hello\nTD_NATIVE_RE".utf8)) == ["hello"])
        #expect(buffer.append(Data("ADY http://127.0.0.1:9/?t=1\r\nlast".utf8)) == ["TD_NATIVE_READY http://127.0.0.1:9/?t=1"])
        #expect(buffer.flush() == "last")
        #expect(buffer.flush() == nil)
    }

    @Test func keepsMultiByteCharactersSplitBetweenReads() {
        var buffer = LineBuffer()
        let bytes = Array("café ✓\n".utf8)
        let cut = 4 // inside "é"
        #expect(buffer.append(Data(bytes[..<cut])) == [])
        #expect(buffer.append(Data(bytes[cut...])) == ["café ✓"])
    }
}

@Suite("Origin check")
struct OriginTests {
    let origin = EngineOrigin(url: URL(string: "http://127.0.0.1:51234/?t=abc")!)!

    @Test func sameOriginLoadsInTheView() {
        for url in ["http://127.0.0.1:51234/", "http://127.0.0.1:51234/assets/app.js", "http://127.0.0.1:51234/#/tasks?x=1"] {
            #expect(NavigationPolicy.decide(url: URL(string: url), isMainFrame: true, origin: origin) == .allow, "\(url)")
        }
    }

    @Test func otherPortsHostsAndSchemesAreNotTheEngine() {
        for url in ["http://127.0.0.1:51235/", "https://127.0.0.1:51234/", "http://localhost:51234/", "http://127.0.0.1/"] {
            #expect(!origin.contains(URL(string: url)!), "\(url)")
        }
    }

    @Test func externalLinksOpenInTheDefaultBrowser() {
        for url in ["https://github.com/asadev", "http://example.com/", "mailto:someone@example.com"] {
            #expect(NavigationPolicy.decide(url: URL(string: url), isMainFrame: true, origin: origin) == .openExternally, "\(url)")
        }
    }

    @Test func externalFramesAreBlockedNotOpened() {
        #expect(NavigationPolicy.decide(url: URL(string: "https://ads.example/"), isMainFrame: false, origin: origin) == .block)
    }

    @Test func dangerousSchemesAreNeverHandedOn() {
        for url in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "vscode://open", "ftp://x/"] {
            #expect(NavigationPolicy.decide(url: URL(string: url), isMainFrame: true, origin: origin) == .block, "\(url)")
        }
    }

    @Test func blankDocumentsAndOwnBlobs() {
        #expect(NavigationPolicy.decide(url: URL(string: "about:blank"), isMainFrame: true, origin: origin) == .allow)
        #expect(NavigationPolicy.decide(url: URL(string: "about:srcdoc"), isMainFrame: false, origin: origin) == .allow)
        #expect(NavigationPolicy.decide(url: URL(string: "about:srcdoc"), isMainFrame: true, origin: origin) == .block)
        #expect(NavigationPolicy.decide(url: URL(string: "blob:http://127.0.0.1:51234/5a1b"), isMainFrame: false, origin: origin) == .allow)
        #expect(NavigationPolicy.decide(url: URL(string: "blob:https://evil.example/5a1b"), isMainFrame: false, origin: origin) == .block)
        #expect(NavigationPolicy.decide(url: nil, isMainFrame: true, origin: origin) == .block)
    }

    @Test func onlyLocalHttpWithAPortIsAnEngineOrigin() {
        #expect(EngineOrigin(url: URL(string: "http://localhost:3000/")!) != nil)
        #expect(EngineOrigin(url: URL(string: "http://[::1]:3000/")!) != nil)
        #expect(EngineOrigin(url: URL(string: "http://127.0.0.1/")!) == nil)
        #expect(EngineOrigin(url: URL(string: "http://192.168.1.4:3000/")!) == nil)
        #expect(EngineOrigin(url: URL(string: "http://user:pw@127.0.0.1:3000/")!) == nil)
    }

    @Test func webKitSecurityOriginMatch() {
        #expect(origin.matches(scheme: "http", host: "127.0.0.1", port: 51234))
        #expect(!origin.matches(scheme: "http", host: "127.0.0.1", port: 51235))
        #expect(!origin.matches(scheme: "https", host: "127.0.0.1", port: 51234))
    }
}

@Suite("Engine configuration")
struct ConfigurationTests {
    let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)
    let home = "/Users/someone"

    func installed(_ version: String?, at path: String = "/Applications/Terminal Deck.app", executable: String? = "Terminal Deck") -> InstalledApp {
        InstalledApp(url: URL(fileURLWithPath: path, isDirectory: true), version: version, executableName: executable)
    }

    @Test func installedTerminalDeckIsTheEngine() throws {
        let config = EngineConfiguration.resolve(environment: [:], applicationSupport: support, home: home, installed: installed("0.18.7"))
        guard case .installedApp(let app, _, let version) = config.source else { Issue.record("expected the installed app"); return }
        #expect(app.path == "/Applications/Terminal Deck.app")
        #expect(version == "0.18.7")
        #expect(config.executable?.path == "/Applications/Terminal Deck.app/Contents/MacOS/Terminal Deck")
        #expect(config.arguments == ["--native-shell",
                                     "--user-data-dir=/Users/someone/Library/Application Support/Terminal Deck Native Proof/engine"])
        #expect(config.workingDirectory == nil)
        #expect(config.engineDataDirectory.path == "/Users/someone/Library/Application Support/Terminal Deck Native Proof/engine")
        #expect(config.logFile.path == "/Users/someone/Library/Application Support/Terminal Deck Native Proof/engine.log")
    }

    @Test func newerReleasesAreFine() {
        for v in ["0.18.8", "0.19.0", "1.0", "0.18.7.1"] {
            let config = EngineConfiguration.resolve(environment: [:], applicationSupport: support, home: home, installed: installed(v))
            guard case .installedApp = config.source else { Issue.record("\(v) should be accepted"); continue }
        }
    }

    @Test func missingTerminalDeckIsSaidPlainly() {
        let config = EngineConfiguration.resolve(environment: [:], applicationSupport: support, home: home, installed: nil)
        #expect(config.source == .unavailable(.notInstalled))
        #expect(config.executable == nil && config.arguments.isEmpty)
    }

    @Test func tooOldTerminalDeckIsSaidPlainly() {
        for v in ["0.18.6", "0.18.5", "0.17.0", "0.18.7-beta.1"] {
            let config = EngineConfiguration.resolve(environment: [:], applicationSupport: support, home: home, installed: installed(v))
            #expect(config.source == .unavailable(.tooOld(found: v)), "\(v)")
        }
        let unknown = EngineConfiguration.resolve(environment: [:], applicationSupport: support, home: home, installed: installed(nil))
        #expect(unknown.source == .unavailable(.tooOld(found: "an unknown version")))
    }

    @Test func messagesSayExactlyWhatIsWrongAndOfferTheDownload() {
        let missing = EngineFailure.needsTerminalDeck(.notInstalled)
        #expect(missing.title == "Terminal Deck isn't installed")
        #expect(missing.message.contains("0.18.7"))
        #expect(missing.downloadURL?.absoluteString == "https://terminaldeck.dev/download.html")
        let old = EngineFailure.needsTerminalDeck(.tooOld(found: "0.18.5"))
        #expect(old.title == "Terminal Deck needs an update")
        #expect(old.message.contains("0.18.5") && old.message.contains("0.18.7"))
        #expect(old.downloadURL != nil)
    }

    @Test func codeCheckoutOverrideWins() {
        // Even with a good install present, TD_REPO means the checkout.
        let config = EngineConfiguration.resolve(environment: ["TD_REPO": "~/code/td"], applicationSupport: support, home: home, installed: installed("0.19.0"))
        #expect(config.source == .checkout(repo: URL(fileURLWithPath: "/Users/someone/code/td", isDirectory: true)))
        #expect(config.executable?.path == "/Users/someone/code/td/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron")
        #expect(config.arguments.first == "/Users/someone/code/td")
        #expect(config.workingDirectory?.path == "/Users/someone/code/td")
        // Blank TD_REPO is no override.
        let blank = EngineConfiguration.resolve(environment: ["TD_REPO": "  "], applicationSupport: support, home: home, installed: installed("0.18.7"))
        guard case .installedApp = blank.source else { Issue.record("blank TD_REPO should fall through"); return }
    }

    @Test func customExecutableName() {
        let config = EngineConfiguration.resolve(environment: [:], applicationSupport: support, home: home,
                                                 installed: installed("0.18.7", at: "/Users/someone/Applications/Terminal Deck.app", executable: "TD"))
        #expect(config.executable?.path == "/Users/someone/Applications/Terminal Deck.app/Contents/MacOS/TD")
    }

    @Test func dataFolderOverrideForChecksOnly() {
        let config = EngineConfiguration.resolve(environment: ["TD_NATIVE_DATA_DIR": "/tmp/check-data"], applicationSupport: support, home: home, installed: nil)
        #expect(config.dataRoot.path == "/tmp/check-data")
        let relative = EngineConfiguration.resolve(environment: ["TD_NATIVE_DATA_DIR": "relative"], applicationSupport: support, home: home, installed: nil)
        #expect(relative.dataRoot.path.hasSuffix("Terminal Deck Native Proof"), "only an absolute path is taken")
    }

    @Test func newestCopyWinsAndTheTrashNever() {
        let best = EngineConfiguration.bestInstalled([
            installed("0.18.7", at: "/Applications/Terminal Deck.app"),
            installed("0.19.2", at: "/Users/someone/.Trash/Terminal Deck.app"),
            installed("0.18.9", at: "/Users/someone/Applications/Terminal Deck.app"),
            installed(nil, at: "/Volumes/TD/Terminal Deck.app"),
        ])
        #expect(best?.url.path == "/Users/someone/Applications/Terminal Deck.app")
        #expect(EngineConfiguration.bestInstalled([]) == nil)
        #expect(EngineConfiguration.bestInstalled([installed(nil)])?.version == nil, "an unreadable copy is still reported (as too old)")
    }

    @Test func childEnvironmentDropsRunAsNode() {
        let env = EngineConfiguration.childEnvironment(from: ["PATH": "/usr/bin", "ELECTRON_RUN_AS_NODE": "1"])
        #expect(env == ["PATH": "/usr/bin"])
    }
}

@Suite("Version comparison")
struct AppVersionTests {
    func v(_ s: String) -> AppVersion { AppVersion(s)! }

    @Test func ordersReleases() {
        #expect(v("0.18.6") < v("0.18.7"))
        #expect(v("0.18.7") < v("0.18.10"), "numeric, not alphabetical")
        #expect(v("0.9.9") < v("0.18.0"))
        #expect(v("0.18.7") < v("1.0.0"))
        #expect(v("0.18.7") == v("0.18.7.0"), "missing parts are zero")
        #expect(v("0.18") < v("0.18.7"))
        #expect(v("v0.18.7") == v("0.18.7"))
    }

    @Test func preReleasesComeBeforeTheRelease() {
        #expect(v("0.18.7-beta.1") < v("0.18.7"))
        #expect(v("0.18.7-beta.2") < v("0.18.7-beta.10"))
        #expect(v("0.18.7-rc.1") > v("0.18.6"))
        #expect(v("0.18.7+build.5") == v("0.18.7"), "build metadata doesn't count")
    }

    @Test func refusesNonsense() {
        for bad in ["", "abc", "0.18.x", "1..2", "-1.0", "1.2.3.4.5"] {
            #expect(AppVersion(bad) == nil, "\(bad)")
        }
    }

    @Test func minimumIsTheFirstNativeShellRelease() {
        #expect(EngineConfiguration.minimumVersion == v("0.18.7"))
        #expect(EngineConfiguration.appBundleID == "dev.terminaldeck.app")
    }
}
