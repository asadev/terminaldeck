/**
 * One key cap — on the fixed bar and in the grid, the same button.
 *
 * Shared rather than written twice because the states are the interesting part
 * and there must be one of them. The bar this replaces had **no pressed state at
 * all**: a key looked identical before, during and after a tap, so on a slow
 * connection every press felt like it had missed. The design brief's rule is
 * that a control which looks pressable must respond, and on a key bar that is
 * not decoration — it is the only feedback there is, because what the key did
 * happens on a machine in another room.
 *
 * ## Auto-repeat lives here
 *
 * Holding an arrow has to repeat or scrolling back through history is one tap
 * per line. 600ms before the first repeat and ten a second after that, which is
 * the cadence the OS keyboard itself uses. Only the keys that *say* they repeat
 * do: holding `~` to get forty tildes is not a thing anyone wants, and holding
 * `^C` to send forty interrupts is actively bad.
 */

import UIKit

@MainActor
final class KeyCapButton: UIButton {

    let cap: KeyCap

    /// Whether this is a sticky modifier that is currently armed. Drawn in the
    /// accent, because an armed modifier is the one thing on this bar that is
    /// *about to* change what the next keystroke means.
    var isArmed = false {
        didSet {
            guard isArmed != oldValue else { return }
            restyle()
        }
    }

    private let press: (KeyCap) -> Void
    private var repeatTask: Task<Void, Never>?
    private var repeatTimer: Timer?

    init(cap: KeyCap, press: @escaping (KeyCap) -> Void) {
        self.cap = cap
        self.press = press
        super.init(frame: .zero)

        setTitle(cap.label, for: .normal)
        // Mono, and this is the one place mono is right in the chrome: these
        // caps *are* the characters that will appear in the terminal, so they
        // are set in the face the terminal will set them in.
        titleLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.75
        titleLabel?.lineBreakMode = .byClipping
        layer.cornerRadius = 7
        layer.cornerCurve = .continuous
        // The glyph is not a word. VoiceOver reading "up arrow" instead of the
        // character is the difference between a usable bar and a row of noises.
        accessibilityLabel = cap.title
        // …and because that replaces the label, the cap needs an identifier of
        // its own for anything looking the key up by what is written on it.
        // Without this `app.buttons["esc"]` finds nothing — measured, in a UI
        // test run that reported the bar as missing every key it was showing.
        accessibilityIdentifier = cap.label
        restyle()

        addTarget(self, action: #selector(fire), for: .touchUpInside)
        if cap.repeats {
            addTarget(self, action: #selector(holdBegan), for: .touchDown)
            addTarget(self, action: #selector(holdEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        // Not `cancelRepeat()`: this is `deinit`, which is not main-actor
        // isolated, and the two objects being torn down here are safe to touch
        // from anywhere. A `Task` cancel is thread-safe by construction, and a
        // timer that has already fired for the last time has nothing to race.
        repeatTask?.cancel()
        repeatTimer?.invalidate()
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            restyle()
        }
    }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            restyle()
        }
    }

    /// One place decides what a key looks like, so the four states cannot drift
    /// apart: at rest, under a finger, armed, and refusing.
    private func restyle() {
        let background: UIColor
        let ink: UIColor
        if !isEnabled {
            // Its own colour rather than `Palette.key` at a lower alpha:
            // `withAlphaComponent` on a colour built from a dynamic provider is
            // not documented to keep the provider, and a disabled cap frozen at
            // whichever appearance the app launched in would be a wrong-coloured
            // key that only some people ever see. See `Palette.keyDisabled`.
            background = Palette.keyDisabled
            ink = Palette.keyLabelFaint
        } else if isArmed {
            background = Palette.keyArmed
            ink = Palette.onArmed
        } else if isHighlighted {
            background = Palette.keyPressed
            ink = Palette.keyLabel
        } else {
            background = Palette.key
            ink = Palette.keyLabel
        }
        backgroundColor = background
        setTitleColor(ink, for: .normal)
        tintColor = ink
    }

    @objc private func fire() {
        press(cap)
    }

    @objc private func holdBegan() {
        cancelRepeat()
        repeatTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            // `[weak self]` again inside the timer's block, and not for tidiness:
            // the timer is owned by this button, so a strong capture here is a
            // cycle that outlives every terminal the app ever opens.
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.press(self.cap)
                }
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
}

/**
 * The two buttons pinned to the right of the bar — *more* and *dismiss*.
 *
 * A separate type from `KeyCapButton` on purpose. They are not keys: they send
 * nothing to the session, they never repeat, and they must never be mistaken for
 * the row of caps beside them — which is exactly what went wrong in the bar this
 * replaces, where dismiss was the twenty-sixth item in a scroll view and read as
 * one more key you had to go and find.
 */
@MainActor
final class KeyChromeButton: UIButton {

    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            restyle()
        }
    }

    private let tap: () -> Void

    init(systemImage: String, title: String, tap: @escaping () -> Void) {
        self.tap = tap
        super.init(frame: .zero)
        setImage(UIImage(systemName: systemImage,
                         withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)),
                 for: .normal)
        layer.cornerRadius = 7
        layer.cornerCurve = .continuous
        accessibilityLabel = title
        restyle()
        addTarget(self, action: #selector(fire), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            restyle()
        }
    }

    private func restyle() {
        if isOn {
            backgroundColor = Palette.keyArmed
            tintColor = Palette.onArmed
        } else {
            backgroundColor = isHighlighted ? Palette.keyPressed : Palette.key
            tintColor = Palette.keyLabel
        }
    }

    @objc private func fire() {
        tap()
    }
}
