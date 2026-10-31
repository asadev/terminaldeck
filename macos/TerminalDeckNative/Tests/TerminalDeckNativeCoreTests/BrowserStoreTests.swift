import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Mirrors extensions-bridge.test.ts and store-bridge.test.ts (the readers and the row words).

@Suite("Store → Browser extensions")
struct BrowserStoreTests {
    private func json(_ text: String) -> CodingAIJSON { CodingAIJSON.parse(text) }

    @Test func readsTheExtensionsView() {
        let view = BrowserStore.extensions(json("""
        {"view":{"profileId":"p1","profileName":"Default","folder":"/x","extensions":[
          {"id":"ubo","name":"uBlock","works":"works","category":"blocking","state":"installed","enabled":true,"reach":["<all_urls>"],"everywhere":true,"cost":"free","bytes":1200},
          {"id":"odd","works":"maybe","state":"weird","category":"nope","cost":"lots"},
          {"name":"no id"}]},
         "orphans":["gone"],"profiles":[{"id":"p1","name":"Default"},{"id":""}],"limits":["one","two"]}
        """))
        #expect(view.profileId == "p1" && view.profileName == "Default" && view.folder == "/x")
        #expect(view.extensions.map(\.id) == ["ubo", "odd"], "a row with no id is dropped")
        let odd = view.extensions[1]
        #expect(odd.works == "no" && odd.state == "available" && odd.category == "scripting" && odd.cost == "unknown")
        #expect(odd.name == "odd")
        #expect(view.orphans == ["gone"] && view.profiles.map(\.id) == ["p1"] && view.limits.count == 2)
        #expect(BrowserStore.extensions(.null).extensions.isEmpty)
    }

    @Test func readsTheToolsView() {
        let view = BrowserStore.tools(json(#"{"view":{"folder":"/t","tools":[{"id":"a","state":"outdated","fetched":true},{"id":"b","state":"weird"},{"name":"x"}]},"orphans":["old"]}"#))
        #expect(view.tools.map(\.id) == ["a", "b"] && view.tools[1].state == "available" && view.tools[1].name == "b")
        #expect(view.folder == "/t" && view.orphans == ["old"])
        #expect(BrowserStore.tools(.null).tools.isEmpty)
    }

    @Test func resultsAndWords() {
        #expect(BrowserStore.result(.null) == (false, "The app did not answer."))
        #expect(BrowserStore.result(json(#"{"ok":true,"message":"Installed."}"#)) == (true, "Installed."))
        #expect(BrowserStore.reachWords(["<all_urls>"], everywhere: true) == "every page you open in this profile")
        #expect(BrowserStore.reachWords(["a.com", "b.com"], everywhere: false) == "a.com, b.com")
        #expect(BrowserStore.reachWords([], everywhere: false) == "no pages of its own")
        #expect(BrowserStore.originWords(["*"]) == "any page")
        #expect(BrowserStore.originWords([]) == "nowhere")
        #expect(BrowserStore.grantWords([]) == "Reads nothing")
        #expect(BrowserStore.grantWords(["page-read"]) == "Reads the page you point it at")
        #expect(BrowserStore.bytesExactly(1234567) == " — 1,234,567 bytes, exactly")
    }

    @Test func actionsAgreeWithTheirVerbs() {
        var ext = BrowserStore.extensions(json(#"{"view":{"extensions":[{"id":"x"}]}}"#)).extensions[0]
        #expect(BrowserStore.extensionActionLabel(ext, busy: false) == "Install" && BrowserStore.extensionVerb(ext) == "install")
        ext.state = "damaged"
        #expect(BrowserStore.extensionActionLabel(ext, busy: false) == "Remove" && BrowserStore.extensionVerb(ext) == "remove",
                "a damaged install says Remove, not Reinstall")
        #expect(BrowserStore.extensionActionLabel(ext, busy: true) == "Working…")
        var tool = BrowserStore.tools(json(#"{"view":{"tools":[{"id":"t","fetched":true}]}}"#)).tools[0]
        #expect(BrowserStore.toolActionLabel(tool, busy: false) == "Download")
        tool.fetched = false
        #expect(BrowserStore.toolActionLabel(tool, busy: false) == "Install" && BrowserStore.toolVerb(tool) == "install")
        tool.state = "installed"
        #expect(BrowserStore.toolActionLabel(tool, busy: false) == "Remove" && BrowserStore.toolVerb(tool) == "remove")
    }

    @Test func facetsAndShelves() {
        var ext = BrowserStore.extensions(json(#"{"view":{"extensions":[{"id":"x","works":"partly"}]}}"#)).extensions[0]
        #expect(BrowserStore.compat(ext) == "unknown", "partly is not working")
        ext.works = "no"
        #expect(BrowserStore.compat(ext) == "cannot")
        #expect(BrowserStore.source(ext) == "release")
        ext.sideloaded = true
        #expect(BrowserStore.source(ext) == "your-own")
        #expect(BrowserStore.shelves.map(\.id) == ["blocking", "privacy", "appearance", "media", "scripting", "your-own", "built-in"])
        #expect(BrowserStore.emptyShelvesLine(kept: 0, filtering: true) == "Nothing in the store matches that.")
        #expect(BrowserStore.emptyShelvesLine(kept: 2, filtering: false) == "Everything this app can install is already installed in this profile.")
    }
}
