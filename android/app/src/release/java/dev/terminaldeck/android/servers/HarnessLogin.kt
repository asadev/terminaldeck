package dev.terminaldeck.android.servers

import android.content.Context
import dev.terminaldeck.android.protocol.EnrollMethod

/**
 * There is no harness in a release build.
 *
 * The debug source set has a version of this that reads launch extras so a walk can drive the
 * server login against a real machine — see `src/debug/.../HarnessLogin.kt` for why that is worth
 * having and what it costs. This is the release half, and it is the reason that cost is bounded:
 * nothing in a shipped app can put an address, a username or a key into that form from outside,
 * because the code that could is not compiled into it.
 *
 * Null, always, with no argument read.
 */
data class HarnessLogin(
    val address: String,
    val port: String,
    val username: String,
    val secret: String,
    val method: EnrollMethod,
)

@Suppress("UNUSED_PARAMETER")
fun harnessLogin(context: Context): HarnessLogin? = null
