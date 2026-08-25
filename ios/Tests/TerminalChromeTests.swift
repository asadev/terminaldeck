/**
 * The colours a session screen wears, and the two questions they answer.
 *
 * Asad: *"whatever the theme colour we decide to keep, in the black for example,
 * in the terminal… my header should be also dark black. Other than the buttons,
 * that top header should be also dark black, everything should be black, not just
 * base colour."*
 *
 * What a screenshot cannot check is the *rule*. Thirteen schemes ship, every one
 * of their twenty-one colours is editable, and somebody can invert a light one
 * into a dark one from inside the app — so a bar that reads well in the two
 * frames anybody thought to photograph proves nothing about the eleven they did
 * not. These cases walk **every** shipped scheme rather than Pure Black and
 * Solarized Light, which are only the two that were photographed.
 *
 * The other half is where the rule is allowed to be applied. Painting a
 * navigation bar and stating a colour scheme for a subtree are both global-ish
 * acts that are invisible in review and visible only by walking to another
 * screen and looking at it — the same shape of defect `AppearanceTests`'
 * source walk exists for, and answered the same way.
 */

import SwiftUI
import UIKit
import XCTest
@testable import TerminalDeck

final class TerminalChromeTests: XCTestCase {

    private let light = UITraitCollection(userInterfaceStyle: .light)
    private let dark = UITraitCollection(userInterfaceStyle: .dark)

    private func scheme(_ id: String) throws -> TerminalScheme {
        try XCTUnwrap(TerminalScheme.builtIns.first { $0.id == id }, "\(id) is not a shipped scheme")
    }

    // MARK: - Which side of the line the bar is on

    /**
     * Every shipped scheme pins the screen to the side of the line its own
     * background is on.
     *
     * This is the case the whole change turns on. The failure it forbids is the
     * obvious implementation — take the phone's appearance and dress the screen in
     * it — which is right on every scheme that happens to agree with the phone and
     * wrong on exactly the one he named: Pure Black with the phone in light.
     *
     * Checked against `isLight`, which is what the picker draws a preview's
     * hairline from, so a scheme cannot be light in one place and dark in the
     * other.
     */
    func testEveryShippedSchemePinsTheScreenToItsOwnSideOfTheLine() {
        for scheme in TerminalScheme.builtIns {
            XCTAssertEqual(TerminalChrome.pinnedStyle(scheme), scheme.isLight ? .light : .dark,
                           "\(scheme.id) reads as \(scheme.isLight ? "light" : "dark") in the picker "
                           + "and the screen has to agree with it")
        }
    }

    /// The two frames that were photographed, named, so a regression says which
    /// screen to open rather than only which assertion failed.
    func testTheOneHeNamedIsDarkAndTheLightestOneShippedIsLight() throws {
        XCTAssertEqual(TerminalChrome.pinnedStyle(try scheme(TerminalScheme.pureBlackID)), .dark)
        XCTAssertEqual(TerminalChrome.pinnedStyle(try scheme("solarized-light")), .light)
    }

    /**
     * **Following the app pins nothing, and that is load bearing.**
     *
     * `nil` is the default and the normal state — see `TerminalThemeStore.selected`
     * — and it means *keep taking the appearance from the phone*. Answering it with
     * a value would freeze the screen to whatever the phone said at the moment the
     * session was opened: an overridden trait does not change when the window's
     * does, so a phone crossing into dark at sunset would take the terminal with it
     * and leave the bar, the strip and the status bar behind.
     */
    func testFollowingTheAppPinsNothingSoThePhoneKeepsDeciding() {
        XCTAssertNil(TerminalChrome.pinnedStyle(nil),
                     "following the app is a refusal to pin, not a third value")
    }

    /// The app's own two schemes are the halves `follow-app` resolves to, and
    /// **pinning** one is a different act from following: choosing Deck Dark on a
    /// light phone has to look like the dark terminal it is.
    func testPinningTheAppsOwnSchemeIsStillAPinAndNotAFollow() throws {
        XCTAssertEqual(TerminalChrome.pinnedStyle(try scheme("deck-dark")), .dark)
        XCTAssertEqual(TerminalChrome.pinnedStyle(try scheme("deck-light")), .light)
    }

    /// A scheme carrying the sentinel id is the sentinel, wherever it came from.
    /// `TerminalThemeStore.selected` hands back `nil` for it and every caller in
    /// the app goes through that — but a *value* wearing the id that means "do not
    /// pin" must not produce a pin, or the one guard standing between a hand-edited
    /// defaults file and a frozen appearance is the store rather than this.
    func testTheSentinelIdIsNeverAPinEvenAsAValue() throws {
        var sentinel = try scheme("deck-dark")
        sentinel.id = TerminalScheme.followAppID
        XCTAssertNil(TerminalChrome.pinnedStyle(sentinel))
    }

    // MARK: - The ink

