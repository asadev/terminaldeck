/**
 * The row above the keyboard, which is most of what makes a terminal usable on
 * a phone.
 *
 * An iOS keyboard has no Escape, no Tab, no Control and no arrows, and a shell
 * without those is a read-only window. SwiftTerm ships an accessory of its own
 * and this replaces it, for three reasons rather than taste:
 *
 *  1. **The keys that are missing are the ones people actually type.** `|`, `/`,
 *     `-`, `~`, `:` and Ctrl-C are behind two taps on the software keyboard, and
 *     Ctrl-C is the single most likely reason someone opens this app in a hurry.
 *  2. **Copy and paste need somewhere to live.** Selection on a terminal is
 *     fiddly with a finger; a Paste that always works and a Copy that takes the
 *     selection or the screen when there is none is what people reach for.
 *  3. **Auto-repeat.** Holding an arrow has to repeat, or scrolling back through
 *     history is one tap per line.
 *
 * ## Control is sticky, and the terminal owns that state
 *
 * `TerminalView.controlModifier` is consulted by SwiftTerm's own `insertText`
 * when the accessory is not one of its own — which is exactly this case — so
 * arming Control here makes the *next* character typed on the software keyboard
 * arrive as a control code, and SwiftTerm clears it afterwards and posts
 * `terminalViewControlModifierReset`. Listening to that is what keeps the button
 * from staying lit after the modifier has already been spent.
 */

import SwiftTerm
import UIKit

@MainActor
final class KeyboardAccessory: UIInputView, UIInputViewAudioFeedback {

    /// Raw bytes for the session. Goes through the same path as a keystroke.
    var onBytes: (([UInt8]) -> Void)?
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// Application-cursor mode changes what an arrow key is on the wire, and
    /// only the terminal knows which mode it is in.
    var applicationCursor: () -> Bool = { false }
    /// Arming Control is a change to the terminal's state, not to this view's.
    var onControl: ((Bool) -> Void)?

    private var controlButton: UIButton?
    private var controlReset: NSObjectProtocol?
    private var repeatTask: Task<Void, Never>?
    private var repeatTimer: Timer?

    private(set) var control = false {
        didSet {
            controlButton?.isSelected = control
            controlButton?.backgroundColor = control ? Self.armed : Self.key
            onControl?(control)
        }
    }

    private static let key = UIColor(white: 1, alpha: 0.10)
    private static let armed = UIColor(red: 0.20, green: 0.62, blue: 0.95, alpha: 1)

