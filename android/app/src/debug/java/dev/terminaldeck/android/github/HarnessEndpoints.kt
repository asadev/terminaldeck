package dev.terminaldeck.android.github

import android.app.Activity
import android.content.Context

/**
 * Where GitHub is, when a test launched this app pointing somewhere else.
 *
 * ## Why this exists at all
 *
 * The approval prompt cannot be exercised end to end without an account, and an account cannot be
 * had without a token GitHub will accept. That leaves three options and only one of them is
 * acceptable:
 *
 *  1. Keep a real person's GitHub token in the repository. Out of the question.
 *  2. Write a back door that puts a token in the store from a launch argument. That is a code path
 *     in the shipping app whose whole job is to fake being signed in.
 *  3. Point the one request that validates a token at a stand-in, the way `android/tools/dev-host.cjs`
 *     already stands in for a Mac. The token still has to be pasted, the login still comes back
 *     over HTTP, and the code under test is the code that ships.
 *
 * This is the third. It is the same choice `ios/TerminalDeck/Transport/GitHubSignIn.swift` makes
 * with `#if DEBUG` and `TD_GITHUB_BASE`, for the same reasons and with the same limits.
 *
 * ## Why it cannot be turned on in a shipped build
 *
 * It is in the **debug source set**. The release variant compiles
 * `src/release/.../HarnessEndpoints.kt` instead, which returns null and contains nothing else —
 * there is no environment variable, no manifest flag and no setting that reaches this code, because
 * in a release build this file is not there.
 *
 * In a debug build it reads one intent extra, which only whoever launched the app can set:
 *
 * ```
 * adb shell am start -n dev.terminaldeck.android.debug/dev.terminaldeck.android.MainActivity \
 *   -e td_github_base http://10.0.2.2:8124
 * ```
 *
 * Cleartext to `10.0.2.2` is what the debug network security config already allows, and for the
 * same reason: it is how an emulator reaches the machine it is running on.
 *
 * Nothing on the wire and nothing on screen can move it.
 */
fun harnessGitHubEndpoints(context: Context): GitHubEndpoints? {
    val base = (context as? Activity)?.intent?.getStringExtra(HARNESS_EXTRA)?.trimEnd('/') ?: return null
    if (base.isEmpty()) return null
    // Two hosts fold onto one base — `github.com` and `api.github.com` differ only in which paths
    // they serve, and the stand-in serves all three.
    return GitHubEndpoints(
        deviceCode = "$base/login/device/code",
        accessToken = "$base/login/oauth/access_token",
        user = "$base/user",
    )
}

private const val HARNESS_EXTRA = "td_github_base"