    /**
     * Text on the bar is the scheme's own `foreground` — the colour the emulator
     * draws ordinary output in, on this very paper.
     *
     * Asserted against every shipped scheme in both trait collections, because a
     * pinned scheme has one answer and `Theme.primary` has two, and the whole
     * defect is a title that resolved to the wrong one.
     */
    func testTheBarsTextIsTheSchemesOwnForegroundInBothAppearances() {
        for scheme in TerminalScheme.builtIns {
            let expected = TerminalPalette.color(scheme.foreground)
            let ink = TerminalChrome.inkColor(scheme)
            XCTAssertEqual(ink.resolvedColor(with: light), expected, "\(scheme.id) in a light phone")
            XCTAssertEqual(ink.resolvedColor(with: dark), expected, "\(scheme.id) in a dark phone")
        }
    }

    /// The pairing on the bar is the pairing in the terminal, measured. Not a
    /// quality gate — `TerminalPalette.luminance`'s header is explicit that a
    /// scheme may be low contrast and that nothing refuses one — but a promise
    /// that this app has not made a scheme *worse* by putting words on it.
    func testTheBarNeverReadsWorseThanTheTerminalItIsOver() {
        for scheme in TerminalScheme.builtIns {
            // The colours the chrome actually resolves to, read back as hex — not
            // the ones the scheme declares. That is the difference between
            // checking the rule and restating the table.
            let paper = TerminalPalette.hex(TerminalPalette.dynamicBackground(scheme)
                .resolvedColor(with: light))
            let ink = TerminalPalette.hex(TerminalChrome.inkColor(scheme).resolvedColor(with: light))

            XCTAssertEqual(paper, TerminalPalette.normalized(scheme.background), "\(scheme.id) paper")
            XCTAssertEqual(ink, TerminalPalette.normalized(scheme.foreground), "\(scheme.id) ink")
            XCTAssertEqual(TerminalPalette.contrast(ink, paper),
                           TerminalPalette.contrast(scheme.foreground, scheme.background),
                           accuracy: 0.0001,
                           "\(scheme.id): the title on the bar is the same pairing as the output "
                           + "three points below it")
        }
    }

    /**
     * A half-typed colour leaves the title readable rather than invisible.
     *
     * A custom scheme is somebody's typing and a hex field holds `#12` for as long
     * as it takes to type the rest — `TerminalPalette`'s own reason for taking a
     * fallback instead of returning an optional. The fallback here is `.label`
     * rather than a constant, so what appears mid-keystroke is the system's own
     * readable ink and never `clear`, which is a bar with no title on it.
     */
    func testAHalfTypedForegroundFallsBackToSomethingReadableAndNotToNothing() throws {
        var broken = try scheme(TerminalScheme.pureBlackID)
        broken.foreground = "#12"
        let ink = TerminalChrome.inkColor(broken).resolvedColor(with: dark)
        XCTAssertEqual(ink, UIColor.label.resolvedColor(with: dark))
        var alpha: CGFloat = 0
        ink.getWhite(nil, alpha: &alpha)
        XCTAssertEqual(alpha, 1, accuracy: 0.001, "an invisible title is not a fallback")
    }

    /**
     * The quieter tier is the same ink at reduced strength, not the app's grey.
     *
     * `Theme.faint` is measured against the app's paper and says nothing about a
     * terminal's: on Pure Black under a light phone it is `#6a6a6a` on `#000000`.
     * Deriving the second tier from the first is what keeps the two lines of the
     * header a fixed distance apart on all thirteen.
     */
    func testTheQuieterTierIsTheSameInkAndNotTheAppsGrey() throws {
        let scheme = try scheme(TerminalScheme.pureBlackID)
        let ink = TerminalChrome.inkColor(scheme).resolvedColor(with: light)
        let dim = TerminalChrome.dimInkColor(scheme).resolvedColor(with: light)

        var inkRGBA = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        var dimRGBA = inkRGBA
        XCTAssertTrue(ink.getRed(&inkRGBA.r, green: &inkRGBA.g, blue: &inkRGBA.b, alpha: &inkRGBA.a))
        XCTAssertTrue(dim.getRed(&dimRGBA.r, green: &dimRGBA.g, blue: &dimRGBA.b, alpha: &dimRGBA.a))

        XCTAssertEqual(dimRGBA.r, inkRGBA.r, accuracy: 0.001, "the same colour")
        XCTAssertEqual(dimRGBA.g, inkRGBA.g, accuracy: 0.001)
        XCTAssertEqual(dimRGBA.b, inkRGBA.b, accuracy: 0.001)
        XCTAssertEqual(dimRGBA.a, TerminalChrome.dimmed, accuracy: 0.001, "only the strength differs")
        XCTAssertLessThan(TerminalChrome.dimmed, inkRGBA.a, "a second tier has to be quieter")
    }

    // MARK: - Where the rule is allowed to be applied

