/**
 * How long to wait before trying the socket again. A port of `pwa/src/backoff.ts`.
 *
 * A phone drops this connection constantly and for reasons that have nothing to
 * do with the desktop being down: the screen locks, the radio hands off from
 * wifi to cellular, the tunnel re-keys, a lift happens. The two failure modes to
 * avoid pull in opposite directions — reconnecting in a tight loop burns battery
 * and hammers the desktop's accept loop, while a fixed long wait leaves the
 * terminal dead for twenty seconds after a two-hundred-millisecond blip.
 *
 * Hence: start fast enough that a blip is invisible, grow, cap, and reset the
 * moment anything works. The caller also resets when the app returns to the
 * foreground, because at that point the schedule is describing a network
 * condition that has already ended.
 */

import Foundation

struct BackoffOptions {
    /// Wait before the first retry.
    var firstMs: Double
    /// Ceiling. Reached after roughly seven attempts with the defaults.
    var maxMs: Double
    /// Growth per attempt.
    var factor: Double
    /// Fraction of each delay that is randomised away, 0–1.
    var jitter: Double

    static let reconnect = BackoffOptions(firstMs: 400, maxMs: 20_000, factor: 1.8, jitter: 0.3)
}

/**
 * The delay for a zero-based attempt number, in seconds.
 *
 * The jitter is subtractive — it only ever shortens a delay. Additive jitter
 * would let a wait exceed `maxMs`, and the cap is a promise to the user about
 * the longest the app can look broken after the network returns.
 */
func backoffDelay(attempt: Int,
                  random: () -> Double = { Double.random(in: 0 ..< 1) },
                  options: BackoffOptions = .reconnect) -> TimeInterval {
    let step = Double(max(0, attempt))
    let raw = options.firstMs * pow(options.factor, step)
    let capped = min(options.maxMs, raw)
    let spread = capped * options.jitter * random()
    return max(0, (capped - spread).rounded()) / 1000
}

/// The schedule as a small object, so no caller tracks the counter itself.
final class Backoff {
    private var attempt = 0
    private let options: BackoffOptions
    private let random: () -> Double

    init(options: BackoffOptions = .reconnect, random: @escaping () -> Double = { Double.random(in: 0 ..< 1) }) {
        self.options = options
        self.random = random
    }

    /// Attempts since the last reset. Shown to the user, so it is not private.
    var attempts: Int { attempt }

    /// The next delay, and advance the schedule.
    func next() -> TimeInterval {
        let delay = backoffDelay(attempt: attempt, random: random, options: options)
        attempt += 1
        return delay
    }

    /// Back to the top. Called on a successful *connection*, not a successful socket.
    func reset() {
        attempt = 0
    }
}
