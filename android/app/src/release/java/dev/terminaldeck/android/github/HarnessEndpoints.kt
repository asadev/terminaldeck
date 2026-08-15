package dev.terminaldeck.android.github

import android.content.Context

/**
 * There is no harness in a release build.
 *
 * The debug source set has a version of this that reads a launch extra so a test can point the
 * three GitHub requests at a stand-in — see `src/debug/.../HarnessEndpoints.kt` for why that is
 * worth having and what it costs. This is the release half, and it is the reason that cost is
 * bounded: nothing in a shipped app can redirect where a token is validated, because the code that
 * could is not compiled into it.
 *
 * Null, always, with no argument read.
 */
@Suppress("UNUSED_PARAMETER")
fun harnessGitHubEndpoints(context: Context): GitHubEndpoints? = null
