/**
 * The key bar, and the one claim it exists to make: **it does not scroll.**
 *
 * The bar this replaces put twenty-six buttons in a horizontal scroll view with
 * dismiss last, so putting the keyboard away meant scrolling past every symbol
 * and every signal first. The fix is only a fix if the replacement genuinely
 * fits, so the first two cases here measure it — at 375 points, the narrowest
 * iPhone this app runs on, not on the Pro Max it happens to be developed on.
 *
 * The rest are about the bytes. A key cap that sends the wrong sequence is
 * indistinguishable from a broken connection to the person pressing it, and the
 * arrows are the ones that get this wrong: in application-cursor mode — which
 * every full-screen program sets — an arrow is `ESC O A` rather than `ESC [ A`,
 * so a bar tested only at a shell prompt would appear to work and would do
 * nothing inside vim.
 */

import UIKit
import XCTest
@testable import TerminalDeck

@MainActor
final class KeyBarTests: XCTestCase {

    // MARK: - It fits

    /**
     * The arithmetic, before any view exists.
     *
     * Seven targets at 44 points plus the gaps, against the narrowest supported
     * screen. If somebody adds an eighth key to the bar this fails here, which
     * is the point: the answer is to move a key into the grid, never to put the
     * scroll view back.
     */
    func testTheFixedBarFitsTheNarrowestSupportedPhone() {
        XCTAssertLessThanOrEqual(
            KeyPlan.minimumBarWidth, KeyPlan.narrowestPhoneWidth,
            "the bar needs \(KeyPlan.minimumBarWidth)pt and the smallest phone is "
            + "\(KeyPlan.narrowestPhoneWidth)pt — move a key into the grid rather than scrolling")
    }

