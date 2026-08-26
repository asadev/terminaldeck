package dev.terminaldeck.android.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What a login is called on the bar, and the four ways that has gone wrong.
 *
 * The rule is pure — an [AccountWire] and a [SignInWire] in, a string out — so every case Asad has
 * reported about it can be written down here rather than re-found on a device. The screen itself is
 * checked by looking at it; what a screenshot cannot show is *why* a row says what it says, and each
 * of these is a decision that would keep passing a glance while being wrong.
 *
 * The complaint they exist for, 2026-08-26, on the account sheet on his phone reading "Default",
 * "Default (Codex CLI)", "Default (Gemini CLI)":
 *
 *   > *"when we click on this link it should clearly mention the name of the account here instead of
 *   > saying default — name of the account should be there."*
 */
class AccountNamingTest {

    /** The rows a machine nobody has added an account to actually sends: one system profile per
     *  agent, each named after its own key. */
    private fun install(id: String, name: String, provider: String, signIn: SignInWire? = null) =
        AccountWire(id = id, name = name, provider = provider, system = true, signIn = signIn)

    /* ------------------------------------------------------------ the complaint -- */

    @Test
    fun `the three rows he filmed no longer all say default`() {
        // The exact list off a fresh machine, in the exact words the sheet drew them in. None of the
        // three has an address, so all three fall to the third rung — and the third rung has to name
        // the agent, or the fix would be three rows reading "Your own install" instead of three rows
        // reading "Default". Same defect, politer word.
        val rows = listOf(
            install("system", "Default", "claude"),
            install("system:codex", "Default (Codex CLI)", "codex"),
            install("system:gemini", "Default (Gemini CLI)", "gemini"),
        )
        val labels = rows.map { accountLoginLabel(it) }
        assertEquals(
            listOf(
                "Your own Claude Code install",
                "Your own Codex CLI install",
                "Your own Gemini CLI install",
            ),
            labels,
        )
        assertEquals("three accounts, three different captions", 3, labels.toSet().size)
        for (label in labels) {
            assertFalse(
                "the word the chip exists to suppress is back on the chip",
                label.lowercase().contains("default"),
            )
        }
    }

    /* --------------------------------------------------------- rung 1: the address -- */

    @Test
    fun `a signed-in install is named by its address and not by its key`() {
        val row = install(
            "system", "Default", "claude",
            SignInWire(state = "signed-in", account = "app.imatch.ae@gmail.com"),
        )
        assertEquals("app.imatch.ae@gmail.com", accountLoginLabel(row))
    }

    @Test
    fun `an expired claude login does not get to keep its address`() {
        // The trap, and the reason rung 1 is gated on the *state* rather than on the address being
        // present. `claude auth status --json` answers `{"loggedIn": false, "email": "…"}` for an
        // expired login, so the address outlives the session it belonged to. Reading `account` alone
        // would put a stale address on a chip for a session that is signed in as nobody —
        // confidently wrong, which is worse than "Default".
        val expired = install(
            "system", "Default", "claude",
            SignInWire(state = "signed-out", account = "app.imatch.ae@gmail.com"),
        )
        assertEquals("Your own Claude Code install", accountLoginLabel(expired))
        assertNull(namedLogin(expired))

        // A state this build has never heard of is not the signed-in one either. The wire keeps
        // `state` a bare string on purpose; an unknown value falls to a lower rung rather than being
        // read optimistically.
        val future = install(
            "system", "Default", "claude",
            SignInWire(state = "reauthenticating", account = "a@b.com"),
        )
        assertEquals("Your own Claude Code install", accountLoginLabel(future))
    }

    @Test
    fun `a signed-in report with no address is not an address`() {
        // A machine that answers `{"state":"signed-in","account":""}` — or omits the address
        // altogether — has not named anybody. An empty caption on a row that is about to be pressed
        // is worse than a sentence about the install, so both fall through to rung 3.
        assertEquals(
            "Your own Claude Code install",
            accountLoginLabel(install("system", "Default", "claude", SignInWire("signed-in", "   "))),
        )
        assertEquals(
            "Your own Claude Code install",
            accountLoginLabel(install("system", "Default", "claude", SignInWire("signed-in", null))),
        )
    }

    /* ------------------------------------------- rung 2: the name, when a person chose it -- */

    @Test
    fun `an account somebody named keeps its name`() {
        val mine = AccountWire(id = "work", name = "Client work", provider = "claude", color = "--accent")
        assertEquals("Client work", accountLoginLabel(mine))
        assertEquals("Client work", namedLogin(mine))
    }

