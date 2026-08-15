package dev.terminaldeck.android.github

import dev.terminaldeck.android.protocol.Protocol
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Getting a GitHub token onto this phone, the two ways a person can.
 *
 * Both end in the same place — a login and a secret in [GitHubAccountStore] — and neither of them
 * puts anything on anybody else's machine. That is the point of the whole exercise: the token is
 * obtained here, kept here, and spent one request at a time over a channel that is already sealed.
 *
 * ## Sign in
 *
 * The **device flow**, which is the only OAuth shape that works from an app with no server behind
 * it: no redirect URI to register, no client secret to ship, no loopback listener. GitHub hands back
 * a short code, the browser takes it, and this polls until somebody has typed it. `github-auth.ts`
 * on the desktop and `GitHubSignIn.swift` on iOS do exactly this and all three agree on the client
 * id on purpose — one registration for one product.
 *
 * ### The OAuth client is borrowed, and the sign-in screen says so
 *
 * The id below is the GitHub CLI's: a public identifier printed in an open-source binary, with no
 * client secret involved because the device flow has none by design. This project has not
 * registered an application of its own yet.
 *
 * What it costs is honesty about identity: GitHub's consent page will say "GitHub CLI", not this
 * app's name. That is not something to hide behind a spinner, so [CLIENT_IS_BORROWED] is part of
 * the surface and the screen prints a line about it. Registering an application and changing the
 * constant makes both the caveat and the sentence disappear on their own.
 *
 * ## Paste a token
 *
 * The fallback the design keeps on purpose, and it is a good one: a **fine-grained personal access
 * token**, scoped to a single repository, with an expiry. Somebody who does not want an OAuth grant
 * on their account gets a blast radius of one repository they already chose to share. It is
 * validated by being used — the login comes from GitHub's answer to `GET /user`, never from
 * something a person typed — because the login is what the approval prompt names, and a prompt that
 * can name the wrong account is worse than no prompt.
 *
 * ## Nothing here logs anything
 *
 * No `Log` call, no error carrying a response body, and no token in any string that leaves this
 * file. The failures a person can act on are enumerated as sentences written here; everything else
 * becomes one general sentence rather than a transcript that might contain a secret.
 */

/** One HTTP answer, reduced to the two things this file reads. */
data class GitHubAnswer(val status: Int, val body: String)

/**
 * The HTTP this needs, as a seam.
 *
 * Injected so the whole flow can be exercised with no network and no `MockWebServer` — and so a
 * test can drive GitHub's `authorization_pending` / `slow_down` dance, which is most of the code
 * here and none of the code a happy-path test would touch.
 */
interface GitHubHttp {
    /** Form-encoded POST, `Accept: application/json`. */
    suspend fun postForm(url: String, fields: Map<String, String>): GitHubAnswer

    /** `GET` with a bearer token. */
    suspend fun getWithToken(url: String, token: String): GitHubAnswer
}

/** The three addresses this app talks to. A parameter only so the tests can stand in for them. */
data class GitHubEndpoints(
    val deviceCode: String = "https://github.com/login/device/code",
    val accessToken: String = "https://github.com/login/oauth/access_token",
    val user: String = "https://api.github.com/user",
)

/**
 * Where the flow is, in the only vocabulary the screen may draw.
 *
 * [Waiting] carries the code as text and the URL separately, deliberately: GitHub's
 * `verification_uri_complete` fills the field in for you, which makes it a link that grants access
 * if it is forwarded. The code is read off the screen and typed.
 */
sealed interface SignInPhase {
    data object Idle : SignInPhase

    /** Asking GitHub for a code. Sub-second; it exists so the button has a state rather than looking dead. */
    data object Starting : SignInPhase

    data class Waiting(val userCode: String, val verificationUri: String) : SignInPhase

    /** The code was entered, or a token was pasted; this is reading the account name back. */
    data object Finishing : SignInPhase

    /** Something went wrong, in a sentence somebody can act on. */
    data class Failed(val sentence: String) : SignInPhase
}