    /// The app's own sources, from this file's compile-time location. The same
    /// walk `AppearanceTests` makes, and for the same reason: a modifier on a
    /// screen nobody has navigated to has not run, so there is nothing to ask at
    /// runtime.
    private func appSources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)   // …/ios/Tests/TerminalChromeTests.swift
            .deletingLastPathComponent()             // …/ios/Tests
            .deletingLastPathComponent()             // …/ios
            .appendingPathComponent("TerminalDeck")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root,
                                                                     includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            files.append((url.lastPathComponent, text))
        }
        XCTAssertGreaterThan(files.count, 30, "the source walk found almost nothing to read at \(root.path)")
        return files
    }

    /// Lines of real code, with the comment lines dropped. Every rule in this
    /// section is discussed at length in prose — the history is the reason the
    /// rules exist — so only calls count.
    private func statements(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }
    }

    /**
     * **Exactly one file paints a navigation bar, and no file paints all of them.**
     *
     * `UINavigationBar.appearance()` is the obvious way to do what this feature
     * asks for and it is the trap: the proxy is global, so it repaints Sessions,
     * Browser and Menu as well, and it is retroactive, so it is not undone by
     * leaving the session. Undoing it by hand needs a moment that does not
     * reliably exist — a tab swap fires the arriving screen's `onAppear` without
     * firing the leaving screen's `onDisappear`, measured, and recorded in
     * `TerminalScreen.onDisappear`.
     *
     * The second half is drift rather than a bug: a `toolbarBackground` written on
     * a second screen would be a second, competing answer to the question of what
     * colour a bar is, and would be invisible until somebody walked to that screen
     * with an unusual scheme chosen.
     */
    func testOnlyTheTerminalsOwnChromePaintsANavigationBar() throws {
        var proxies: [String] = []
        var painters: Set<String> = []

        for file in try appSources() {
            for line in statements(in: file.text) {
                if line.contains("UINavigationBar.appearance(") {
                    proxies.append("\(file.name): \(line)")
                }
                if line.contains(".toolbarBackground(") {
                    painters.insert(file.name)
                }
            }
        }

        XCTAssertTrue(proxies.isEmpty,
                      "a global navigation-bar proxy repaints every screen in the app and is never "
                      + "undone:\n" + proxies.joined(separator: "\n"))
        XCTAssertEqual(painters, ["TerminalChrome.swift"],
                       "the colour of a navigation bar is decided in one place")
    }

    /**
     * **One file states an appearance for a subtree, and it is the session's
     * chrome.**
     *
     * `AppearanceTests.testNothingButTheRootStatesAColourScheme` holds the rule
     * about `.preferredColorScheme`, which is a *window*-level statement — and
     * measured on iOS 27, one written on a pushed screen is simply overruled by the
     * root's, so it is not even a way to do this. `transformEnvironment` is the
     * neighbouring modifier and a different act: it hands a subtree a value to
     * resolve dynamic colours against, it reaches nothing above itself, and it is
     * used here for one reason — the strip over a session and the conversation are
     * drawn on the *terminal's* paper, so light-or-dark for them is a fact about
     * the scheme he pinned rather than about the phone.
     *
     * Pinned to one file because a second one would be a screen quietly deciding
     * it knows better than his Appearance setting, which is the family of defect
     * the rule next door was written for. `.environment(\.colorScheme,·)` is
     * refused outright: it cannot express *state nothing*, which is exactly what
     * `follow-app` needs.
     */
    func testOnlyTheSessionsChromeStatesAnAppearanceForASubtree() throws {
        var transformers: Set<String> = []
        var setters: [String] = []
        for file in try appSources() {
            for line in statements(in: file.text) {
                if line.contains(".transformEnvironment(\\.colorScheme") {
                    transformers.insert(file.name)
                }
                if line.contains(".environment(\\.colorScheme") {
                    setters.append("\(file.name): \(line)")
                }
            }
        }
        XCTAssertEqual(transformers, ["TerminalChrome.swift"],
                       "the appearance of a session screen is decided in one place")
        XCTAssertTrue(setters.isEmpty,
                      "a plain environment value cannot state *nothing* for follow-app:\n"
                      + setters.joined(separator: "\n"))
    }

    /**
     * **No screen overrides an interface style, and the lock window is not a
     * screen.**
     *
     * `overrideUserInterfaceStyle` is what this feature was first written with and
     * it did nothing at all: a `UIViewControllerRepresentable` placed in a
     * screen's `.background` is handed a controller with **no parent, no
     * `navigationController` and no window** at `updateUIViewController` time —
     * logged from the simulator, `owner=nil nav=nil window=nil` — so every line of
     * it was inert while the screen looked half right for an unrelated reason.
     *
     * `AppLockShield` keeps its one, and it is a different thing: that window is
     * its own, made by this app, outside every SwiftUI modifier `RootView`
     * applies. See `Appearance.interfaceStyle`, which exists for that single
     * caller.
     */
    func testNoScreenOverridesAnInterfaceStyleAndTheLockWindowIsNotAScreen() throws {
        var users: Set<String> = []
        for file in try appSources() {
            for line in statements(in: file.text) where line.contains("overrideUserInterfaceStyle =") {
                users.insert(file.name)
            }
        }
        XCTAssertEqual(users, ["AppLockShield.swift"],
                       "an interface style overridden outside the lock's own window: \(users.sorted())")
    }
}
