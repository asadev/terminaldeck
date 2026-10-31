import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Page address")
struct PageAddressTests {
    @Test func logsNeverCarryTheToken() {
        #expect(EngineLineParser.redacted(URL(string: "http://127.0.0.1:5/?t=SECRET")!) == "http://127.0.0.1:5/?…")
        #expect(EngineLineParser.redacted("http://127.0.0.1:5/") == "http://127.0.0.1:5/")
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
    let support = URL(fileURLWithPath: "/Users/me/Library/Application Support", isDirectory: true)

    /// #287: the Electron engine is gone. A copy without its pages never looks for another
    /// Terminal Deck, starts nothing and keeps the old preview folder, never the app's data.
    @Test func aCopyWithoutItsPagesSaysSoAndKeepsAwayFromTheAppsData() {
        let config = EngineConfiguration.resolve(environment: ["TD_REPO": "~/code/td"], applicationSupport: support, resources: nil)
        guard case .unavailable(.bundledEngine(let detail)) = config.source else { Issue.record("a bare copy must say so"); return }
        #expect(!detail.isEmpty)
        #expect(config.dataRoot.lastPathComponent == EngineConfiguration.dataFolderName)
        #expect(EngineFailure.needsTerminalDeck(.bundledEngine(detail)).message == detail)
    }

    @Test func dataFolderOverrideForChecksOnly() {
        let config = EngineConfiguration.resolve(environment: ["TD_NATIVE_DATA_DIR": "/tmp/check-data"], applicationSupport: support, resources: nil)
        #expect(config.dataRoot.path == "/tmp/check-data")
        let relative = EngineConfiguration.resolve(environment: ["TD_NATIVE_DATA_DIR": "relative"], applicationSupport: support, resources: nil)
        #expect(relative.dataRoot.lastPathComponent == EngineConfiguration.dataFolderName)
        #expect(EngineConfiguration.appBundleID == "dev.terminaldeck.app")
    }
}