class GitHubSignIn(
    private val accounts: GitHubAccountStore,
    private val scope: CoroutineScope,
    private val http: GitHubHttp = OkHttpGitHub(),
    private val endpoints: GitHubEndpoints = GitHubEndpoints(),
    private val onChange: () -> Unit = {},
) {

    var phase: SignInPhase = SignInPhase.Idle
        private set

    /**
     * True while either route is in flight, so both buttons can be disabled together.
     *
     * Two sign-ins racing to write the same store is a state nobody needs to reason about.
     */
    val isBusy: Boolean
        get() = phase is SignInPhase.Starting || phase is SignInPhase.Waiting || phase is SignInPhase.Finishing

    private var work: Job? = null

    /* ------------------------------------------------------------------ sign in -- */

    fun start() {
        if (isBusy) return
        work?.cancel()
        set(SignInPhase.Starting)
        work = scope.launch {
            try {
                val code = requestDeviceCode()
                set(SignInPhase.Waiting(userCode = code.userCode, verificationUri = code.verificationUri))
                val token = awaitToken(code)
                set(SignInPhase.Finishing)
                adopt(token, GitHubAccount.Source.SignIn)
            } catch (e: CancellationException) {
                // The screen went away mid-flow. Not a failure to report to somebody who is no
                // longer looking at it.
                throw e
            } catch (e: Throwable) {
                set(SignInPhase.Failed(sentenceFor(e)))
            }
        }
    }

    /**
     * Stop polling and go back to the start.
     *
     * Called when the sheet closes, so a coroutine does not keep waking the radio every five
     * seconds for a code nobody is going to enter.
     */
    fun cancel() {
        work?.cancel()
        work = null
        set(SignInPhase.Idle)
    }

    /** Clear a failure without starting anything, so the screen has a way back to its buttons. */
    fun clearFailure() {
        if (phase is SignInPhase.Failed) set(SignInPhase.Idle)
    }

    /* ------------------------------------------------------------ paste a token -- */

    fun useToken(raw: String) {
        if (isBusy) return
        val token = raw.trim()
        if (token.isEmpty()) {
            set(SignInPhase.Failed("Paste a token first."))
            return
        }
        if (token.length > Protocol.MAX_CREDENTIAL_SECRET_LENGTH) {
            // The desktop refuses a longer secret and answers a refused frame by closing the
            // socket, so this is caught at the one moment a person can do something about it rather
            // than on the first push.
            set(SignInPhase.Failed("That is longer than a GitHub token. Check what was pasted."))
            return
        }
        work?.cancel()
        set(SignInPhase.Finishing)
        work = scope.launch {
            try {
                adopt(token, GitHubAccount.Source.Token)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                set(SignInPhase.Failed(sentenceFor(e)))
            }
        }
    }

    /* ----------------------------------------------------------------- the flow -- */

    private data class DeviceCode(
        val deviceCode: String,
        val userCode: String,
        val verificationUri: String,
        val intervalMs: Long,
        val expiresAtMs: Long,
    )

    private suspend fun requestDeviceCode(): DeviceCode {
        val json = postJson(endpoints.deviceCode, mapOf("client_id" to CLIENT_ID, "scope" to SCOPES))
        val deviceCode = json.text("device_code")
        val userCode = json.text("user_code")
        val uri = json.text("verification_uri")
        if (deviceCode.isNullOrEmpty() || userCode.isNullOrEmpty() || uri.isNullOrEmpty() ||
            !uri.startsWith("https://")
        ) {
            throw Refusal("GitHub did not hand back a sign-in code.")
        }
        // Both are advisory and both have floors: a zero interval would become a request loop, and
        // a zero expiry would give up before the browser had opened.
        val interval = maxOf(json.number("interval") ?: 5.0, 5.0)
        val lifetime = maxOf(json.number("expires_in") ?: 900.0, 60.0)
        return DeviceCode(
            deviceCode = deviceCode,
            userCode = userCode,
            verificationUri = uri,
            intervalMs = (interval * 1000).toLong(),
            expiresAtMs = System.currentTimeMillis() + (lifetime * 1000).toLong(),
        )
    }

    private suspend fun awaitToken(code: DeviceCode): String {
        var wait = code.intervalMs
        while (System.currentTimeMillis() < code.expiresAtMs) {
            delay(wait)
            val json = postJson(
                endpoints.accessToken,
                mapOf(
                    "client_id" to CLIENT_ID,
                    "device_code" to code.deviceCode,
                    "grant_type" to "urn:ietf:params:oauth:grant-type:device_code",
                ),
            )
            val token = json.text("access_token")
            if (!token.isNullOrEmpty()) return token

            when (json.text("error")) {
                "authorization_pending" -> Unit
                // GitHub's own instruction, and ignoring it gets the flow rate-limited rather than
                // merely slowed.
                "slow_down" -> wait += 5_000
                "expired_token" -> throw Refusal("That code expired. Start again.")
                "access_denied" -> throw Refusal("That sign-in was cancelled on GitHub.")
                else -> throw Refusal("GitHub refused the sign-in.")
            }
        }
        throw Refusal("That code expired. Start again.")
    }

    /**
     * Read the account name off GitHub and write both halves away.
     *
     * The login comes from GitHub rather than from anything a person typed, because it is what the
     * approval prompt names — and the prompt is the entire explanation of this feature. A name this
     * app guessed at would make it a decoration.
     */
    private suspend fun adopt(token: String, source: GitHubAccount.Source) {
        val answer = http.getWithToken(endpoints.user, token)
        if (answer.status == 401) throw Refusal("GitHub did not accept that token.")
        val login = if (answer.status == 200) parse(answer.body)?.text("login") else null
        if (login.isNullOrEmpty()) throw Refusal("GitHub would not say which account that is.")
        if (login.length > Protocol.MAX_CREDENTIAL_USERNAME_LENGTH) {
            // A login this long is not one GitHub issued. It would be refused by the desktop's
            // parser on the first push, which closes the socket — so it is refused here instead,
            // where the only cost is a sentence.
            throw Refusal("GitHub answered with an account name this app cannot use.")
        }
        accounts.connect(login = login, token = token, source = source)
        set(SignInPhase.Idle)
    }

    /* --------------------------------------------------------------------- http -- */

    private suspend fun postJson(url: String, fields: Map<String, String>): JsonObject {
        val answer = http.postForm(url, fields)
        return parse(answer.body) ?: throw Refusal(
            if (answer.status == 404) {
                "GitHub did not recognise this app's sign-in."
            } else {
                "GitHub answered with something this app could not read."
            }
        )
    }

    private fun parse(body: String): JsonObject? = try {
        LENIENT.parseToJsonElement(body) as? JsonObject
    } catch (e: Exception) {
        null
    }

    private fun set(next: SignInPhase) {
        phase = next
        onChange()
    }

    companion object {
        /**
         * The GitHub CLI's public device-flow client id.
         *
         * Shared with `github-auth.ts` and `GitHubSignIn.swift`, where it is documented at length
         * and where it was checked against the live endpoint on 2026-08-15.
         */
        private const val CLIENT_ID = "178c6fc778ccc68e1d6a"

        /** Whether the id above is still somebody else's. Read by the screen, which says so. */
        const val CLIENT_IS_BORROWED = true

        /**
         * What this app asks for, and nothing else.
         *
         * `repo` alone. The desktop asks for `read:org` and `notifications` as well because it draws
         * pull request lists and a notification badge; this app does one thing with a token — hand
         * it to a `git` process that is fetching or pushing — and every extra scope is something a
         * person has to agree to hand over for a feature that is not there.
         */
        private const val SCOPES = "repo"

        private val LENIENT = Json { ignoreUnknownKeys = true; isLenient = true }
    }
}

