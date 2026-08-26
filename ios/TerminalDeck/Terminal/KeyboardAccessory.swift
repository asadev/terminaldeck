/**
 * The bar above the keyboard, which is most of what makes a terminal usable on a
 * phone — and, since this rewrite, the one surface in the app that is guaranteed
 * not to move under a thumb.
 *
 * An iOS keyboard has no Escape, no Tab, no Control and no arrows, and a shell
 * without those is a read-only window. SwiftTerm ships an accessory of its own
 * and this replaces it.
 *
 * ## What was wrong with the bar this replaces
 *
 * Twenty-six buttons in a single horizontal `UIScrollView`, with the dismiss
 * button added **last**. The control people reach for most often was therefore
 * the one furthest away: putting the keyboard down meant scrolling past
 * `| / \ - _ ~ : *`, the four signals, home, end, pgup, pgdn, copy and paste.
 * And because a scroll view has no fixed positions, no muscle memory could ever
 * form for any of them — every key cost a swipe plus a hunt.
 *
 * ## The shape that replaces it
 *
 * **A bar that never scrolls, and a grid that opens where the keyboard was.**
 *
 * The bar carries only what is pressed constantly while typing a command —
 * `esc` `tab` `ctrl` `↑` `↓` — plus two buttons pinned hard right that never
 * move: **more**, which opens the grid, and **dismiss**, which puts the keyboard
 * away. `KeyPlan` owns which keys those are and proves the set fits the
 * narrowest supported iPhone without scrolling; if a key is ever added here and
 * that stops being true, `KeyBarTests` fails rather than a scroll view quietly
 * coming back.
 *
 * ## Control and Alt are sticky, and the terminal owns that state
 *
 * A finger cannot hold a chord, so both modifiers arm and are spent by the next
 * key — the same interaction every phone keyboard uses for shift.
 * `TerminalView.controlModifier` and `.metaModifier` are consulted by SwiftTerm's
 * own `insertText` when the accessory is not one of its own, which is exactly
 * this case, so arming here makes the *next* character typed on the software
 * keyboard arrive as a control code or with an Escape prefix. SwiftTerm clears
 * the flag afterwards and posts a notification; listening to that is what keeps
 * the button from staying lit after the modifier has already been spent.
 */

import SwiftTerm
import UIKit

@MainActor
final class KeyboardAccessory: UIInputView, UIInputViewAudioFeedback {

    /// Raw bytes for the session. Goes through the same path as a keystroke.
    var onBytes: (([UInt8]) -> Void)?
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    /// Open the photo picker, and the file picker. Both are sheets the screen
    /// owns; this only says which one was asked for.
    var onSendMedia: (() -> Void)?
    var onSendFile: (() -> Void)?
    /// Put the keyboard away. Also closes the grid — dismiss means "give me the
    /// screen back", and leaving a grid up would be answering half of that.
    var onDismiss: (() -> Void)?
    /// Open or close the grid.
    var onMore: (() -> Void)?
    /// Application-cursor mode changes what an arrow key is on the wire, and
    /// only the terminal knows which mode it is in.
    var applicationCursor: () -> Bool = { false }
    /// Arming a modifier is a change to the terminal's state, not to this
    /// view's, so it is reported rather than stored.
    var onModifier: ((KeyAction.Modifier, Bool) -> Void)?

    /// The bar's height. 52 rather than the 44 this replaces: a 44pt *touch
    /// target* needs 44 points of key, and the old bar spent 10 of its 44 on
    /// padding and left 34 for the thing you actually hit.
    static let height: CGFloat = 52

    private var modifierButtons: [KeyAction.Modifier: KeyCapButton] = [:]
    private var moreButton: KeyChromeButton?
    private var resetObservers: [NSObjectProtocol] = []

    /// Which sticky modifiers are armed right now. On this view because the
    /// buttons are, and mirrored onto the terminal through `onModifier`.
    private(set) var armed: Set<KeyAction.Modifier> = [] {
        didSet {
            for (modifier, button) in modifierButtons {
                button.isArmed = armed.contains(modifier)
            }
        }
    }

    /// Drawn on the *more* button so the two states of the grid are visible
    /// from the bar rather than only from what is underneath it.
    var isGridOpen = false {
        didSet { moreButton?.isOn = isGridOpen }
    }

    init(width: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: Self.height),
                   inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        build()

