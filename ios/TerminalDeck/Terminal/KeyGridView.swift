/**
 * Everything that is not on the fixed bar, in the space the keyboard was using.
 *
 * ## The trick this whole view exists for
 *
 * Tapping **more** does not open a panel *over* the terminal and it does not
 * push the terminal up. It replaces the keyboard: the grid becomes the
 * terminal's `inputView` and is given the height the keyboard had, so one
 * surface swaps for the other and the terminal above does not move by a single
 * point. Anything else — a sheet, a popover, an overlay — costs the user their
 * place in the output at the exact moment they are looking for a key.
 *
 * Making it the *input view* rather than a view of our own has a second
 * consequence that matters more than the layout: **the terminal never stops
 * being first responder**, so a selection made with a long press survives the
 * trip into this grid. That is the whole reason `copy` can live here at all. A
 * "Copy Selection" item in the navigation bar had to be removed from this app
 * once already, because reaching a control outside the terminal destroys the
 * selection on the way there — see `TerminalScreen`. This is inside.
 *
 * ## Why it scrolls vertically and the bar does not
 *
 * The bar not scrolling is the fix. The grid holding more than a keyboard's
 * worth of keys is simply true: five labelled groups and twelve function keys do
 * not fit in 290 points, and the alternative to a vertical scroll is dropping
 * keys or shrinking them below a touch target. The groups are ordered so that
 * what a phone reaches for in a hurry — edit, signals, navigation — is above the
 * fold, and a scroll indicator says the rest is there. Vertical scrolling in a
 * keyboard-shaped surface is also what the emoji keyboard does, so nobody has to
 * be taught it.
 */

import UIKit

@MainActor
final class KeyGridView: UIInputView {

    /// Called for every key. The accessory owns the meaning of a press, so this
    /// view hands it back rather than deciding for itself — one switch, two
    /// surfaces.
    var onKey: ((KeyCap) -> Void)?

    /// Which sticky modifiers are armed. Set by the accessory, because `alt`
    /// lives here and `ctrl` lives on the bar and they are the same kind of
    /// state.
    var armed: Set<KeyAction.Modifier> = [] {
        didSet {
            for (modifier, button) in modifierButtons {
                button.isArmed = armed.contains(modifier)
            }
        }
    }

    /**
     * How tall to be — measured from the keyboard this is standing in for.
     *
     * Set by `TerminalBridge` from the last keyboard frame it saw. It is not a
     * constant because there is no such constant: the keyboard is a different
     * height on every screen size, in landscape, with a third-party keyboard,
     * and with a hardware keyboard attached.
     */
    var preferredHeight: CGFloat = KeyGridView.fallbackHeight {
        didSet {
            guard preferredHeight != oldValue else { return }
            invalidateIntrinsicContentSize()
        }
    }

    /**
     * What to use before a keyboard has ever been on screen.
     *
     * Nearly unreachable — the *more* button lives on the accessory bar, which
     * is only visible while the keyboard is up — but not unreachable: with a
     * hardware keyboard attached the bar appears on its own. 291 points is the
     * portrait keyboard on a 375-point phone, which is the narrowest case and
     * therefore the one where being wrong costs the least.
     */
    static let fallbackHeight: CGFloat = 291

    private var modifierButtons: [KeyAction.Modifier: KeyCapButton] = [:]

    /// The *Send* group's own view, kept so it can be taken away.
    private var sendSection: UIView?

    /**
     * Whether this machine will accept a photo or a file.
     *
     * Hidden rather than dead when it will not: *"a control that can only
     * produce a refusal is not a control"* — the same reasoning that kept these
     * two out of the session's `…` on a machine that cannot receive them, moved
     * here with them. A stack view drops a hidden arranged subview out of the
     * layout entirely, so the panel closes over the gap and *Edit* is first.
     */
    var canSendFiles = true {
        didSet {
            guard canSendFiles != oldValue else { return }
            sendSection?.isHidden = !canSendFiles
        }
    }
    private let scroll = UIScrollView()

    /// Six across. The number is a consequence rather than a taste: at 375
    /// points, six columns leaves each key about 55 points wide, and seven would
    /// take it under the 44-point touch target once the gaps are paid for.
    private static let columns = 6

    init(width: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: Self.fallbackHeight),
                   inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "keys.grid"
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        // The home indicator sits inside the keyboard's frame, so the last row
        // of keys would be under it. Paid for with content inset rather than by
        // shrinking the view, because the view's height is the keyboard's and
        // changing it would move the terminal.
        scroll.contentInset.bottom = safeAreaInsets.bottom
        scroll.verticalScrollIndicatorInsets.bottom = safeAreaInsets.bottom
    }

    private func build() {
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false

        for group in KeyPlan.grid {
            let view = section(group)
            if group.title == KeyPlan.sendGroupTitle {
                sendSection = view
                view.isHidden = !canSendFiles
            }
            column.addArrangedSubview(view)
        }

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.addSubview(column)
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            column.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor,
                                            constant: KeyPlan.barMargin),
            column.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor,
                                             constant: -KeyPlan.barMargin),
            // The content is as wide as the scroll view and no wider. Without
            // this the grid would scroll sideways, which is the exact defect
            // this whole redesign is removing from the bar above it.
            column.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor,
                                          constant: -KeyPlan.barMargin * 2),
        ])
    }

    /// A labelled group: a quiet header, then its keys in rows of six.
    private func section(_ group: KeyGroup) -> UIView {
        // Tracking on the header, because an eleven-point uppercase label
        // without it reads as a cramped word rather than as a heading — which
        // is why it is attributed text rather than three plain properties.
        let header = UILabel()
        header.attributedText = NSAttributedString(
            string: group.title.uppercased(),
            attributes: [.kern: 0.6, .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: Palette.keyLabelFaint])

        let column = UIStackView(arrangedSubviews: [header])
        column.axis = .vertical
        column.spacing = 8
        column.setCustomSpacing(6, after: header)

        for slice in stride(from: 0, to: group.keys.count, by: Self.columns) {
            let keys = Array(group.keys[slice ..< min(slice + Self.columns, group.keys.count)])
            column.addArrangedSubview(row(keys))
        }
        return column
    }

    /**
     * One row of keys.
     *
     * A short row is padded with empty space rather than stretched: the two Edit
     * keys spread across the whole width would be two enormous buttons that look
     * like a different control from the `^C` directly under them, and the grid's
     * whole readability comes from every cap being the same size.
     */
    private func row(_ keys: [KeyCap]) -> UIView {
        let stack = UIStackView(arrangedSubviews: keys.map { cap in
            let button = KeyCapButton(cap: cap) { [weak self] in self?.onKey?($0) }
            if case let .modifier(modifier) = cap.action { modifierButtons[modifier] = button }
            return button
        })
        stack.axis = .horizontal
        stack.spacing = KeyPlan.keySpacing
        stack.distribution = .fillEqually
        for _ in keys.count ..< Self.columns {
            stack.addArrangedSubview(UIView())
        }
        stack.heightAnchor.constraint(equalToConstant: KeyPlan.minimumTouchTarget).isActive = true
        return stack
    }
}
