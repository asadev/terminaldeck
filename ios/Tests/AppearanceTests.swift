/**
 * The appearance setting, the palette behind it, and the three pins that used to
 * hold this app dark.
 *
 * Asad: *"mobile iOS is only dark mode — it should have both, in settings."*
 *
 * Everything here is arithmetic on colours and a walk over the source, because
 * those are the two things about a theme that can be checked without a person
 * looking at it. What a person has to look at is in `AppearanceShotsUITests`,
 * which photographs every screen in both schemes and measures each frame. The
 * two suites are answering different questions and neither replaces the other:
 * this one says the numbers are right, that one says they arrived on screen.
 *
 * ## Why contrast is asserted rather than eyeballed
 *
 * A light theme fails quietly. Nothing throws, nothing looks broken in a
 * screenshot at 30% zoom, and the failure is a person squinting at a grey word
 * on a grey card a week later. Every ink in this palette is set on three
 * different surfaces somewhere in the app, so the assertion is over the whole
 * cross-product rather than over the pairing somebody thought of.
 */

import SwiftTerm
import SwiftUI
import UIKit
import XCTest
@testable import TerminalDeck

final class AppearanceTests: XCTestCase {

    // MARK: - The setting

    /// A store of its own, so a test never writes into the preferences of the
    /// simulator it happens to be running on.
    private func freshDefaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "appearance-tests.\(name)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testAPhoneThatHasChosenNothingFollowsTheSystem() throws {
        let defaults = try freshDefaults()
        XCTAssertEqual(Appearance.stored(in: defaults), .system)
        XCTAssertNil(Appearance.system.colorScheme,
                     "system must be no preference at all — a resolved value would stop tracking "
                     + "the phone the moment its own schedule crossed over")
    }

    func testAChoiceIsWrittenAndReadBack() throws {
        let defaults = try freshDefaults()
        for choice in Appearance.allCases {
            Appearance.save(choice, in: defaults)
            XCTAssertEqual(Appearance.stored(in: defaults), choice)
        }
    }

    func testAValueFromAnotherBuildFallsBackToTheSystem() throws {
        let defaults = try freshDefaults()
        defaults.set("sepia", forKey: Appearance.key)
        XCTAssertEqual(Appearance.stored(in: defaults), .system,
                       "a preference read off disk is input; junk must not leave the app in a "
                       + "scheme nobody chose")
    }

    func testTheTwoExplicitChoicesArePainted() {
        XCTAssertEqual(Appearance.light.colorScheme, .light)
        XCTAssertEqual(Appearance.dark.colorScheme, .dark)
        XCTAssertEqual(Appearance.allCases.map(\.label), ["System", "Light", "Dark"])
    }

    // MARK: - The three pins

    /**
     * `UIUserInterfaceStyle` is not in the bundle.
     *
     * The first and most important of the three, because it is the operating
     * system's own override: while it is there, every window in the process is
     * forced to that style before any view is consulted, so the setting cannot
     * work no matter what `RootView` states. It is checked against the built
     * bundle rather than the source file, because that is what actually ships
     * and because `project.yml` could put it back through a build setting
     * without `Info.plist` changing a character.
     */
    func testTheBundleDoesNotForceAnInterfaceStyle() {
        let value = Bundle.main.object(forInfoDictionaryKey: "UIUserInterfaceStyle")
        XCTAssertNil(value,
                     "Info.plist forces the interface style to \(value ?? "?"); the Appearance "
                     + "setting cannot work while it does")
    }

    /**
     * Exactly one view in this app states a colour scheme, and it is the root.
     *
     * The second pin was eleven `.preferredColorScheme(.dark)` calls spread over
     * nine files — the session detail, the alerts, the localhost browser, the
     * GitHub account, the inspect sheet, three copilot sheets, the credential
     * prompt and the root twice. Every one of them was invisible while the plist
     * pin was in place and every one of them would have silently ignored this
     * setting for its own screen the moment it came out.
     *
     * A source walk rather than a runtime check, because there is nothing to ask
     * at runtime: a modifier on a screen nobody has navigated to has not run
     * yet. `#filePath` is the compile-time location of this file, which gives
     * the checkout; a simulator process can read the Mac's filesystem, which is
     * how `LiveTransferUITests` already verifies uploads that landed on the Mac.
     */
    func testNothingButTheRootStatesAColourScheme() throws {
        let sources = URL(fileURLWithPath: #filePath)     // …/ios/Tests/AppearanceTests.swift
            .deletingLastPathComponent()                  // …/ios/Tests
            .deletingLastPathComponent()                  // …/ios
            .appendingPathComponent("TerminalDeck")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources,
                                                                     includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var rootStatesIt = false
        var scanned = 0

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Comments talk about this modifier at length on purpose — the
                // history is the reason the rule exists — so only real calls
                // count.
                guard trimmed.hasPrefix(".preferredColorScheme(") else { continue }
                if url.lastPathComponent == "RootView.swift" {
                    rootStatesIt = true
                    XCTAssertTrue(trimmed.contains("appearance.colorScheme"),
                                  "the root must state the *setting*, not a constant: \(trimmed)")
                } else {
                    offenders.append("\(url.lastPathComponent): \(trimmed)")
                }
            }
        }

        XCTAssertGreaterThan(scanned, 30, "the source walk found almost nothing to read at \(sources.path)")
        XCTAssertTrue(rootStatesIt, "RootView should be the one place the scheme is stated")
        XCTAssertTrue(offenders.isEmpty,
                      "a screen is overriding the appearance setting for itself:\n"
                      + offenders.joined(separator: "\n"))
    }

    /**
     * No view paints a raw white tint either.
     *
     * The third pin was not a modifier, it was an assumption: a wash written as
     * `Color.white.opacity(0.06)` is a pressed state in the dark theme and
     * nothing at all on paper. Two rows in this app had one. This is the same
     * check as above for the same reason — it is a defect that looks perfectly
     * correct in the half of the app anybody was looking at.
     */
    func testNothingTintsWithRawWhite() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TerminalDeck")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources,
                                                                     includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            // Theme.swift is where a literal is allowed to be — it is the file
            // that turns literals into a palette.
            guard url.lastPathComponent != "Theme.swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false)
            where line.contains("Color.white.opacity") || line.contains("UIColor(white:") {
                offenders.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "a white tint is invisible on paper — use a token that flips:\n"
                      + offenders.joined(separator: "\n"))
    }

    // MARK: - The palette

    private static let light = UITraitCollection(userInterfaceStyle: .light)
    private static let dark = UITraitCollection(userInterfaceStyle: .dark)

    private func rgb(_ color: SwiftUI.Color, _ traits: UITraitCollection) -> (r: Double, g: Double, b: Double) {
        rgb(UIColor(color), traits)
    }

    private func rgb(_ color: UIColor, _ traits: UITraitCollection) -> (r: Double, g: Double, b: Double) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red), Double(green), Double(blue))
    }

    private func hex(_ color: SwiftUI.Color, _ traits: UITraitCollection) -> Int {
        let value = rgb(color, traits)
        return (Int((value.r * 255).rounded()) << 16)
            | (Int((value.g * 255).rounded()) << 8)
            | Int((value.b * 255).rounded())
    }

    private func luminance(_ value: (r: Double, g: Double, b: Double)) -> Double {
        func channel(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(value.r) + 0.7152 * channel(value.g) + 0.0722 * channel(value.b)
    }

    private func contrast(_ a: (r: Double, g: Double, b: Double),
                          _ b: (r: Double, g: Double, b: Double)) -> Double {
        let first = luminance(a), second = luminance(b)
        let high = max(first, second), low = min(first, second)
        return (high + 0.05) / (low + 0.05)
    }

    /**
     * The bridge works.
     *
     * `Color(uiColor:)` is what carries one `UIColor(dynamicProvider:)` into
     * SwiftUI, and the whole file rests on it keeping the provider rather than
     * resolving it at construction. If that were ever untrue every chrome colour
     * in the app would freeze at whichever appearance happened to be current
     * when `Theme` was first touched — and it would look completely correct in
     * whichever appearance that was.
     */
    func testAChromeColourResolvesDifferentlyInTheTwoAppearances() {
        for (name, color) in [("background", Theme.background),
                              ("surface", Theme.surface),
                              ("primary", Theme.primary),
                              ("accent", Theme.accent)] {
            XCTAssertNotEqual(hex(color, Self.light), hex(color, Self.dark),
                              "\(name) is the same colour in both appearances — the dynamic "
                              + "provider did not survive the bridge into SwiftUI")
        }
    }

    /// The light half is `tokens.css`'s light theme, hex for hex. Written out
    /// rather than derived, so a "small tidy-up" of the desktop's palette that
    /// never reached the phone fails here instead of drifting for a year.
    func testTheLightHalfIsTheDesktopsLightTheme() {
        let expected: [(String, SwiftUI.Color, Int)] = [
            ("--bg-primary", Theme.background, 0xffffff),
            ("--bg-secondary", Theme.surface, 0xf5f5f5),
            ("--bg-tertiary", Theme.surfaceHigh, 0xededed),
            ("--text-primary", Theme.primary, 0x1c1c1c),
            ("--text-secondary", Theme.secondary, 0x545454),
            ("--text-muted", Theme.faint, 0x666666),
            ("--accent", Theme.accent, 0x1a66c4),
            ("--accent-fg", Theme.onAccent, 0xffffff),
            ("--color-critical", Theme.critical, 0xbd3a2c),
            ("--color-warning", Theme.warning, 0x8f5800),
            ("--color-positive", Theme.positive, 0x19714a),
        ]
        for (token, color, hexValue) in expected {
            XCTAssertEqual(hex(color, Self.light), hexValue,
                           "\(token) should be #\(String(hexValue, radix: 16)) in the light theme")
        }
    }

    /// And the dark half is unchanged by this work. Adding a light theme must not
    /// move the theme people are already using.
    func testTheDarkHalfIsWhatTheAppAlreadyShipped() {
        let expected: [(String, SwiftUI.Color, Int)] = [
            ("--bg-primary", Theme.background, 0x191919),
            ("--bg-secondary", Theme.surface, 0x202020),
            ("--bg-tertiary", Theme.surfaceHigh, 0x252525),
            ("--text-primary", Theme.primary, 0xededed),
            ("--text-secondary", Theme.secondary, 0xa8a8a8),
            ("--text-muted", Theme.faint, 0x8f8f8f),
            ("--accent", Theme.accent, 0x3b8fee),
            ("--accent-fg", Theme.onAccent, 0x0f1114),
            ("--color-critical", Theme.critical, 0xff6f60),
            ("--color-warning", Theme.warning, 0xddb04a),
            ("--color-positive", Theme.positive, 0x5fbf95),
        ]
        for (token, color, hexValue) in expected {
            XCTAssertEqual(hex(color, Self.dark), hexValue,
                           "\(token) should be #\(String(hexValue, radix: 16)) in the dark theme")
        }
    }

    /**
     * Every surface and every ink is exactly neutral.
     *
     * `r == g == b`. The set this replaced ran three to four levels more red
     * than blue, which is invisible in a swatch and enough to make a filled
     * screen read as faintly orange — reported on the desktop, inherited here
     * from the same source. It is a property a person cannot check one colour at
     * a time and a machine can check in a millisecond.
     */
    func testTheGreysAreExactlyNeutral() {
        let greys: [(String, SwiftUI.Color)] = [("background", Theme.background),
                                        ("surface", Theme.surface),
                                        ("surfaceHigh", Theme.surfaceHigh),
                                        ("primary", Theme.primary),
                                        ("secondary", Theme.secondary),
                                        ("faint", Theme.faint)]
        for traits in [Self.light, Self.dark] {
            for (name, color) in greys {
                let value = rgb(color, traits)
                XCTAssertEqual(value.r, value.g, accuracy: 0.002, "\(name) is not neutral")
                XCTAssertEqual(value.g, value.b, accuracy: 0.002, "\(name) is not neutral")
            }
        }
    }

    /**
     * Every ink clears AA on every surface it can land on, in both appearances.
     *
     * Three inks and three surfaces is nine pairings per appearance, and the
     * reason it is the whole cross-product rather than the obvious three is that
     * a card inside a card is a real thing in this app: the settings rows sit on
     * `surface`, the chips inside them on `surfaceHigh`, and the quietest ink is
     * set on both.
     */
    func testEveryInkIsReadableOnEverySurface() {
        let surfaces: [(String, SwiftUI.Color)] = [("background", Theme.background),
                                           ("surface", Theme.surface),
                                           ("surfaceHigh", Theme.surfaceHigh)]
        let inks: [(String, SwiftUI.Color)] = [("primary", Theme.primary),
                                       ("secondary", Theme.secondary),
                                       ("faint", Theme.faint),
                                       ("accent", Theme.accent),
                                       ("warning", Theme.warning),
                                       ("critical", Theme.critical),
                                       ("positive", Theme.positive)]
        for (schemeName, traits) in [("light", Self.light), ("dark", Self.dark)] {
            for (surfaceName, surface) in surfaces {
                for (inkName, ink) in inks {
                    let ratio = contrast(rgb(ink, traits), rgb(surface, traits))
                    XCTAssertGreaterThanOrEqual(
                        ratio, 4.5,
                        "\(schemeName): \(inkName) on \(surfaceName) is "
                        + "\(String(format: "%.2f", ratio)):1, below AA for body text")
                }
            }
        }
    }

    /// Every status dot is also a status word somewhere, so the same rule applies
    /// to all five — including the two that only ever appear as five pixels.
    func testEveryStatusColourIsReadableAsText() {
        for (schemeName, traits) in [("light", Self.light), ("dark", Self.dark)] {
            for status in ["working", "waiting", "input", "completed", "exited", "idle"] {
                for (surfaceName, surface) in [("background", Theme.background),
                                               ("surfaceHigh", Theme.surfaceHigh)] {
                    let ratio = contrast(rgb(Theme.statusColor(status), traits), rgb(surface, traits))
                    XCTAssertGreaterThanOrEqual(
                        ratio, 4.5,
                        "\(schemeName): status \(status) on \(surfaceName) is "
                        + "\(String(format: "%.2f", ratio)):1")
                }
            }
        }
    }

    /// The ink that goes on a filled accent button. It flips between the
    /// appearances — near-black on the dark theme's bright blue, white on the
    /// light theme's dark one — and both have to clear, which is the reason the
    /// flip exists at all.
    func testTheInkOnTheAccentClearsInBothAppearances() {
        for (name, traits) in [("light", Self.light), ("dark", Self.dark)] {
            let ratio = contrast(rgb(Theme.onAccent, traits), rgb(Theme.accent, traits))
            XCTAssertGreaterThanOrEqual(ratio, 4.5,
                                        "\(name): ink on the accent is \(String(format: "%.2f", ratio)):1")
        }
    }

    // MARK: - The terminal

    func testTheTerminalHasItsOwnPaperAndItIsNotTheAppCanvas() {
        // On paper the terminal must be recessed, or it stops being a terminal
        // and becomes an empty document with a cursor in it. `#e8e8e8` is the
        // desktop's own `--terminal-bg`.
        XCTAssertEqual(hex(SwiftUI.Color(uiColor: Palette.terminalBackground), Self.light), 0xe8e8e8)
        XCTAssertNotEqual(hex(SwiftUI.Color(uiColor: Palette.terminalBackground), Self.light),
                          hex(Theme.background, Self.light),
                          "a terminal the same colour as the app canvas is not a terminal")
        XCTAssertEqual(hex(SwiftUI.Color(uiColor: Palette.terminalBackground), Self.dark), 0x121212)

        for (name, traits) in [("light", Self.light), ("dark", Self.dark)] {
            let ratio = contrast(rgb(Palette.terminalForeground, traits),
                                 rgb(Palette.terminalBackground, traits))
            XCTAssertGreaterThan(ratio, 12,
                                 "\(name): the terminal's own ink is \(String(format: "%.1f", ratio)):1 "
                                 + "— a terminal's job is to be exact")
        }
    }

    /// Sixteen in each appearance, and the two sets are not the same set.
    func testThereIsAnAnsiPaletteForEachAppearance() {
        XCTAssertEqual(Palette.ansi(for: .light).count, 16)
        XCTAssertEqual(Palette.ansi(for: .dark).count, 16)
        XCTAssertNotEqual(Palette.ansi(for: .light).map(\.red),
                          Palette.ansi(for: .dark).map(\.red),
                          "a light terminal with the dark ANSI set is unreadable")
    }

    /// The dark set is the one the desktop renders: these sixteen hexes are
    /// what a session looks like in the window on the Mac — and now on the
    /// phone. They started as `@xterm/xterm`'s defaults, inherited there by not
    /// passing a palette; the desktop declares them itself now, unchanged, as
    /// `--ansi-*` in `tokens.css`, and `tokens.test.ts` holds this table against
    /// that sheet from the other side.
    func testTheDarkAnsiSetIsTheOneTheDesktopRenders() {
        let expected = [0x2e3436, 0xcc0000, 0x4e9a06, 0xc4a000, 0x3465a4, 0x75507b, 0x06989a, 0xd3d7cf,
                        0x555753, 0xef2929, 0x8ae234, 0xfce94f, 0x729fcf, 0xad7fa8, 0x34e2e2, 0xeeeeec]
        XCTAssertEqual(Palette.ansi(for: .dark).map(Self.hex), expected)
    }

    /**
     * The light set is the same sixteen walked down, not a different palette.
     *
     * Hue within two degrees of its dark twin, because the transform is a scale
     * of the channels toward black and nothing else — which preserves hue
     * exactly in arithmetic. A "light palette" that had been picked by eye would
     * drift here, and drifting here means red stops being the red the desktop
     * shows.
     *
     * The bound is two degrees rather than zero because the values are eight-bit
     * and the scale is not. Thirteen of the sixteen land dead on; the worst is
     * bright magenta at **1.72°**, and that is rounding rather than drift — it is
     * the palest and least saturated of the nine that move, so a half-level of
     * rounding on a channel is a larger angle there than anywhere else. Anything
     * above two degrees is somebody having chosen a colour.
     */
    func testTheLightAnsiSetKeepsEveryHue() {
        for (index, pair) in zip(Palette.ansi(for: .light), Palette.ansi(for: .dark)).enumerated() {
            let (light, dark) = pair
            guard let lightHue = Self.hue(light), let darkHue = Self.hue(dark) else { continue }
            var delta = abs(lightHue - darkHue)
            if delta > 180 { delta = 360 - delta }
            XCTAssertLessThan(delta, 2.0,
                              "ANSI \(index) changed hue by \(String(format: "%.1f", delta))° "
                              + "between the appearances")
        }
    }

    /**
     * Every ANSI colour that is *meant* to be foreground is readable on paper.
     *
     * White and bright white are excluded, and the exclusion is the honest part
     * of this palette rather than a hole in the test: those two are used as
     * backgrounds as often as foregrounds, and darkening them would turn
     * `ESC[47m` into a black band. Every light terminal scheme in use makes the
     * same trade — the desktop included — and a program that wants the ordinary
     * foreground says `ESC[39m`, which is the terminal's own ink.
     */
    func testTheLightAnsiSetIsReadableOnPaper() {
        let paper = rgb(Palette.terminalBackground, Self.light)
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
                     "bright black", "bright red", "bright green", "bright yellow",
                     "bright blue", "bright magenta", "bright cyan", "bright white"]
        for (index, color) in Palette.ansi(for: .light).enumerated() where index != 7 && index != 15 {
            let ratio = contrast(Self.components(color), paper)
            XCTAssertGreaterThanOrEqual(ratio, 4.5,
                                        "ANSI \(names[index]) is \(String(format: "%.2f", ratio)):1 "
                                        + "on the light terminal's paper")
        }
    }

    /**
     * Normal and bright stay tellable apart on paper.
     *
     * They did not, on the first attempt: walking both to the same contrast
     * target put green and bright green eleven levels apart, which a diff draws
     * as one colour. The bright eight therefore target a higher contrast — on a
     * dark ground "brighter" means further from the ground, and on paper the
     * same idea is darker. The six chromatic pairs are what this checks; black
     * and white are the ends of the ramp and are argued about in `Ink.ansi`.
     */
    func testNormalAndBrightAreNotTheSameColourOnPaper() {
        let light = Palette.ansi(for: .light)
        for index in 1 ... 6 {
            let normal = Self.components(light[index])
            let bright = Self.components(light[index + 8])
            let distance = sqrt(pow(normal.r - bright.r, 2)
                                + pow(normal.g - bright.g, 2)
                                + pow(normal.b - bright.b, 2)) * 255
            XCTAssertGreaterThan(distance, 25,
                                 "ANSI \(index) and \(index + 8) are \(Int(distance)) apart in the "
                                 + "light set — a program using both draws one colour")
        }
    }

    // MARK: - Reading SwiftTerm's colours

    private static func components(_ color: SwiftTerm.Color) -> (r: Double, g: Double, b: Double) {
        // `init(red8:)` widens by 257, so this is the exact inverse rather than
        // a division by 65535 that would land a level low on every channel.
        (Double(color.red / 257) / 255, Double(color.green / 257) / 255, Double(color.blue / 257) / 255)
    }

    private static func hex(_ color: SwiftTerm.Color) -> Int {
        (Int(color.red / 257) << 16) | (Int(color.green / 257) << 8) | Int(color.blue / 257)
    }

    private static func hue(_ color: SwiftTerm.Color) -> Double? {
        let value = components(color)
        let high = max(value.r, value.g, value.b)
        let low = min(value.r, value.g, value.b)
        let delta = high - low
        guard delta > 0.001 else { return nil }
        let sextant: Double
        if high == value.r {
            sextant = (value.g - value.b) / delta
        } else if high == value.g {
            sextant = (value.b - value.r) / delta + 2
        } else {
            sextant = (value.r - value.g) / delta + 4
        }
        let degrees = sextant * 60
        return degrees < 0 ? degrees + 360 : degrees
    }
}