    /**
     * A bar laid out at a given width, the way the keyboard system lays it out.
     *
     * Inside a host view rather than by setting `frame`. The bar turns
     * autoresizing translation off in its own initialiser — it has to, because
     * it is a self-sizing `UIInputView` — so a frame assigned to it directly is
     * overwritten the moment the engine runs, and the engine with nothing
     * holding the edges sizes the bar to *fit* its content instead of stretching
     * the content to the screen. That is not a hypothetical: the first version
     * of this test measured 38-point keys and reported a bar that overflowed,
     * when what it had actually built was a 320-point bar floating in space.
     */
    private func laidOut(width: CGFloat) -> KeyboardAccessory {
        let bar = KeyboardAccessory(width: width)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: width, height: KeyboardAccessory.height))
        host.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bar.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutIfNeeded()
        return bar
    }

    /// And the same claim measured off a real layout, because arithmetic about a
    /// layout is not a layout.
    func testEveryKeyIsATouchTargetOnTheNarrowestPhone() {
        let bar = laidOut(width: KeyPlan.narrowestPhoneWidth)

        let buttons = bar.everyButton
        XCTAssertEqual(buttons.count, KeyPlan.bar.count + KeyPlan.pinnedCount)
        for button in buttons {
            XCTAssertGreaterThanOrEqual(
                button.bounds.width.rounded(), KeyPlan.minimumTouchTarget,
                "\(button.accessibilityLabel ?? "?") is \(button.bounds.width)pt wide")
            XCTAssertGreaterThanOrEqual(button.bounds.height.rounded(), KeyPlan.minimumTouchTarget)
            // Inside the bar, not merely laid out. A button whose frame runs off
            // the edge is exactly what a scroll view used to hide.
            XCTAssertTrue(bar.bounds.contains(button.convert(button.bounds, to: bar)),
                          "\(button.accessibilityLabel ?? "?") is outside the bar")
        }
    }

    /// The literal claim, stated as a test so it cannot be quietly undone: there
    /// is no scroll view anywhere in the bar.
    func testTheBarContainsNoScrollView() {
        let bar = KeyboardAccessory(width: KeyPlan.narrowestPhoneWidth)
        XCTAssertFalse(bar.containsAScrollView, "the bar must not scroll — that is the whole change")
    }

    /// Dismiss is the control people reach for most and it used to be
    /// twenty-sixth. It is now the last thing on the bar by position and always
    /// on screen.
    func testDismissAndMoreArePinnedToTheRight() throws {
        let bar = laidOut(width: KeyPlan.narrowestPhoneWidth)

        let dismiss = try XCTUnwrap(bar.everyButton.first { $0.accessibilityIdentifier == "keys.dismiss" })
        let more = try XCTUnwrap(bar.everyButton.first { $0.accessibilityIdentifier == "keys.more" })

        let keys = bar.everyButton.filter { $0 is KeyCapButton }
        let rightmostKey = keys.map { $0.convert($0.bounds, to: bar).maxX }.max() ?? 0
        XCTAssertGreaterThan(more.convert(more.bounds, to: bar).minX, rightmostKey)
        XCTAssertGreaterThan(dismiss.convert(dismiss.bounds, to: bar).minX,
                             more.convert(more.bounds, to: bar).minX)
    }

    // MARK: - What is where

    func testTheBarHoldsOnlyTheKeysPressedConstantly() {
        XCTAssertEqual(KeyPlan.bar.map(\.label), ["esc", "tab", "ctrl", "↑", "↓"])
    }

    /**
     * Everything the old row had is still reachable — nothing was dropped on the
     * way from one scroll view to a grid, which is the obvious way this change
     * could have quietly lost a feature.
     */
    func testEveryKeyTheOldRowHadIsStillSomewhere() {
        let everywhere = Set(KeyPlan.bar.map(\.label) + KeyPlan.grid.flatMap { $0.keys.map(\.label) })
        let theOldRow = ["esc", "tab", "ctrl", "←", "↑", "↓", "→",
                         "|", "/", "\\", "-", "_", "~", ":", "*",
                         "^C", "^D", "^Z", "^L", "home", "end", "pgup", "pgdn", "copy", "paste"]
        for key in theOldRow {
            XCTAssertTrue(everywhere.contains(key), "\(key) was on the old row and is now nowhere")
        }
    }

    /**
     * No `cmd` and no `win`, anywhere.
     *
     * A PTY cannot receive either: a terminal sees Ctrl, Alt/Meta and Escape
     * sequences, and there is no byte for Command or the Windows key. Those caps
     * would send nothing at all, and a control that does nothing is the exact
     * defect this redesign exists to remove. `alt` is the real key and it is in
     * the grid. This is asserted rather than merely decided, because "add a cmd
     * key" is a request that will come back.
     */
    func testThereIsNoCommandOrWindowsKey() {
        let labels = (KeyPlan.bar + KeyPlan.grid.flatMap(\.keys)).map { $0.label.lowercased() }
        XCTAssertFalse(labels.contains("cmd"))
        XCTAssertFalse(labels.contains("win"))
        XCTAssertTrue(labels.contains("alt"), "alt is what takes their place")
    }

    /// Groups are labelled, and each label is a word rather than a category
    /// number. The grid's whole readability is that it can be read.
    func testEveryGridGroupIsLabelledAndPopulated() {
        XCTAssertEqual(KeyPlan.grid.map(\.title),
                       ["Edit", "Signals", "Navigation", "Symbols", "Modifiers", "Function"])
        for group in KeyPlan.grid {
            XCTAssertFalse(group.keys.isEmpty, "\(group.title) has no keys in it")
        }
    }

    /// Every cap says something a screen reader can pronounce. A row of glyphs
    /// with no titles is a row of noises to VoiceOver.
    func testEveryKeyHasSomethingToSay() {
        for cap in KeyPlan.bar + KeyPlan.grid.flatMap(\.keys) {
            XCTAssertFalse(cap.title.isEmpty, "\(cap.label) has no spoken title")
        }
    }

    // MARK: - What the keys send

    func testTheArrowsChangeWithApplicationCursorMode() {
        // `ESC [ A` at a shell prompt, `ESC O A` inside anything full-screen.
        // Getting this wrong produces arrows that work in bash and do nothing in
        // vim, which is reported as "the arrows are broken" a week later.
        XCTAssertEqual(KeyPlan.cursorBytes("A", applicationCursor: false), [0x1b, 0x5b, 0x41])
        XCTAssertEqual(KeyPlan.cursorBytes("A", applicationCursor: true), [0x1b, 0x4f, 0x41])
        XCTAssertEqual(KeyPlan.cursorBytes("H", applicationCursor: false), [0x1b, 0x5b, 0x48])
    }

    func testTheSignalsAreTheRealControlBytes() {
        let signals = KeyPlan.grid.first { $0.title == "Signals" }?.keys ?? []
        XCTAssertEqual(signals.map(\.action), [
            .bytes([0x03]), .bytes([0x04]), .bytes([0x1a]), .bytes([0x0c]),
        ])
    }

    /// F1–F4 are SS3 and F5 upwards are CSI with a number that skips 16, 22 and
    /// 27 — a table rather than a formula, which is why it is worth checking.
    func testTheFunctionKeysMatchXterm() {
        XCTAssertEqual(KeyPlan.functionKey(1), Array("\u{1b}OP".utf8))
        XCTAssertEqual(KeyPlan.functionKey(4), Array("\u{1b}OS".utf8))
        XCTAssertEqual(KeyPlan.functionKey(5), Array("\u{1b}[15~".utf8))
        XCTAssertEqual(KeyPlan.functionKey(11), Array("\u{1b}[23~".utf8))
        XCTAssertEqual(KeyPlan.functionKey(12), Array("\u{1b}[24~".utf8))
    }

    // MARK: - Sticky modifiers

    /**
     * A finger cannot hold a chord, so Ctrl and Alt arm and are spent by the
     * next key — the same interaction every phone keyboard uses for shift. What
     * is checked here is that the *terminal* is told, because that is where the
     * state actually lives: `insertText` reads the view's flag, not the bar's.
     */
    func testArmingAModifierTellsTheTerminalAndCanBeUndone() throws {
        let bar = KeyboardAccessory(width: KeyPlan.narrowestPhoneWidth)
        var reported: [(KeyAction.Modifier, Bool)] = []
        bar.onModifier = { reported.append(($0, $1)) }

        let ctrl = try XCTUnwrap(KeyPlan.bar.first { $0.label == "ctrl" })
        bar.press(ctrl)
        XCTAssertTrue(bar.armed.contains(.control))
        // Tapping it again undoes it, rather than forcing the user to spend it
        // on a key they did not want.
        bar.press(ctrl)
        XCTAssertFalse(bar.armed.contains(.control))

        XCTAssertEqual(reported.map(\.1), [true, false])
        XCTAssertTrue(reported.allSatisfy { $0.0 == .control })
    }

    /// Spent by a keystroke SwiftTerm handled: the library posts, and the button
    /// has to stop claiming. A modifier that looks armed and is not is how a `w`
    /// becomes a Ctrl+W and closes something.
    func testAModifierUnlightsWhenTheTerminalSpendsIt() throws {
        let bar = KeyboardAccessory(width: KeyPlan.narrowestPhoneWidth)
        bar.press(try XCTUnwrap(KeyPlan.bar.first { $0.label == "ctrl" }))
        XCTAssertTrue(bar.armed.contains(.control))

        NotificationCenter.default.post(name: .terminalViewControlModifierReset, object: nil)
        XCTAssertFalse(bar.armed.contains(.control))
    }

    // MARK: - Pressing

    func testAKeyPressSendsItsBytes() throws {
        let bar = KeyboardAccessory(width: KeyPlan.narrowestPhoneWidth)
        var sent: [[UInt8]] = []
        bar.onBytes = { sent.append($0) }
        bar.applicationCursor = { true }

        bar.press(try XCTUnwrap(KeyPlan.bar.first { $0.label == "esc" }))
        bar.press(try XCTUnwrap(KeyPlan.bar.first { $0.label == "↑" }))

        XCTAssertEqual(sent, [[0x1b], [0x1b, 0x4f, 0x41]])
    }

    /// Copy and paste are the app's business rather than the wire's, so they
    /// come out as their own callbacks and never as bytes.
    func testCopyAndPasteDoNotGoOnTheWire() {
        let bar = KeyboardAccessory(width: KeyPlan.narrowestPhoneWidth)
        var bytes = 0
        var copies = 0
        var pastes = 0
        bar.onBytes = { _ in bytes += 1 }
        bar.onCopy = { copies += 1 }
        bar.onPaste = { pastes += 1 }

        let edit = KeyPlan.grid.first { $0.title == "Edit" }?.keys ?? []
        for cap in edit { bar.press(cap) }

        XCTAssertEqual(bytes, 0)
        XCTAssertEqual(copies, 1)
        XCTAssertEqual(pastes, 1)
    }

    // MARK: - The grid

    /// The grid is a `UIInputView` that stands where the keyboard was, so its
    /// height is the keyboard's — anything else moves the terminal above it.
    func testTheGridTakesTheHeightItIsGiven() {
        let grid = KeyGridView(width: KeyPlan.narrowestPhoneWidth)
        XCTAssertEqual(grid.intrinsicContentSize.height, KeyGridView.fallbackHeight)
        grid.preferredHeight = 336
        XCTAssertEqual(grid.intrinsicContentSize.height, 336)
    }

    /// Every key in the grid reaches the same interpreter the bar uses, so
    /// `copy` in one place and `copy` in the other cannot become two different
    /// acts.
    func testTheGridHandsItsPressesBack() {
        let grid = KeyGridView(width: KeyPlan.narrowestPhoneWidth)
        var pressed: [String] = []
        grid.onKey = { pressed.append($0.label) }

        for button in grid.everyButton.compactMap({ $0 as? KeyCapButton }) where button.cap.label == "^C" {
            button.sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(pressed, ["^C"])
    }
}

/* -------------------------------------------------------------------------- */
/* Reading a view hierarchy                                                    */
/* -------------------------------------------------------------------------- */

extension UIView {
    /// Every button under this view, at any depth. The bar nests two stacks, and
    /// a test that only looked one level down would pass on a bar that had
    /// silently stopped laying anything out.
    var everyButton: [UIButton] {
        subviews.flatMap { view -> [UIButton] in
            (view as? UIButton).map { [$0] } ?? view.everyButton
        }
    }

    var containsAScrollView: Bool {
        subviews.contains { $0 is UIScrollView || $0.containsAScrollView }
    }
}
