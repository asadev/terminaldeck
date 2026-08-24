/**
 * The scheme table, the store that holds a choice, and the one test that keeps
 * this file honest about being a mirror.
 *
 * `testEveryBuiltInMatchesTheSharedTable` reads
 * `src/shared/terminal-theme.ts` off disk and compares it entry for entry with
 * the Swift. It is the only thing standing between "the same scheme on every
 * screen" and two products drifting apart one hex at a time, and it is why
 * nothing in `TerminalScheme` may be edited without editing the TypeScript.
 *
 * It skips when the file is absent rather than failing, which is a deliberate
 * and narrow allowance: this lane and the desktop's are cut from the same tip
 * and the shared file arrives with whichever merges first. A skip says so out
 * loud in the log. Everything else here runs unconditionally.
 */

import XCTest
@testable import TerminalDeck

final class TerminalSchemeTests: XCTestCase {

    // MARK: - Parity with the shared file

    /// The repository, found from this source file's own path at compile time.
    /// The simulator can read it: a test bundle runs on the host's filesystem.
    private static var sharedThemeFile: URL {
        URL(fileURLWithPath: #filePath)          // ios/Tests/TerminalSchemeTests.swift
            .deletingLastPathComponent()         // ios/Tests
            .deletingLastPathComponent()         // ios
            .deletingLastPathComponent()         // repo
            .appendingPathComponent("src/shared/terminal-theme.ts")
    }

    func testEveryBuiltInMatchesTheSharedTable() throws {
        let url = Self.sharedThemeFile
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("src/shared/terminal-theme.ts is not in this tree yet — "
                          + "the desktop lane creates it. Nothing is asserted about parity.")
        }

        let table = try Self.parseBuiltIns(source)
        XCTAssertEqual(table.map(\.id), TerminalScheme.builtIns.map(\.id),
                       "the schemes, or their order, differ from the shared file")

        for expected in table {
            guard let actual = TerminalScheme.builtIns.first(where: { $0.id == expected.id }) else {
                XCTFail("\(expected.id) is in the shared file and not in Swift")
                continue
            }
            XCTAssertEqual(actual.name, expected.name, "\(expected.id): name")
            for slot in ColourSlot.allCases {
                XCTAssertEqual(actual[slot], expected.colours[slot.rawValue],
                               "\(expected.id).\(slot.rawValue)")
            }
        }
    }

