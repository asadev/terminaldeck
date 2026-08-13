package dev.terminaldeck.android.transport

import kotlin.math.min
import kotlin.math.pow
import kotlin.random.Random

/**
 * How long to wait before trying the socket again. Transcribed from `pwa/src/backoff.ts`.
 *
 * A phone drops this connection constantly and for reasons that have nothing to do with the Mac
 * being down: the screen locks, the radio hands off from wifi to cellular, a lift happens. The two
 * failure modes pull in opposite directions — a tight loop burns battery and hammers the relay,
 * while a fixed long wait leaves the terminal dead for twenty seconds after a blip — so: start fast
 * enough that a blip is invisible, grow, cap, and reset the moment anything works.
 *
 * The jitter is **subtractive**, so a delay can never exceed the cap. The cap is a promise about
 * the longest the app may look broken after the network comes back, and additive jitter would
 * quietly break it.
 */
class Backoff(
    private val firstMs: Long = 400,
    private val maxMs: Long = 20_000,
    private val factor: Double = 1.8,
    private val jitter: Double = 0.3,
    private val random: () -> Double = { Random.nextDouble() },
) {
    var attempts: Int = 0
        private set

    fun next(): Long {
        val raw = firstMs * factor.pow(attempts)
        val capped = min(maxMs.toDouble(), raw)
        val delay = (capped - capped * jitter * random()).toLong().coerceAtLeast(0)
        attempts += 1
        return delay
    }

    /** Back to the top. Called on a successful *connection*, not on a successful socket. */
    fun reset() {
        attempts = 0
    }
}
