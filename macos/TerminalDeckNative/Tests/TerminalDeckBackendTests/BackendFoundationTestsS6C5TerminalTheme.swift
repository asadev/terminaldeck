import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// terminal-theme.test.ts. Skipped: the two tokens.css drift cases (reads the renderer stylesheet), the xterm ITheme
/// typings case and the xtermTheme case (xterm/Electron only; native draws with its own colours), the not-a-string
/// refusal (the Swift API is typed String) and the null/array isTerminalScheme inputs.
final class BackendFoundationTestsS6C5TerminalTheme: XCTestCase {
    private func s6c5Scheme(_ id: String) -> TerminalScheme { TerminalSchemes.builtins.first { $0.id == id }! }
    private func s6c5Raw(_ scheme: TerminalScheme) -> [String: Any] {
        var raw: [String: Any] = ["name": scheme.name]
        for slot in TerminalColours.slots { raw[slot] = scheme.colour(slot) }
        return raw
    }

    // MARK: every scheme that ships

    func testEverySchemeStatesTwentyOneColoursAndEachIsAColour() {
        XCTAssertEqual(TerminalColours.slots.count, 21)
        for scheme in TerminalSchemes.builtins {
            XCTAssertEqual(scheme.ansi.count, 16, scheme.id)
            for slot in TerminalColours.slots { XCTAssertNotNil(TerminalColour.normalise(scheme.colour(slot)), "\(scheme.id).\(slot)") }
        }
    }

    func testEverySchemeIsNormalisedAlready() {
        for scheme in TerminalSchemes.builtins {
            for slot in TerminalColours.slots { XCTAssertEqual(scheme.colour(slot), TerminalColour.normalise(scheme.colour(slot)), "\(scheme.id).\(slot)") }
        }
    }