/**
 * A failure, as a sentence and never as a transcript.
 *
 * Everything a person reads about this flow is written in `GitHubSignIn`. An exception from OkHttp
 * is turned into one general line rather than surfaced, because the requests in this module carry a
 * bearer token and a message that helpfully quoted a request would be the one place a secret
 * escaped.
 */
class Refusal(val sentence: String) : Exception(sentence)

private fun sentenceFor(error: Throwable): String =
    (error as? Refusal)?.sentence ?: "That did not reach GitHub. Check the connection and try again."

private fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

private fun JsonObject.number(key: String): Double? = (this[key] as? JsonPrimitive)?.doubleOrNull

/* -------------------------------------------------------------------------- */

/**
 * The real HTTP, on OkHttp — the client this app already ships for the WebSocket transport.
 *
 * `Dispatchers.IO` rather than OkHttp's own callback queue: the flow above is written as suspending
 * code, and `execute` on a coroutine dispatcher meant for computation is how a phone ends up with a
 * blocked main thread on a slow network.
 */
class OkHttpGitHub(private val client: OkHttpClient = OkHttpClient()) : GitHubHttp {

    override suspend fun postForm(url: String, fields: Map<String, String>): GitHubAnswer =
        withContext(Dispatchers.IO) {
            val body = FormBody.Builder().apply {
                for ((name, value) in fields) add(name, value)
            }.build()
            val request = Request.Builder()
                .url(url)
                .post(body)
                // Without this GitHub answers the device endpoints in
                // `application/x-www-form-urlencoded`, which parses to nothing here and looks
                // exactly like a refusal.
                .header("Accept", "application/json")
                .build()
            send(request)
        }

    override suspend fun getWithToken(url: String, token: String): GitHubAnswer =
        withContext(Dispatchers.IO) {
            val request = Request.Builder()
                .url(url)
                .get()
                .header("Authorization", "Bearer $token")
                .header("Accept", "application/vnd.github+json")
                .header("X-GitHub-Api-Version", "2022-11-28")
                .build()
            send(request)
        }

    // `FormBody` percent-encodes each field itself, which is why nothing here reaches for
    // `URLEncoder`: one fewer place to get the encoding of a device code wrong.
    private fun send(request: Request): GitHubAnswer = client.newCall(request).execute().use { response ->
        GitHubAnswer(status = response.code, body = response.body?.string() ?: "")
    }
}
