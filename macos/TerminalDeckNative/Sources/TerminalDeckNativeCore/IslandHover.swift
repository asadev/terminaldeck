import Foundation

/// When the island grows and when it settles. Pure: every event carries the time,
/// and the owner calls `advance(to:)` at `deadline` — so a test drives it with a
/// fake clock and nothing waits.
///
/// - The pointer resting on the pill for `openDelay` grows it (a pointer just
///   passing over does not).
/// - A click grows it at once; it then has the keyboard and stays while it does.
/// - It settles `closeDelay` after the pointer leaves (coming back in time keeps
///   it), when the keyboard goes elsewhere with the pointer off it, or on Escape.
/// - Settled on purpose (Escape) with the pointer still on it, it does not grow
///   again until the pointer has left and come back.
/// - It never grows while there is nothing to show (`available` false).
public struct IslandHover: Equatable, Sendable {
    public static let defaultOpenDelay: TimeInterval = 0.12
    public static let defaultCloseDelay: TimeInterval = 0.25

    public let openDelay: TimeInterval
    public let closeDelay: TimeInterval

    public private(set) var expanded = false
    public private(set) var pointerInside = false
    public private(set) var hasKeyboard = false
    /// The expanded page is loaded and can be shown.
    public private(set) var available = false
    public private(set) var quiet = false
    public private(set) var openAt: TimeInterval?
    public private(set) var closeAt: TimeInterval?

    public init(openDelay: TimeInterval = IslandHover.defaultOpenDelay,
                closeDelay: TimeInterval = IslandHover.defaultCloseDelay) {
        self.openDelay = openDelay
        self.closeDelay = closeDelay
    }

    /// The next time `advance(to:)` has something to do, if any.
    public var deadline: TimeInterval? {
        switch (openAt, closeAt) {
        case let (open?, close?): return min(open, close)
        case let (open?, nil): return open
        case let (nil, close?): return close
        case (nil, nil): return nil
        }
    }

    public mutating func setAvailable(_ value: Bool) {
        available = value
        guard !value else { return }
        expanded = false
        openAt = nil
        closeAt = nil
    }

    public mutating func pointerEntered(at now: TimeInterval) {
        pointerInside = true
        closeAt = nil
        guard available, !expanded, !quiet, openAt == nil else { return }
        openAt = now + openDelay
    }

    public mutating func pointerExited(at now: TimeInterval) {
        pointerInside = false
        quiet = false
        openAt = nil
        if expanded, !hasKeyboard { closeAt = now + closeDelay }
    }

    /// A click on the island (pill or panel).
    public mutating func pressed(at now: TimeInterval) {
        quiet = false
        openAt = nil
        closeAt = nil
        guard available else { return }
        expanded = true
    }

    /// The island became (or stopped being) the key window.
    public mutating func keyboardChanged(_ has: Bool, at now: TimeInterval) {
        hasKeyboard = has
        if has {
            closeAt = nil
            return
        }
        // The keyboard went somewhere else — a click outside. Settle, unless the
        // pointer is still on it; then it settles when the pointer leaves.
        if expanded, !pointerInside {
            expanded = false
            closeAt = nil
        }
    }

    /// Escape, or anything else that settles it on purpose.
    public mutating func dismiss() {
        openAt = nil
        closeAt = nil
        guard expanded || pointerInside else { return }
        expanded = false
        if pointerInside { quiet = true }
    }

    public mutating func advance(to now: TimeInterval) {
        if let open = openAt, now >= open {
            openAt = nil
            if pointerInside, available, !quiet, !expanded { expanded = true }
        }
        if let close = closeAt, now >= close {
            closeAt = nil
            if !pointerInside, !hasKeyboard { expanded = false }
        }
    }
}
