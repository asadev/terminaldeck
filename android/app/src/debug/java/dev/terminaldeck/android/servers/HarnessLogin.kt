package dev.terminaldeck.android.servers

import android.app.Activity
import android.content.Context
import android.util.Base64
import dev.terminaldeck.android.protocol.EnrollMethod

/**
 * A server login handed in by whoever launched the app, so the flow can be walked against a **real
 * server** rather than against a mock of one.
 *
 * ## Why this exists
 *
 * The interesting half of the login screen is what happens *after* the button — a real SSH
 * handshake, a real host key, a real probe of a real machine, the install, the connect — and none
 * of it can be photographed from a fixture. iOS makes exactly this argument in
 * `ServerLoginView.swift` and answers it the same way, with `TD_SERVER_ADDRESS` and friends read
 * from the process environment under `#if DEBUG`.
 *
 * The Android answer is the one this app already uses for the GitHub stand-in: an intent extra,
 * read in the **debug source set only**. `src/release/.../HarnessLogin.kt` returns null and
 * contains nothing else, so a shipped build has no code that could read one.
 *
 * ```
 * adb shell am start -n dev.terminaldeck.android.debug/dev.terminaldeck.android.MainActivity \
 *   -e td_server_address 178.105.239.176 \
 *   -e td_server_user root \
 *   -e td_server_key_base64 "$(base64 < ~/.ssh/id_ed25519)"
 * ```
 *
 * ## Why the key arrives base64
 *
 * Because a private key is seven lines, and `adb shell am start -e` hands its value through a shell
 * on the phone. A multi-line value does not survive that intact — iOS hit the same wall handing one
 * from `xcodebuild` to `launchEnvironment`, where it arrived empty, the Log in button stayed
 * disabled because there was no secret, and the walk sat waiting out its whole timeout for a screen
 * no button had been pressed to reach. One line goes through.
 *
 * ## What it does not do
 *
 * It fills the fields. It does not press anything, it does not bypass a check, and it does not put
 * a credential anywhere: the login that follows is the same code path a finger reaches, including
 * the validation, the handshake and the host-key check.
 */
data class HarnessLogin(
    val address: String,
    val port: String,
    val username: String,
    val secret: String,
    val method: EnrollMethod,
)

fun harnessLogin(context: Context): HarnessLogin? {
    val intent = (context as? Activity)?.intent ?: return null
    val address = intent.getStringExtra("td_server_address")?.trim().orEmpty()
    if (address.isEmpty()) return null

    val encoded = intent.getStringExtra("td_server_key_base64").orEmpty()
    val key = if (encoded.isEmpty()) {
        ""
    } else {
        try {
            String(Base64.decode(encoded, Base64.DEFAULT), Charsets.UTF_8)
        } catch (e: IllegalArgumentException) {
            ""
        }
    }
    val password = intent.getStringExtra("td_server_password").orEmpty()

    return HarnessLogin(
        address = address,
        port = intent.getStringExtra("td_server_port")?.trim().orEmpty(),
        username = intent.getStringExtra("td_server_user")?.trim().orEmpty(),
        secret = if (key.isNotEmpty()) key else password,
        method = if (key.isNotEmpty()) EnrollMethod.Key else EnrollMethod.Password,
    )
}