    init(width: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        build()

        // The token is kept and removed in `deinit`. The block-based observer is
        // not released when its object is: NotificationCenter holds it until it
        // is handed back, so a session-per-accessory app would accumulate one
        // dead observer per terminal ever opened.
        controlReset = NotificationCenter.default.addObserver(
            forName: .terminalViewControlModifierReset,
            object: nil,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Spent by a keystroke SwiftTerm handled. The button has to
                    // stop claiming otherwise.
                    self?.control = false
                }
            }
    }

    deinit {
        if let controlReset { NotificationCenter.default.removeObserver(controlReset) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The row is wider than any phone, so it scrolls. Ordered by how often a
    /// key is needed rather than by keyboard layout: the first screenful is
    /// Escape, Tab, Control, the arrows and the pipe.
    private func build() {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(button("esc") { [weak self] in self?.send([0x1b]) })
        stack.addArrangedSubview(button("tab") { [weak self] in self?.send([0x09]) })
        controlButton = button("ctrl") { [weak self] in
            guard let self else { return }
            control.toggle()
        }
        stack.addArrangedSubview(controlButton!)

        stack.addArrangedSubview(repeating("chevron.left", system: true) { [weak self] in
            guard let self else { return }
            send(applicationCursor() ? [0x1b, 0x4f, 0x44] : [0x1b, 0x5b, 0x44])
        })
        stack.addArrangedSubview(repeating("chevron.up", system: true) { [weak self] in
            guard let self else { return }
            send(applicationCursor() ? [0x1b, 0x4f, 0x41] : [0x1b, 0x5b, 0x41])
        })
        stack.addArrangedSubview(repeating("chevron.down", system: true) { [weak self] in
            guard let self else { return }
            send(applicationCursor() ? [0x1b, 0x4f, 0x42] : [0x1b, 0x5b, 0x42])
        })
        stack.addArrangedSubview(repeating("chevron.right", system: true) { [weak self] in
            guard let self else { return }
            send(applicationCursor() ? [0x1b, 0x4f, 0x43] : [0x1b, 0x5b, 0x43])
        })

        for character in ["|", "/", "\\", "-", "_", "~", ":", "*"] {
            stack.addArrangedSubview(button(character) { [weak self] in
                self?.send(Array(character.utf8))
            })
        }

        // Written out rather than composed from the ctrl button, because these
        // are the ones worth one tap: interrupt, end-of-file, suspend, clear.
        stack.addArrangedSubview(button("^C") { [weak self] in self?.send([0x03]) })
        stack.addArrangedSubview(button("^D") { [weak self] in self?.send([0x04]) })
        stack.addArrangedSubview(button("^Z") { [weak self] in self?.send([0x1a]) })
        stack.addArrangedSubview(button("^L") { [weak self] in self?.send([0x0c]) })

        stack.addArrangedSubview(button("home") { [weak self] in
            guard let self else { return }
            send(applicationCursor() ? [0x1b, 0x4f, 0x48] : [0x1b, 0x5b, 0x48])
        })
        stack.addArrangedSubview(button("end") { [weak self] in
            guard let self else { return }
            send(applicationCursor() ? [0x1b, 0x4f, 0x46] : [0x1b, 0x5b, 0x46])
        })
        stack.addArrangedSubview(button("pgup") { [weak self] in self?.send([0x1b, 0x5b, 0x35, 0x7e]) })
        stack.addArrangedSubview(button("pgdn") { [weak self] in self?.send([0x1b, 0x5b, 0x36, 0x7e]) })

        stack.addArrangedSubview(button("copy") { [weak self] in self?.onCopy?() })
        stack.addArrangedSubview(button("paste") { [weak self] in self?.onPaste?() })
        stack.addArrangedSubview(button("keyboard.chevron.compact.down", system: true) { [weak self] in
            self?.onDismiss?()
        })

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.addSubview(stack)
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -5),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -10),
        ])
    }

    // MARK: - Buttons

    private func button(_ label: String, system: Bool = false, action: @escaping () -> Void) -> UIButton {
        let button = ActionButton(type: .system)
        if system {
            button.setImage(UIImage(systemName: label), for: .normal)
        } else {
            button.setTitle(label, for: .normal)
            button.titleLabel?.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        }
        button.tintColor = .white
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = Self.key
        button.layer.cornerRadius = 6
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        button.action = action
        button.addTarget(button, action: #selector(ActionButton.fire), for: .touchUpInside)
        return button
    }

    /// A key that repeats while it is held. 600ms before the first repeat and
    /// ten a second after that, which is the cadence the OS keyboard uses.
    private func repeating(_ label: String, system: Bool, action: @escaping () -> Void) -> UIButton {
        let button = self.button(label, system: system, action: action)
        button.addTarget(self, action: #selector(holdBegan(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(holdEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return button
    }

    @objc private func holdBegan(_ sender: UIButton) {
        guard let button = sender as? ActionButton, let action = button.action else { return }
        cancelRepeat()
        repeatTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                MainActor.assumeIsolated { action() }
            }
        }
    }

    @objc private func holdEnded() {
        cancelRepeat()
    }

    private func cancelRepeat() {
        repeatTask?.cancel()
        repeatTask = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func send(_ bytes: [UInt8]) {
        UIDevice.current.playInputClick()
        onBytes?(bytes)
    }

    /// From `UIInputViewAudioFeedback`: the keyboard click a hardware-feeling
    /// key ought to make. Without the conformance `playInputClick` is silent.
    var enableInputClicksWhenVisible: Bool { true }
}

/// A button that carries its own action, so the repeat handler can find it.
/// Target-action with a stored closure rather than a `UIAction`, because a
/// `UIAction` cannot be read back off the button when a hold starts repeating.
private final class ActionButton: UIButton {
    var action: (() -> Void)?

    @objc func fire() {
        action?()
    }
}