    func testUniqueIdAndUniqueName() {
        let ids = TerminalSchemes.builtins.map(\.id), names = TerminalSchemes.builtins.map(\.name)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testNeverClaimsTheIdThatMeansNoScheme() {
        XCTAssertFalse(TerminalColours.isBuiltin(TerminalSchemes.followApp))
        XCTAssertNil(TerminalSchemes.pinned(in: [TerminalSchemes.settingKey: TerminalSchemes.followApp]))
    }

    func testEachOneIsTheSideItsOwnNameClaims() {
        for scheme in TerminalSchemes.builtins {
            XCTAssertEqual(scheme.isLight, scheme.name.lowercased().contains("light"), scheme.name)
        }
    }

    func testReadableInkOnEveryGround() {
        for scheme in TerminalSchemes.builtins {
            XCTAssertGreaterThan(TerminalColours.contrast(scheme.foreground, scheme.background), 4, scheme.name)
        }
    }

    func testCursorSitsOnSomethingThatIsNotItself() {
        for scheme in TerminalSchemes.builtins {
            XCTAssertNotEqual(TerminalColours.opaque(scheme.cursor), TerminalColours.opaque(scheme.cursorAccent), scheme.name)
        }
    }

    func testNamesEverySlotOnScreen() {
        for slot in TerminalColours.slots {
            XCTAssertNotEqual(TerminalColours.labels[slot]?.trimmingCharacters(in: .whitespaces) ?? "", "", slot)
        }
        XCTAssertEqual(Set(TerminalColours.labels.values).count, TerminalColours.slots.count)
    }

    func testAppSchemeHandsBackEachAppearance() {
        XCTAssertEqual(TerminalSchemes.app(dark: true).id, "deck-dark")
        XCTAssertEqual(TerminalSchemes.app(dark: false).id, "deck-light")
    }

    // MARK: a colour, normalised

    func testExpandsShortFormsLikeCSS() {
        XCTAssertEqual(TerminalColour.normalise("#abc"), "#aabbcc")
        XCTAssertEqual(TerminalColour.normalise("#abcd"), "#aabbccdd")
    }

    func testLowerCasesAndTrims() {
        XCTAssertEqual(TerminalColour.normalise("  #FF00AA "), "#ff00aa")
    }

    func testKeepsEightDigitsForTheSelectionAlpha() {
        XCTAssertEqual(TerminalColour.normalise("#3b8fee29"), "#3b8fee29")
        XCTAssertEqual(TerminalColours.alpha("#3b8fee29"), "29")
        XCTAssertEqual(TerminalColours.alpha("#3b8fee"), "")
        XCTAssertEqual(TerminalColours.opaque("#3b8fee29"), "#3b8fee")
    }

    func testRefusesAnythingThatIsNotHex() {
        for value in ["red", "rgb(1,2,3)", "url(x)", "javascript:alert(1)", "#12345", "#gggggg", "", "#"] {
            XCTAssertNil(TerminalColour.normalise(value), value)
        }
    }

    func testLeavesASchemeAloneWhenTheValueIsHalfTyped() {
        let scheme = TerminalSchemes.builtins[0]
        XCTAssertEqual(scheme.with("red", "#ff"), scheme)
        XCTAssertEqual(scheme.with("red", "#ff0000").colour("red"), "#ff0000")
    }

    // MARK: reading a pasted scheme

    func testTakesThisAppsOwnExportBack() throws {
        let nord = s6c5Scheme("nord")
        guard case .ok(let scheme) = TerminalColours.parse(TerminalColours.export(nord), taken: []) else { return XCTFail("not ok") }
        for slot in TerminalColours.slots { XCTAssertEqual(scheme.colour(slot), nord.colour(slot), slot) }
        XCTAssertEqual(scheme.name, "Nord")
    }

    func testTakesTheAliasSpellings() {
        let text = """
        {"name":"Elsewhere","background":"#101010","foreground":"#e0e0e0","cursorColor":"#ffcc00","selectionBackground":"#333333",
        "black":"#000000","red":"#ff0000","green":"#00ff00","yellow":"#ffff00","blue":"#0000ff","purple":"#ff00ff","cyan":"#00ffff",
        "white":"#cccccc","brightBlack":"#666666","brightRed":"#ff6666","brightGreen":"#66ff66","brightYellow":"#ffff66",
        "brightBlue":"#6666ff","brightPurple":"#ff66ff","brightCyan":"#66ffff","brightWhite":"#ffffff"}
        """
        guard case .ok(let scheme) = TerminalColours.parse(text, taken: []) else { return XCTFail("not ok") }
        XCTAssertEqual(scheme.cursor, "#ffcc00")
        XCTAssertEqual(scheme.magenta, "#ff00ff")
        XCTAssertEqual(scheme.brightMagenta, "#ff66ff")
    }

    func testTakesTheFirstSchemeOutOfAFileOfThem() throws {
        let canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(TerminalColours.export(s6c5Scheme("nord")).utf8)))
        let wrapped = String(decoding: try JSONSerialization.data(withJSONObject: ["schemes": [canonical]]), as: UTF8.self)
        guard case .ok(let scheme) = TerminalColours.parse(wrapped, taken: []) else { return XCTFail("not ok") }
        XCTAssertEqual(scheme.name, "Nord")
    }

    func testFillsInCursorGroundAndSelectionWhenAbsent() throws {
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(TerminalColours.export(s6c5Scheme("nord")).utf8)) as? [String: Any])
        raw["cursorAccent"] = nil; raw["selectionBackground"] = nil
        let text = String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
        guard case .ok(let scheme) = TerminalColours.parse(text, taken: []) else { return XCTFail("not ok") }
        XCTAssertEqual(scheme.cursorAccent, scheme.background)
        XCTAssertNotNil(TerminalColour.normalise(scheme.selectionBackground))
    }

    func testNeverTakesAnIdFromTheFile() throws {
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(TerminalColours.export(s6c5Scheme("nord")).utf8)) as? [String: Any])
        raw["id"] = "nord"
        let text = String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
        guard case .ok(let scheme) = TerminalColours.parse(text, taken: ["custom-1"]) else { return XCTFail("not ok") }
        XCTAssertEqual(scheme.id, "custom-2")
    }

    func testNamesWhatIsMissingRatherThanSayingNo() {
        guard case .problem(let why) = TerminalColours.parse(##"{ "name": "Half", "background": "#101010", "foreground": "#eeeeee" }"##, taken: []) else { return XCTFail("ok") }
        XCTAssertTrue(why.contains("cursor"))
        XCTAssertTrue(why.contains("black"))
    }

    func testSaysSoWhenItIsNotJSONAtAll() {
        guard case .problem(let why) = TerminalColours.parse("{ nope", taken: []) else { return XCTFail("ok") }
        XCTAssertTrue(why.contains("JSON"))
    }

    func testRefusesAColourThatIsNotOne() throws {
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(TerminalColours.export(s6c5Scheme("nord")).utf8)) as? [String: Any])
        raw["red"] = "javascript:x"
        let text = String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
        guard case .problem = TerminalColours.parse(text, taken: []) else { return XCTFail("accepted") }
    }

    func testExportsSomethingTheOtherSpellingCanReadToo() throws {
        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(TerminalColours.export(s6c5Scheme("dracula")).utf8)) as? [String: String])
        XCTAssertEqual(out["cursorColor"], out["cursor"])
        XCTAssertEqual(out["purple"], out["magenta"])
        XCTAssertEqual(out["brightPurple"], out["brightMagenta"])
    }

    // MARK: the schemes somebody makes

    func testCopiesUnderANameThatSaysWhoseItIsWithoutStackingTheSuffix() {
        XCTAssertEqual(TerminalColours.copyName("Nord"), "Nord (yours)")
        XCTAssertEqual(TerminalColours.copyName("Nord (yours)"), "Nord (yours)")
    }

    func testTakesAnIdNothingElseIsUsingFillingGaps() {
        XCTAssertEqual(TerminalColours.newCustomId([]), "custom-1")
        XCTAssertEqual(TerminalColours.newCustomId(["custom-1", "custom-2"]), "custom-3")
        XCTAssertEqual(TerminalColours.newCustomId(["custom-1", "custom-3"]), "custom-2")
    }

    func testIsACopyOfTheColoursNotAReference() {
        let nord = s6c5Scheme("nord"), copy = TerminalColours.copy(nord, taken: [])
        XCTAssertNotEqual(copy.id, nord.id)
        XCTAssertEqual(copy.name, "Nord (yours)")
        for slot in TerminalColours.slots { XCTAssertEqual(copy.colour(slot), nord.colour(slot), slot) }
    }

    func testReadsBackOffTheSettingsMapUnderItsOwnKey() {
        let nord = s6c5Scheme("nord")
        let mine = TerminalColours.copy(nord, taken: []).renamed(name: "Mine")
        let values: [String: Any] = [TerminalSchemes.customPrefix + mine.id: TerminalColours.stored(mine), "appearance.density": "compact"]
        let back = TerminalSchemes.customs(in: values)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].id, mine.id)
        XCTAssertEqual(back[0].name, "Mine")
        XCTAssertEqual(back[0].colour("brightCyan"), nord.colour("brightCyan"))
    }

    func testTakesItsIdFromTheKeyItWasStoredUnder() {
        let lying = TerminalColours.copy(s6c5Scheme("nord"), taken: []).renamed(id: "lying", name: "X")
        let values: [String: Any] = [TerminalSchemes.customPrefix + "elsewhere": TerminalColours.stored(lying)]
        XCTAssertEqual(TerminalSchemes.customs(in: values).first?.id, "elsewhere")
    }

    func testSkipsADamagedKeyRatherThanLosingTheRest() {
        let mine = TerminalColours.copy(s6c5Scheme("nord"), taken: [])
        let values: [String: Any] = [
            TerminalSchemes.customPrefix + "broken": "{ not json",
            TerminalSchemes.customPrefix + "empty": "",
            TerminalSchemes.customPrefix + "partial": ##"{"name":"Half","background":"#000000"}"##,
            TerminalSchemes.customPrefix + mine.id: TerminalColours.stored(mine),
        ]
        XCTAssertEqual(TerminalSchemes.customs(in: values).map(\.id), [mine.id])
    }

    func testSortsByNameSoTheListDoesNotReorder() {
        let nord = s6c5Scheme("nord")
        let values: [String: Any] = [
            TerminalSchemes.customPrefix + "a": TerminalColours.stored(nord.renamed(name: "Zephyr")),
            TerminalSchemes.customPrefix + "b": TerminalColours.stored(nord.renamed(name: "Amber")),
        ]
        XCTAssertEqual(TerminalSchemes.customs(in: values).map(\.name), ["Amber", "Zephyr"])
    }

    func testStoresWellUnderTheSettingsFilesSilentCut() {
        for scheme in TerminalSchemes.builtins { XCTAssertLessThan(TerminalColours.stored(scheme).count, 2048, scheme.name) }
    }

    func testACustomWinsALookupAgainstABuiltInOfTheSameId() {
        let mine = s6c5Scheme("nord").renamed(id: "nord", name: "Not really Nord")
        let values: [String: Any] = [TerminalSchemes.settingKey: "nord", TerminalSchemes.customPrefix + "nord": TerminalColours.stored(mine)]
        XCTAssertEqual(TerminalSchemes.pinned(in: values)?.name, "Not really Nord")
    }

    func testOnlyASchemeWhenEveryColourIsThere() {
        let nord = s6c5Scheme("nord")
        XCTAssertNotNil(TerminalSchemes.scheme(id: "x", from: s6c5Raw(nord)))
        var teal = s6c5Raw(nord); teal["brightCyan"] = "teal"
        XCTAssertNil(TerminalSchemes.scheme(id: "x", from: teal))
        var unnamed = s6c5Raw(nord); unnamed["name"] = ""
        XCTAssertNil(TerminalSchemes.scheme(id: "x", from: unnamed))
    }

    func testHoldsANameToOneLineOfOrdinaryText() {
        XCTAssertEqual(TerminalColours.cleanName("  Two   words  "), "Two words")
        XCTAssertEqual(TerminalColours.cleanName(String(repeating: "x", count: 200)).count, 48)
    }
}
