package dev.terminaldeck.android.github

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The two ways a token gets onto this phone, and the refusals in between.
 *
 * Most of the code being exercised is not the happy path: it is GitHub's `authorization_pending` /
 * `slow_down` dance, and it is the part a manual test would never reach because it only happens
 * while somebody is walking to a browser. The HTTP is a seam so the whole flow runs with no network
 * and no `MockWebServer`.
 *
 * The claim these are really about: **the login comes from GitHub and never from anything a person
 * typed**. It is the name the approval prompt puts on screen, and a prompt that can name the wrong
 * account is worse than no prompt at all.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class GitHubSignInTest {

    /** Answers queued per URL, taken in order. An empty queue is a request nobody expected. */
    private class ScriptedHttp : GitHubHttp {
        private val answers = mutableMapOf<String, ArrayDeque<GitHubAnswer>>()
        val posted = mutableListOf<Pair<String, Map<String, String>>>()
        var lastToken: String? = null
            private set

        fun on(url: String, vararg replies: GitHubAnswer) {
            answers.getOrPut(url) { ArrayDeque() }.addAll(replies)
        }

        override suspend fun postForm(url: String, fields: Map<String, String>): GitHubAnswer {
            posted += url to fields
            return answers[url]?.removeFirstOrNull() ?: GitHubAnswer(500, "")
        }

        override suspend fun getWithToken(url: String, token: String): GitHubAnswer {
            lastToken = token
            return answers[url]?.removeFirstOrNull() ?: GitHubAnswer(500, "")
        }
    }

    private val endpoints = GitHubEndpoints(
        deviceCode = "https://example.test/device",
        accessToken = "https://example.test/token",
        user = "https://example.test/user",
    )

    private fun signIn(http: GitHubHttp, scope: TestScope, accounts: GitHubAccountStore) =
        GitHubSignIn(accounts = accounts, scope = scope, http = http, endpoints = endpoints)

    @Test
    fun `the device flow waits out authorization_pending and adopts the account GitHub names`() = runTest(
        UnconfinedTestDispatcher()
    ) {
        val http = ScriptedHttp()
        http.on(
            endpoints.deviceCode,
            GitHubAnswer(
                200,
                """{"device_code":"dev-1","user_code":"ABCD-1234",""" +
                    """"verification_uri":"https://github.com/login/device","interval":5,"expires_in":900}"""
            ),
        )
        http.on(
            endpoints.token,
            GitHubAnswer(200, """{"error":"authorization_pending"}"""),
            GitHubAnswer(200, """{"error":"slow_down"}"""),
            GitHubAnswer(200, """{"access_token":"gho_real"}"""),
        )
        http.on(endpoints.user, GitHubAnswer(200, """{"login":"asadev","id":1}"""))

        val accounts = InMemoryGitHubStore()
        val flow = signIn(http, this, accounts)
        flow.start()
        advanceUntilIdle()

        assertEquals("gho_real", accounts.token())
        assertEquals("asadev", accounts.account()?.login)
        assertEquals(GitHubAccount.Source.SignIn, accounts.account()?.source)
        assertEquals(SignInPhase.Idle, flow.phase)
    }

    @Test
    fun `the code is shown as text and the plain verification uri is what gets opened`() = runTest(
        UnconfinedTestDispatcher()
    ) {
        // `verification_uri_complete` is deliberately never read: it fills the field in for you,
        // which makes it a link that grants access if it is forwarded.
        val http = ScriptedHttp()
        http.on(
            endpoints.deviceCode,
            GitHubAnswer(
                200,
                """{"device_code":"dev-1","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device",""" +
                    """"verification_uri_complete":"https://github.com/login/device?user_code=ABCD-1234"}"""
            ),
        )
        // Nothing queued for the token endpoint, so the poll fails and the phase stops moving —
        // this test only cares about what `waiting` carried.
        val flow = signIn(http, this, InMemoryGitHubStore())
        flow.start()

        val phase = flow.phase
        assertTrue("expected a waiting phase, got $phase", phase is SignInPhase.Waiting)
        phase as SignInPhase.Waiting
        assertEquals("ABCD-1234", phase.userCode)
        assertEquals("https://github.com/login/device", phase.verificationUri)
        flow.cancel()
    }

    @Test
    fun `a device code over a plain http uri is refused`() = runTest(UnconfinedTestDispatcher()) {
        val http = ScriptedHttp()
        http.on(
            endpoints.deviceCode,
            GitHubAnswer(200, """{"device_code":"d","user_code":"C","verification_uri":"http://github.com/login/device"}"""),
        )
        val flow = signIn(http, this, InMemoryGitHubStore())
        flow.start()
        advanceUntilIdle()

        assertEquals(SignInPhase.Failed("GitHub did not hand back a sign-in code."), flow.phase)
    }

    @Test
    fun `a cancelled sign-in says so in words somebody can act on`() = runTest(UnconfinedTestDispatcher()) {
        val http = ScriptedHttp()
        http.on(
            endpoints.deviceCode,
            GitHubAnswer(200, """{"device_code":"d","user_code":"C","verification_uri":"https://github.com/login/device"}"""),
        )
        http.on(endpoints.token, GitHubAnswer(200, """{"error":"access_denied"}"""))

        val flow = signIn(http, this, InMemoryGitHubStore())
        flow.start()
        advanceUntilIdle()

        assertEquals(SignInPhase.Failed("That sign-in was cancelled on GitHub."), flow.phase)
    }

    @Test
    fun `a pasted token is validated by being used`() = runTest(UnconfinedTestDispatcher()) {
        val http = ScriptedHttp()
        http.on(endpoints.user, GitHubAnswer(200, """{"login":"someone"}"""))

        val accounts = InMemoryGitHubStore()
        signIn(http, this, accounts).useToken("  github_pat_x  ")
        advanceUntilIdle()

        assertEquals("github_pat_x", http.lastToken)
        // The login is GitHub's answer, never a field somebody filled in.
        assertEquals("someone", accounts.account()?.login)
        assertEquals(GitHubAccount.Source.Token, accounts.account()?.source)
    }

    @Test
    fun `a token GitHub will not accept never becomes an account`() = runTest(UnconfinedTestDispatcher()) {
        val http = ScriptedHttp()
        http.on(endpoints.user, GitHubAnswer(401, """{"message":"Bad credentials"}"""))

        val accounts = InMemoryGitHubStore()
        val flow = signIn(http, this, accounts)
        flow.useToken("github_pat_wrong")
        advanceUntilIdle()

        assertNull(accounts.account())
        assertEquals(SignInPhase.Failed("GitHub did not accept that token."), flow.phase)
    }

    @Test
    fun `an empty paste is refused before anything is sent`() = runTest(UnconfinedTestDispatcher()) {
        val http = ScriptedHttp()
        val flow = signIn(http, this, InMemoryGitHubStore())
        flow.useToken("   ")

        assertEquals(SignInPhase.Failed("Paste a token first."), flow.phase)
        assertNull(http.lastToken)
    }

    @Test
    fun `a paste longer than the wire allows is caught here rather than on the first push`() = runTest(
        UnconfinedTestDispatcher()
    ) {
        // The desktop refuses a longer secret and answers a refused frame by closing the socket, so
        // it would cost the connection rather than the push.
        val http = ScriptedHttp()
        val flow = signIn(http, this, InMemoryGitHubStore())
        flow.useToken("x".repeat(dev.terminaldeck.android.protocol.Protocol.MAX_CREDENTIAL_SECRET_LENGTH + 1))

        assertEquals(
            SignInPhase.Failed("That is longer than a GitHub token. Check what was pasted."),
            flow.phase,
        )
        assertNull(http.lastToken)
    }

    @Test
    fun `no sentence anywhere in this flow can carry a token`() = runTest(UnconfinedTestDispatcher()) {
        // A failure quoting a request would be the one place a secret escaped. Every sentence a
        // person reads is written in `GitHubSignIn`, and this is the check that it stays that way.
        val http = ScriptedHttp()
        http.on(endpoints.user, GitHubAnswer(500, """{"message":"gho_leaked"}"""))

        val flow = signIn(http, this, InMemoryGitHubStore())
        flow.useToken("gho_leaked")
        advanceUntilIdle()

        val sentence = (flow.phase as SignInPhase.Failed).sentence
        assertTrue(sentence, !sentence.contains("gho_leaked"))
    }
}

/** Named so the endpoints read the way they are used above. */
private val GitHubEndpoints.token: String get() = accessToken
