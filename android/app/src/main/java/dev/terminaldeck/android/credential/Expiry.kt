package dev.terminaldeck.android.credential

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * How a delayed thing is scheduled, so a decide/read/apply window can be tested by moving a hand
 * rather than by waiting out a real timer.
 *
 * [after] returns the function that cancels it. That is what removes the need for a generation
 * counter in the request clusters that use this: a thing leaving the screen cancels its own timer,
 * so a timer armed for one request cannot fire against a later one because it is no longer running.
 *
 * A fun interface so a test can hand over a hand-cranked one and drive the timeouts deterministically.
 * The whole app's request/response clusters — settings, the device roster, the session bar, the
 * copilot, the tunnels — share this one seam.
 */
fun interface Expiry {
    fun after(ms: Long, onExpired: () -> Unit): () -> Unit
}

/** The real one: a coroutine on the caller's scope. */
fun coroutineExpiry(scope: CoroutineScope): Expiry = Expiry { ms, onExpired ->
    val job: Job = scope.launch {
        delay(ms)
        onExpired()
    }
    ({ job.cancel() })
}