    func testTheSharedFilesConstantsMatch() throws {
        let url = Self.sharedThemeFile
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("src/shared/terminal-theme.ts is not in this tree yet.")
        }
        XCTAssertEqual(Self.stringConstant("FOLLOW_APP_SCHEME_ID", in: source),
                       TerminalScheme.followAppID)
        XCTAssertEqual(Self.numberConstant("MAX_CUSTOM_SCHEMES", in: source),
                       TerminalScheme.maxCustomSchemes)
        XCTAssertEqual(Self.numberConstant("MAX_SCHEME_NAME", in: source),
                       TerminalScheme.maxNameLength)
    }

    // MARK: - The table's own invariants

    func testEveryColourInEveryBuiltInIsAColour() {
        for scheme in TerminalScheme.builtIns {
            for slot in ColourSlot.allCases {
                XCTAssertTrue(TerminalPalette.isColor(scheme[slot]),
                              "\(scheme.id).\(slot.rawValue) is \(scheme[slot])")
            }
        }
    }

    func testIdsAndNamesAreUnique() {
        XCTAssertEqual(Set(TerminalScheme.builtIns.map(\.id)).count, TerminalScheme.builtIns.count)
        XCTAssertEqual(Set(TerminalScheme.builtIns.map(\.name)).count, TerminalScheme.builtIns.count)
    }

    /// `follow-app` is a refusal to pin a scheme, not a scheme. In the list it
    /// would be a row that can be edited and copied, and copying it would
    /// produce a scheme whose colours nobody chose.
    func testFollowAppIsNotOneOfTheSchemes() {
        XCTAssertNil(TerminalScheme.builtIns.first { $0.id == TerminalScheme.followAppID })
    }

    /// The one Asad named, and the only reason it is worth a test of its own is
    /// that "pure black" is a claim about a specific value: an OLED panel
    /// switches `#000000` off and lights everything else.
    func testPureBlackIsActuallyBlack() {
        let scheme = TerminalScheme.builtIns.first { $0.id == TerminalScheme.pureBlackID }
        XCTAssertEqual(scheme?.background, "#000000")
        XCTAssertEqual(TerminalPalette.luminance("#000000"), 0)
    }

    func testTheAppsOwnTwoAreThereUnderTheNamesTheResolverAsksFor() {
        XCTAssertEqual(TerminalScheme.app(dark: true).id, "deck-dark")
        XCTAssertEqual(TerminalScheme.app(dark: false).id, "deck-light")
    }

    /// The sixteen are read out in wire order, and the subscript is what the
    /// editor writes through — so a swapped pair here would ship as an agent's
    /// diff in the wrong colour with every test still green.
    func testTheSixteenComeOutInWireOrder() {
        let nord = TerminalScheme.builtIns.first { $0.id == "nord" }!
        XCTAssertEqual(nord.ansi.count, 16)
        XCTAssertEqual(nord.ansi[0], nord.black)
        XCTAssertEqual(nord.ansi[6], nord.cyan)
        XCTAssertEqual(nord.ansi[8], nord.brightBlack)
        XCTAssertEqual(nord.ansi[15], nord.brightWhite)
    }

    func testLightSchemesKnowTheyAreLight() {
        for id in ["solarized-light", "one-half-light", "deck-light"] {
            XCTAssertTrue(TerminalScheme.builtIns.first { $0.id == id }!.isLight, id)
        }
        for id in ["pure-black", "dracula", "nord", "deck-dark", "campbell"] {
            XCTAssertFalse(TerminalScheme.builtIns.first { $0.id == id }!.isLight, id)
        }
    }

    // MARK: - Colours

    func testAColourIsReadInEveryFormPeopleWriteItIn() {
        XCTAssertEqual(TerminalPalette.normalized("#8BF"), "#88bbff")
        XCTAssertEqual(TerminalPalette.normalized("#8be9fd"), "#8be9fd")
        XCTAssertEqual(TerminalPalette.normalized("#3b8fee29"), "#3b8fee29")
        XCTAssertEqual(TerminalPalette.normalized("#8bfa"), "#88bbffaa")
        XCTAssertEqual(TerminalPalette.normalized("  #8BE9FD  "), "#8be9fd")
    }

    /// Refusing is the point. A scheme is stored as text and can be hand-edited,
    /// so this function is the whole of what stands between that file and the
    /// emulator's theme.
    func testAnythingElseIsNotAColour() {
        for text in ["red", "8be9fd", "#8b", "#8be9f", "#8be9fdff0", "", "#", "#gggggg",
                     "rgb(1,2,3)", "javascript:alert(1)"] {
            XCTAssertNil(TerminalPalette.normalized(text), text)
            XCTAssertFalse(TerminalPalette.isColor(text), text)
        }
    }

    func testTheAlphaSurvivesAndIsSeparable() {
        XCTAssertEqual(TerminalPalette.opaquePart("#3b8fee29"), "#3b8fee")
        XCTAssertEqual(TerminalPalette.alphaPart("#3b8fee29"), "29")
        XCTAssertEqual(TerminalPalette.alphaPart("#3b8fee"), "")
        XCTAssertEqual(TerminalPalette.components("#3b8fee29")?.alpha, 0x29)
        XCTAssertEqual(TerminalPalette.components("#3b8fee")?.alpha, 255)
    }

    /// A half-typed hex must not paint. The fallback is what the caller was
    /// already using, so a terminal cannot go black while somebody is still
    /// typing the colour they wanted.
    func testAHalfTypedColourFallsBackRatherThanPainting() {
        XCTAssertEqual(TerminalPalette.color("#8b", fallback: .red), .red)
        XCTAssertNotEqual(TerminalPalette.color("#8be9fd", fallback: .red), .red)
    }

    // MARK: - Resolving

    /// Nothing pinned means *follow the app*, which is what every install has
    /// been on since this app existed.
    func testNothingPinnedFollowsTheAppearance() {
        XCTAssertEqual(TerminalPalette.resolved(nil, style: .dark).id, "deck-dark")
        XCTAssertEqual(TerminalPalette.resolved(nil, style: .light).id, "deck-light")
        // `.unspecified` is dark, which is what this app has always drawn.
        XCTAssertEqual(TerminalPalette.resolved(nil, style: .unspecified).id, "deck-dark")
    }

    /**
     * A chosen scheme is absolute, and this is the assertion that says so.
     *
     * A terminal that threw away Solarized Light because the phone crossed into
     * dark at sunset would be the app overruling the one choice the picker
     * exists to offer.
     */
    func testAChosenSchemeIgnoresTheAppearance() {
        let solarized = TerminalScheme.builtIns.first { $0.id == "solarized-light" }!
        XCTAssertEqual(TerminalPalette.resolved(solarized, style: .dark).background, "#fdf6e3")
        XCTAssertEqual(TerminalPalette.resolved(solarized, style: .light).background, "#fdf6e3")

        let black = TerminalScheme.builtIns.first { $0.id == TerminalScheme.pureBlackID }!
        XCTAssertEqual(TerminalPalette.resolved(black, style: .light).background, "#000000")
    }

    // MARK: - The store

    private func store() -> TerminalThemeStore {
        let defaults = UserDefaults(suiteName: "scheme.\(UUID().uuidString)")!
        return TerminalThemeStore(defaults: defaults, center: NotificationCenter())
    }

    func testAFreshPhoneFollowsTheApp() {
        let themes = store()
        XCTAssertTrue(themes.isFollowingApp)
        XCTAssertNil(themes.selected)
        XCTAssertEqual(themes.selectedID, TerminalScheme.followAppID)
        XCTAssertEqual(themes.selectedName, "Follow the app")
    }

    func testChoosingPureBlackSticks() {
        let themes = store()
        themes.select(TerminalScheme.pureBlackID)
        XCTAssertEqual(themes.selected?.background, "#000000")
        XCTAssertFalse(themes.isFollowingApp)
        themes.followApp()
        XCTAssertTrue(themes.isFollowingApp)
    }

    func testAChoiceSurvivesARelaunch() {
        let suite = "scheme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        TerminalThemeStore(defaults: defaults, center: NotificationCenter()).select("nord")
        // A second store over the same defaults is what the next launch is.
        let reopened = TerminalThemeStore(defaults: defaults, center: NotificationCenter())
        XCTAssertEqual(reopened.selectedID, "nord")
    }

    func testAnIdNamingNothingFallsBackToFollowingTheApp() {
        let defaults = UserDefaults(suiteName: "scheme.\(UUID().uuidString)")!
        defaults.set("a-scheme-that-was-deleted", forKey: "terminaldeck.terminalScheme.v1")
        let themes = TerminalThemeStore(defaults: defaults, center: NotificationCenter())
        XCTAssertNil(themes.selected)
        XCTAssertTrue(themes.isFollowingApp)
    }

    // MARK: - Copies

    func testEditingABuiltInMakesACopyAndLeavesTheOriginalAlone() {
        let themes = store()
        let dracula = TerminalScheme.builtIns.first { $0.id == "dracula" }!
        let copy = themes.copying(dracula)
        XCTAssertEqual(copy?.id, "custom-1")
        XCTAssertEqual(copy?.name, "Dracula (yours)")
        XCTAssertEqual(copy?.background, dracula.background)
        XCTAssertFalse(copy!.isBuiltIn)

        themes.update(copy!.with(.background, "#010203"))
        XCTAssertEqual(themes.scheme(id: "custom-1")?.background, "#010203")
        // The published palette is untouched, which is the only way "Dracula"
        // can go on meaning Dracula.
        XCTAssertEqual(themes.scheme(id: "dracula")?.background, "#282a36")
    }

    func testCopyingACopyDoesNotStackTheSuffix() {
        let themes = store()
        let first = themes.copying(TerminalScheme.builtIns.first { $0.id == "nord" }!)!
        let second = themes.copying(first)!
        XCTAssertEqual(first.name, "Nord (yours)")
        XCTAssertEqual(second.name, "Nord (yours)")
        XCTAssertEqual(second.id, "custom-2")
    }

    func testABuiltInCannotBeWrittenOver() {
        let themes = store()
        let nord = TerminalScheme.builtIns.first { $0.id == "nord" }!
        themes.update(nord.with(.background, "#ff0000"))
        XCTAssertEqual(themes.scheme(id: "nord")?.background, "#2e3440")
        XCTAssertTrue(themes.customs.isEmpty, "an update of a built-in must not add a scheme")
    }

    func testHalfATypedHexLeavesTheSchemeAlone() {
        let nord = TerminalScheme.builtIns.first { $0.id == "nord" }!
        XCTAssertEqual(nord.with(.red, "#8b").red, nord.red)
        XCTAssertEqual(nord.with(.red, "#8be9fd").red, "#8be9fd")
        // And a shorthand is expanded on the way in, so the table and a typed
        // value compare as strings.
        XCTAssertEqual(nord.with(.red, "#8BF").red, "#88bbff")
    }

    func testRenamingAndTheNamesThatAreRefused() {
        let themes = store()
        let copy = themes.copying(TerminalScheme.builtIns[0])!
        themes.rename(copy.id, to: "  Night   shift  ")
        XCTAssertEqual(themes.scheme(id: copy.id)?.name, "Night shift")

        // Nothing but whitespace is not a name; a nameless row in a picker
        // cannot be told from a bug.
        themes.rename(copy.id, to: "   ")
        XCTAssertEqual(themes.scheme(id: copy.id)?.name, "Night shift")

        themes.rename(copy.id, to: String(repeating: "x", count: 200))
        XCTAssertEqual(themes.scheme(id: copy.id)?.name.count, TerminalScheme.maxNameLength)
    }

    func testDeletingTheOneInUseGoesBackToFollowingTheApp() {
        let themes = store()
        let copy = themes.copying(TerminalScheme.builtIns[0])!
        themes.select(copy.id)
        themes.delete(copy.id)
        XCTAssertTrue(themes.isFollowingApp)
        XCTAssertNil(themes.scheme(id: copy.id))
    }

    func testDeletingOneNotInUseLeavesTheChoiceAlone() {
        let themes = store()
        let copy = themes.copying(TerminalScheme.builtIns[0])!
        themes.select("nord")
        themes.delete(copy.id)
        XCTAssertEqual(themes.selectedID, "nord")
    }

    func testThereIsACeilingOnCopies() {
        let themes = store()
        for _ in 0 ..< TerminalScheme.maxCustomSchemes {
            XCTAssertNotNil(themes.copying(TerminalScheme.builtIns[0]))
        }
        XCTAssertNil(themes.copying(TerminalScheme.builtIns[0]),
                     "the ceiling has to refuse rather than silently do nothing")
        XCTAssertEqual(themes.customs.count, TerminalScheme.maxCustomSchemes)
    }

    // MARK: - What comes back off disk

    /**
     * A stored record is input.
     *
     * It was written by this app but not necessarily by this *build* of it, and
     * on a simulator it can be edited by hand. A custom that shadows a shipped
     * id would be a scheme nobody could delete; one with `"red"` in a slot would
     * paint a hole in the terminal.
     */
    func testARecordThatIsNotASchemeIsDroppedOnTheWayIn() {
        let defaults = UserDefaults(suiteName: "scheme.\(UUID().uuidString)")!
        var shadow = TerminalScheme.builtIns.first { $0.id == "nord" }!
        shadow.id = "nord"
        shadow.background = "#ff0000"
        var broken = TerminalScheme.builtIns[0]
        broken.id = "custom-9"
        broken.red = "not a colour"
        var good = TerminalScheme.builtIns[0]
        good.id = "custom-8"
        good.name = "   "
        defaults.set(try! JSONEncoder().encode([shadow, broken, good]),
                     forKey: "terminaldeck.terminalSchemes.custom.v1")

        let themes = TerminalThemeStore(defaults: defaults, center: NotificationCenter())
        XCTAssertEqual(themes.customs.map(\.id), ["custom-8"])
        XCTAssertEqual(themes.scheme(id: "nord")?.background, "#2e3440",
                       "a stored record must not be able to shadow a shipped palette")
        XCTAssertEqual(themes.customs.first?.name, "Untitled")
    }

    // MARK: - Announcing

    /// The notification is the whole of *applies live*: with it absent the
    /// picker still works, still saves and still looks right on the next
    /// session, and the terminal already on screen keeps yesterday's colours.
    func testEveryChangeAnnouncesItself() {
        let center = NotificationCenter()
        let defaults = UserDefaults(suiteName: "scheme.\(UUID().uuidString)")!
        let themes = TerminalThemeStore(defaults: defaults, center: center)

        var announcements = 0
        let token = center.addObserver(forName: .terminalSchemeChanged, object: nil, queue: nil) { _ in
            announcements += 1
        }
        defer { center.removeObserver(token) }

        themes.select("nord")
        let copy = themes.copying(TerminalScheme.builtIns[0])!
        themes.update(copy.with(.background, "#010203"))
        themes.rename(copy.id, to: "Mine")
        themes.delete(copy.id)
        XCTAssertEqual(announcements, 5)

        // Choosing what is already chosen is not a change, and a store that
        // announced it would repaint a terminal on every tap of the row that is
        // already ticked.
        themes.select("nord")
        XCTAssertEqual(announcements, 5)
    }

    // MARK: - Reading the TypeScript

    private struct ParsedScheme {
        let id: String
        let name: String
        let colours: [String: String]
    }

    /// Every `{ … }` in `BUILTIN_SCHEMES`, with `...APP_ANSI_*` expanded. Block
    /// comments are stripped first: they are the only thing in that region that
    /// could carry a brace or a quote and confuse the scan.
    private static func parseBuiltIns(_ source: String) throws -> [ParsedScheme] {
        let text = stripBlockComments(source)
        let dark = try constObject("APP_ANSI_DARK", in: text)
        let light = try constObject("APP_ANSI_LIGHT", in: text)
        let spreads = ["APP_ANSI_DARK": dark, "APP_ANSI_LIGHT": light]

        guard let arrayStart = text.range(of: "BUILTIN_SCHEMES: readonly TerminalScheme[] = [") else {
            throw Failure("BUILTIN_SCHEMES is not in the shared file in the shape this test reads")
        }
        var schemes: [ParsedScheme] = []
        var depth = 0
        var current = ""
        for character in text[arrayStart.upperBound...] {
            if character == "]" && depth == 0 { break }
            if character == "{" {
                depth += 1
                if depth == 1 { current = ""; continue }
            }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    schemes.append(try scheme(from: current, spreads: spreads))
                    continue
                }
            }
            if depth > 0 { current.append(character) }
        }
        return schemes
    }

    private static func scheme(from body: String,
                               spreads: [String: [String: String]]) throws -> ParsedScheme {
        var colours: [String: String] = [:]
        for name in spreads.keys where body.contains("...\(name),") {
            colours.merge(spreads[name]!) { _, new in new }
        }
        var id = "", name = ""
        for (key, value) in pairs(body) {
            switch key {
            case "id": id = value
            case "name": name = value
            default: colours[key] = value
            }
        }
        guard !id.isEmpty else { throw Failure("a scheme in the shared file has no id") }
        return ParsedScheme(id: id, name: name, colours: colours)
    }

    private static func constObject(_ name: String, in text: String) throws -> [String: String] {
        guard let start = text.range(of: "const \(name) = {"),
              let end = text.range(of: "} as const", range: start.upperBound ..< text.endIndex) else {
            throw Failure("\(name) is not in the shared file")
        }
        return Dictionary(uniqueKeysWithValues: pairs(String(text[start.upperBound ..< end.lowerBound])))
    }

    /// `key: 'value'` pairs. Deliberately only single-quoted strings — every
    /// colour and every name in that file is one, and matching anything looser
    /// would start picking up prose.
    private static func pairs(_ text: String) -> [(String, String)] {
        let pattern = try! NSRegularExpression(pattern: "([A-Za-z]+):\\s*'([^']*)'")
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            guard let key = Range(match.range(at: 1), in: text),
                  let value = Range(match.range(at: 2), in: text) else { return nil }
            return (String(text[key]), String(text[value]))
        }
    }

    private static func stringConstant(_ name: String, in text: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: "\(name)\\s*=\\s*'([^']*)'")
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range),
              let value = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[value])
    }

    private static func numberConstant(_ name: String, in text: String) -> Int? {
        let pattern = try! NSRegularExpression(pattern: "\(name)\\s*=\\s*(\\d+)")
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range),
              let value = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[value])
    }

    private static func stripBlockComments(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("/*"),
               let close = text.range(of: "*/", range: index ..< text.endIndex) {
                index = close.upperBound
                continue
            }
            out.append(text[index])
            index = text.index(after: index)
        }
        return out
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