        // The tokens are kept and removed in `deinit`. A block-based observer is
        // not released when its object is: NotificationCenter holds it until it
        // is handed back, so a session-per-accessory app would accumulate one
        // dead observer per terminal ever opened.
        observe(.terminalViewControlModifierReset, clears: .control)
        observe(.terminalViewMetaModifierReset, clears: .meta)
    }

    deinit {
        for token in resetObservers { NotificationCenter.default.removeObserver(token) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Spent by a keystroke SwiftTerm handled. The button has to stop claiming
    /// otherwise — a modifier that looks armed and is not is how a `w` becomes a
    /// Ctrl+W and closes something.
    private func observe(_ name: Notification.Name, clears modifier: KeyAction.Modifier) {
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.armed.remove(modifier)
            }
        }
        resetObservers.append(token)
    }

    // MARK: - Layout

    /**
     * The bar, in one pass, with no scroll view anywhere in it.
     *
     * The keys stretch and the two pinned buttons hug, which is what keeps
     * *more* and *dismiss* in the same place on every phone: on a 375pt screen
     * each key comes out just under 46 points, on a 430pt screen just under 57,
     * and the right-hand pair is at the right-hand edge on both. Measured on a
     * real layout in `KeyBarTests`, not asserted from this arithmetic.
     */
    private func build() {
        let keys = UIStackView(arrangedSubviews: KeyPlan.bar.map { cap in
            let button = KeyCapButton(cap: cap) { [weak self] in self?.press($0) }
            if case let .modifier(modifier) = cap.action { modifierButtons[modifier] = button }
            return button
        })
        keys.axis = .horizontal
        keys.spacing = KeyPlan.keySpacing
        keys.distribution = .fillEqually

        let more = KeyChromeButton(systemImage: "square.grid.2x2", title: "More keys") { [weak self] in
            self?.onMore?()
        }
        more.accessibilityIdentifier = "keys.more"
        moreButton = more

        let dismiss = KeyChromeButton(systemImage: "keyboard.chevron.compact.down",
                                      title: "Hide the keyboard") { [weak self] in
            self?.onDismiss?()
        }
        dismiss.accessibilityIdentifier = "keys.dismiss"

        let pinned = UIStackView(arrangedSubviews: [more, dismiss])
        pinned.axis = .horizontal
        pinned.spacing = KeyPlan.keySpacing
        pinned.distribution = .fillEqually

        let row = UIStackView(arrangedSubviews: [keys, pinned])
        row.axis = .horizontal
        row.spacing = KeyPlan.pinnedSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        // Which half absorbs the spare width, stated rather than left to a tie.
        // Both stacks default to the same hugging priority, and a stack asked to
        // fill with two equally reluctant children has no defined answer about
        // which one grows. The keys grow; the pinned pair is a fixed size by
        // definition, because "the same place on every phone" is its whole job.
        keys.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pinned.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(row)

        let capHeight = Self.height - 8
        NSLayoutConstraint.activate([
            // The safe-area guide rather than the bounds: in landscape on a
            // notched phone the bar spans the full width and the first key would
            // otherwise sit under the sensor housing.
            row.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: KeyPlan.barMargin),
            row.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -KeyPlan.barMargin),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.heightAnchor.constraint(equalToConstant: capHeight),
            // Each pinned button is a square of the same height as a key, which
            // is what makes the pair read as chrome rather than as two more keys.
            pinned.widthAnchor.constraint(equalToConstant: capHeight * 2 + KeyPlan.keySpacing),
        ])
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    // MARK: - Pressing

    /**
     * One place turns a key into an effect.
     *
     * Shared with the grid deliberately: `copy` on the bar and `copy` in the
     * grid have to be the same act, and a second switch statement somewhere else
     * is how they stop being.
     */
    func press(_ cap: KeyCap) {
        switch cap.action {
        case let .bytes(bytes):
            send(bytes)
        case let .cursor(final):
            send(KeyPlan.cursorBytes(final, applicationCursor: applicationCursor()))
        case let .modifier(modifier):
            UIDevice.current.playInputClick()
            if armed.contains(modifier) {
                armed.remove(modifier)
            } else {
                armed.insert(modifier)
            }
            onModifier?(modifier, armed.contains(modifier))
        case .copy:
            UIDevice.current.playInputClick()
            onCopy?()
        case .paste:
            UIDevice.current.playInputClick()
            onPaste?()
        case .sendMedia:
            UIDevice.current.playInputClick()
            onSendMedia?()
        case .sendFile:
            UIDevice.current.playInputClick()
            onSendFile?()
        }
    }

    private func send(_ bytes: [UInt8]) {
        UIDevice.current.playInputClick()
        onBytes?(bytes)
    }

    /// From `UIInputViewAudioFeedback`: the keyboard click a hardware-feeling
    /// key ought to make. Without the conformance `playInputClick` is silent.
    var enableInputClicksWhenVisible: Bool { true }
}