    @Test
    fun `a generated name is never treated as a name`() {
        // `system` and `system:<agent>` are minted by `profiles.ts` and never by a person, so the
        // name beside them is generated whatever it says.
        assertTrue(isGeneratedAccountId("system"))
        assertTrue(isGeneratedAccountId("system:gemini"))
        assertFalse(isGeneratedAccountId("work"))
        assertFalse(isGeneratedAccountId("systematic"))
    }

    @Test
    fun `an older machine that sends no system flag is still read off the id`() {
        // The `or` in `isGeneratedAccount`, load-bearing on a client shipped against machines older
        // than itself: [AccountWire.system] defaults to `false`, so a desktop whose build predates
        // the field arrives as an explicit `false` — and trusting the flag alone would read that as
        // *"somebody named this account Default (Gemini CLI)"* and print the slug he filmed.
        val old = AccountWire(id = "system:gemini", name = "Default (Gemini CLI)", provider = "gemini")
        assertTrue(isGeneratedAccount(old))
        assertEquals("Your own Gemini CLI install", accountLoginLabel(old))
    }

    /* ------------------------------------------------ rung 3: which install this is -- */

    @Test
    fun `codex falls to the install because its cli names nobody`() {
        // Not a rare case. `codex login status` prints *"Logged in using ChatGPT"* and never an
        // address, by design — so a signed-in Codex row reaches rung 3 every single time. If the
        // fallback were the sign-in state instead, every Codex login in the list would be named
        // after its plan and two of them would be indistinguishable.
        val codex = install("system:codex", "Default (Codex CLI)", "codex", SignInWire("signed-in", null))
        assertEquals("Your own Codex CLI install", accountLoginLabel(codex))
        assertNull(namedLogin(codex))
    }

    @Test
    fun `a list already filtered to one agent may drop the agent's name`() {
        // `namesTheAgent = false` is for a list whose rows all belong to one agent, where the name
        // distinguishes nothing and what is left is a vendor's product name printed in a pop-up:
        //
        //   > *"You should not mention in any settings or any pop-up a specific tool or LLM, because
        //   > they can use some other also."*
        //
        // Nothing on the session bar passes it — that sheet lists every login on the far machine —
        // and this is what keeps the default from quietly flipping under a later edit.
        val row = install("system", "Default", "claude")
        assertEquals("Your own install", accountLoginLabel(row, namesTheAgent = false))
        assertEquals("Your own Claude Code install", accountLoginLabel(row))
    }

    @Test
    fun `an agent this build has never heard of gets a true sentence and not its slug`() {
        // A `custom:` agent somebody added on the far machine. "Your own custom:my-agent install"
        // would be a slug leaking onto a screen, which is the complaint rather than the fix.
        assertEquals(
            "Your own install",
            accountLoginLabel(install("system:custom:my-agent", "Default (my-agent)", "custom:my-agent")),
        )
        // The same for a machine too old to name its agent at all.
        assertEquals(
            "Your own install",
            accountLoginLabel(AccountWire(id = "system", name = "Default", system = true)),
        )
    }

    /* ------------------------------------------------------------------- the wire -- */

    @Test
    fun `the sign-in report is decoded off the account row`() {
        // The half that was missing. `account-serve.ts`'s `toWire` has spread a `signIn` object onto
        // every account row since 2026-08-21; this client decoded id/name/provider/color/system and
        // dropped it, which is why the chip could not have told the truth even if it had wanted to.
        // `plan` and `detail` ride along on the wire and are dropped by `ignoreUnknownKeys` — this
        // bar draws no sentences, so lifting them would only invite one.
        val raw = """
            {"id":"system","name":"Default","provider":"claude","color":"--accent","system":true,
             "signIn":{"state":"signed-in","account":"app.imatch.ae@gmail.com","plan":"max",
                       "detail":"Signed in as app.imatch.ae@gmail.com on the max plan"}}
        """.trimIndent()
        val account = ProtocolJson.decodeFromString(AccountWire.serializer(), raw)
        assertEquals(SignInWire("signed-in", "app.imatch.ae@gmail.com"), account.signIn)
        assertEquals("app.imatch.ae@gmail.com", accountLoginLabel(account))
    }

    @Test
    fun `a machine that said nothing is not a machine that said signed out`() {
        // Absent is a real answer meaning *that machine did not say* — a desktop older than the
        // field, or a probe that threw on the far side. It must not collapse into "signed out": the
        // two have different remedies and only one of them is fixed by logging in again. Here it
        // falls to the rung below, which says something true either way. It must also not take the
        // row down with it: a desktop that sends no `signIn` still decodes.
        val raw = """{"id":"system","name":"Default","provider":"claude","system":true}"""
        val account = ProtocolJson.decodeFromString(AccountWire.serializer(), raw)
        assertNull(account.signIn)
        assertEquals("Your own Claude Code install", accountLoginLabel(account))
    }
}
