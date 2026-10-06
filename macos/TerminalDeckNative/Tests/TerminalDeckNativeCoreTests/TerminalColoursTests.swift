import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Lane T — Settings → Terminal colours (mirrors terminal-theme.test.ts / TerminalColours.test.tsx).

@Suite("Terminal colours")
struct TerminalColoursTests {
    private var deck: TerminalScheme { TerminalSchemes.app(dark: true) }

    @Test func copiesAreNamedAndNumberedFromOne() {
        #expect(TerminalColours.copyName("Nord") == "Nord (yours)")
        #expect(TerminalColours.copyName("Nord (yours)") == "Nord (yours)")
        #expect(TerminalColours.newCustomId([]) == "custom-1")
        #expect(TerminalColours.newCustomId(["custom-1", "custom-3"]) == "custom-2")
        let copy = TerminalColours.copy(deck, taken: ["custom-1"])
        #expect(copy.id == "custom-2" && copy.name == "Deck Dark (yours)" && copy.background == deck.background)
    }

    @Test func namesAreCleanedAndCapped() {
        #expect(TerminalColours.cleanName("  My   scheme ") == "My scheme")
        #expect(TerminalColours.cleanName(String(repeating: "x", count: 60)).count == 48)
    }

    @Test func storedSchemesReadBack() throws {
        let stored = TerminalColours.stored(deck.renamed(name: "Mine"))
        let back = try #require(TerminalSchemes.customs(in: ["appearance.terminalScheme.custom.custom-1": stored]).first)
        #expect(back.id == "custom-1" && back.name == "Mine" && back.ansi == deck.ansi)
    }

    @Test func exportCarriesTheAliasesOtherTerminalsUse() throws {
        let text = TerminalColours.export(deck)
        #expect(text.hasSuffix("\n"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        #expect(object["cursorColor"] == deck.cursor && object["purple"] == deck.magenta && object["id"] == "deck-dark")
    }

    @Test func pastedSchemesAreReadWithAliasesAndDefaults() {
        var raw: [String: String] = ["name": " Imported ", "background": "#000", "foreground": "#ffffff", "cursorColor": "#ff0000", "purple": "#800080"]
        for slot in TerminalScheme.ansiSlots where slot != "magenta" { raw[slot] = "#123456" }
        let text = String(data: try! JSONSerialization.data(withJSONObject: raw), encoding: .utf8)!
        guard case .ok(let scheme) = TerminalColours.parse(text, taken: ["custom-1"]) else {
            Issue.record("expected a scheme")
            return
        }
        #expect(scheme.id == "custom-2")
        #expect(scheme.name == "Imported")
        #expect(scheme.cursor == "#ff0000")
        #expect(scheme.magenta == "#800080")
        #expect(scheme.cursorAccent == "#000000")
        #expect(scheme.selectionBackground == "#ffffff40")
    }

    @Test func pasteProblemsAreSaid() {
        #expect(TerminalColours.parse("{", taken: []) == .problem("That is not JSON — check for a missing brace or comma."))
        #expect(TerminalColours.parse("[1]", taken: []) == .problem("A scheme is a JSON object."))
        #expect(TerminalColours.parse(#"{"schemes":[]}"#, taken: []) == .problem("That file has no schemes in it."))
        #expect(TerminalColours.parse(##"{"background":"#000"}"##, taken: []) == .problem("That scheme has no text, cursor or black, and 15 more."))
        #expect(TerminalColours.parse(#"{"schemes":[{"name":"x"}]}"#, taken: []) != .problem("That file has no schemes in it."))
    }

    @Test func colourEditsKeepTheRestAndRefuseNonsense() {
        let edited = deck.with("red", "#ABC")
        #expect(edited.ansi[1] == "#aabbcc")
        #expect(edited.background == deck.background)
        #expect(deck.with("background", "red") == deck)
        #expect(edited.colour("red") == "#aabbcc")
        #expect(TerminalColours.alpha("#3b8fee29") == "29")
        #expect(TerminalColours.opaque("#3b8fee29") == "#3b8fee")
    }

    @Test func contrastAndLightnessAreSaid() {
        #expect(abs(TerminalColours.contrast("#ffffff", "#000000") - 21) < 0.01)
        #expect(TerminalColours.contrastLine(deck).hasSuffix("Deck Dark came with the app, so changing a colour makes you a copy of it."))
        #expect(TerminalColours.lightness(TerminalSchemes.app(dark: false)).hasPrefix("A light scheme."))
        #expect(TerminalColours.rowHelp(active: nil) == "Sessions follow the app’s own light and dark.")
        #expect(TerminalColours.chosenId([:]) == "follow-app")
    }
}
