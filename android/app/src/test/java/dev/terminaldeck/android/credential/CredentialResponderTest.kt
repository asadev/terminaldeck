package dev.terminaldeck.android.credential

import dev.terminaldeck.android.github.GitHubAccount
import dev.terminaldeck.android.github.GitHubAccountStore
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.CredentialDenial
import dev.terminaldeck.android.protocol.CredentialOperation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The policy, as it must behave on every client.
 *
 * These are `ios/Tests/CredentialResponderTests.swift` case for case, and that is the point rather
 * than a shortcut: three clients answer one desktop, and the thing they have to agree about is
 * *when a person is interrupted*. A policy that drifted between two of them would be a feature that
 * behaves differently depending on which phone is in somebody's pocket — and it would drift
 * silently, because both would keep compiling and both would keep connecting.
 *
 * The refusals are tested as hard as the approvals, which is what `CREDENTIAL-PROXY.md` asks for: a
 * denied request, a request with no account behind it, a machine that went away mid-question, and
 * an "always" claimed for a repository that has no name.
 */
class CredentialResponderTest {

    /** An account store whose two halves can be taken away independently. */
    private class FakeAccounts(
        private var login: String? = "asadev",
        private var secret: String? = "gho_secret",
    ) : GitHubAccountStore {
        /** Counted, because a token read while a prompt is on screen would be a token held. */
        var tokenReads = 0
            private set

        override fun account(): GitHubAccount? = login?.let {
            GitHubAccount(login = it, source = GitHubAccount.Source.SignIn, connectedAt = 0)
        }

        override fun token(): String? {
            tokenReads += 1
            return secret
        }

        override fun connect(login: String, token: String, source: GitHubAccount.Source) {
            this.login = login
            this.secret = token
        }

        override fun disconnect() {
            login = null
            secret = null
        }
    }

    /** An expiry nothing fires unless a test says so. */
    private class ManualExpiry : Expiry {
        private val armed = mutableListOf<() -> Unit>()

        override fun after(ms: Long, onExpired: () -> Unit): () -> Unit {
            armed += onExpired
            return { armed.remove(onExpired) }
        }

        /** Everything still armed, in the order it was armed. */
        fun fire() {
            for (expired in armed.toList()) expired()
        }

        val pending: Int get() = armed.size
    }

    private class Harness(accounts: FakeAccounts = FakeAccounts()) {
        val accounts = accounts
        val expiry = ManualExpiry()
        val sent = mutableListOf<Pair<String, ClientMessage>>()
        var changes = 0
            private set
        val responder = CredentialResponder(accounts, expiry, onChange = { changes += 1 }).also {
            it.route = { machineId, message -> sentAdd(machineId, message) }
        }

        private fun sentAdd(machineId: String, message: ClientMessage) {
            sent += machineId to message
        }

        fun ask(
            id: String = "r1",
            machineId: String = "m1",
            machineName: String = "Studio",
            repo: String? = "asadev/terminaldeck",
            operation: CredentialOperation = CredentialOperation.Write,
            prompt: Boolean = true,
        ) = responder.receive(
            CredentialQuestion(
                id = id,
                machineId = machineId,
                machineName = machineName,
                origin = "github.com",
                repo = repo,
                operation = operation,
                prompt = prompt,
            )
        )

        fun messages(): List<ClientMessage> = sent.map { it.second }
    }

    /* ---------------------------------------------------------------- silence -- */

    @Test
    fun `a read is answered without a prompt`() {
        val deck = Harness()
        deck.ask(operation = CredentialOperation.Read, prompt = false)

        assertNull("a read must never raise a question", deck.responder.asking)
        assertEquals(
            listOf<ClientMessage>(
                ClientMessage.CredentialAck("r1"),
                ClientMessage.CredentialAnswer("r1", "asadev", "gho_secret", remember = false),
            ),
            deck.messages(),
        )
    }

    @Test
    fun `an approved push is silent because the desktop said so`() {
        // `prompt` false against a write is the desktop saying this device has already approved this
        // repository *there*. Second-guessing it here would be a second source of truth.
        val deck = Harness()
        deck.ask(operation = CredentialOperation.Write, prompt = false)

        assertNull(deck.responder.asking)
        assertTrue(deck.messages()[1] is ClientMessage.CredentialAnswer)
    }

    /* -------------------------------------------------------------------- ack -- */

    @Test
    fun `every request is acknowledged first, even one about to be refused`() {
        // The frame the whole failure mode rests on: without it the desktop cannot tell a phone
        // that is asleep from a person who is thinking, and a push stalls for thirty seconds with
        // nothing on screen.
        val deck = Harness(FakeAccounts(login = null, secret = null))
        deck.ask()

        assertEquals(ClientMessage.CredentialAck("r1"), deck.messages().first())
    }

    @Test
    fun `no account is not a refusal`() {
        val deck = Harness(FakeAccounts(login = null, secret = null))
        deck.ask()

        assertNull("nobody can be asked to approve with no account to approve with", deck.responder.asking)
        assertEquals(
            ClientMessage.CredentialDeny("r1", CredentialDenial.NoAccount),
            deck.messages()[1],
        )
    }

    /* ------------------------------------------------------------- the prompt -- */

    @Test
    fun `a push raises the question and answers nothing until it is answered`() {
        val deck = Harness()
        deck.ask()

        assertEquals("r1", deck.responder.asking?.id)
        assertEquals("Studio", deck.responder.asking?.machineName)
        assertEquals(listOf<ClientMessage>(ClientMessage.CredentialAck("r1")), deck.messages())
    }

    @Test
    fun `the token is not touched while the question is on screen`() {
        // A person may take a minute to decide, and for that minute the bytes must not be in this
        // process. The store is read at the moment a reply is built and never before.
        val deck = Harness()
        deck.ask()

        assertEquals(0, deck.accounts.tokenReads)
        deck.responder.approve(remember = false)
        assertEquals(1, deck.accounts.tokenReads)
    }

    @Test
    fun `always sends the scope and plain approve does not`() {
        val once = Harness()
        once.ask()
        once.responder.approve(remember = false)
        assertEquals(
            ClientMessage.CredentialAnswer("r1", "asadev", "gho_secret", remember = false),
            once.messages()[1],
        )

        val always = Harness()
        always.ask()
        always.responder.approve(remember = true)
        assertEquals(
            ClientMessage.CredentialAnswer("r1", "asadev", "gho_secret", remember = true),
            always.messages()[1],
        )
    }

    @Test
    fun `always is not claimed for a repository with no name`() {
        // The desktop refuses to record an approval it cannot key, so sending one would be this
        // phone claiming a consent that nothing acts on.
        val deck = Harness()
        deck.ask(repo = null)
        deck.responder.approve(remember = true)

        val answer = deck.messages()[1] as ClientMessage.CredentialAnswer
        assertTrue("remember must be dropped when there is no repo", !answer.remember)
    }

    @Test
    fun `deny refuses and clears the screen`() {
        val deck = Harness()
        deck.ask()
        deck.responder.deny()

        assertNull(deck.responder.asking)
        assertEquals(ClientMessage.CredentialDeny("r1", CredentialDenial.Denied), deck.messages()[1])
    }

    @Test
    fun `approving with the account gone refuses rather than pretending`() {
        val deck = Harness()
        deck.ask()
        deck.accounts.disconnect()
        deck.responder.approve(remember = false)

        // Not a silent failure and not a fake success: the button did not fail, there is simply no
        // account any more, and that is a different sentence on the desktop.
        assertEquals(
            ClientMessage.CredentialDeny("r1", CredentialDenial.NoAccount),
            deck.messages()[1],
        )
    }

    /* --------------------------------------------------------------- the queue -- */

    @Test
    fun `a second question waits and arrives when the first is answered`() {
        val deck = Harness()
        deck.ask(id = "r1")
        deck.ask(id = "r2")

        assertEquals("r1", deck.responder.asking?.id)
        assertEquals(1, deck.responder.queued)
        // Both were acknowledged straight away — the second one is waiting on a person, not on the
        // desktop's reachability deadline.
        assertEquals(
            listOf<ClientMessage>(ClientMessage.CredentialAck("r1"), ClientMessage.CredentialAck("r2")),
            deck.messages(),
        )

        deck.responder.approve(remember = false)
        assertEquals("r2", deck.responder.asking?.id)
        assertEquals(0, deck.responder.queued)
    }

    @Test
    fun `too many questions are refused rather than accumulated`() {
        val deck = Harness()
        for (i in 1..CredentialResponder.MAX_PENDING + 4) deck.ask(id = "r$i")

        val denials = deck.messages().filterIsInstance<ClientMessage.CredentialDeny>()
        assertTrue("a machine that stops behaving must not fill this phone", denials.isNotEmpty())
        assertTrue(denials.all { it.reason == CredentialDenial.Denied })
        assertTrue(deck.responder.queued < CredentialResponder.MAX_PENDING)
    }

    /* ------------------------------------------------------------- the machines -- */

    @Test
    fun `an answer is routed back to the machine that asked`() {
        val deck = Harness()
        deck.ask(id = "r1", machineId = "studio")
        deck.responder.approve(remember = false)

        assertTrue(deck.sent.all { it.first == "studio" })
    }

    @Test
    fun `a question from a machine that went away is taken off the screen`() {
        // The reply has nowhere to go, so the buttons would answer nothing — and a control that
        // looks pressable and does nothing is the one rule the design brief puts first.
        val deck = Harness()
        deck.ask(id = "r1", machineId = "studio")
        deck.responder.machineLost("studio")

        assertNull(deck.responder.asking)
        // No refusal sent: nobody refused, and the socket it would go on has gone.
        assertEquals(listOf<ClientMessage>(ClientMessage.CredentialAck("r1")), deck.messages())
    }

    @Test
    fun `losing a machine drops its waiting questions too`() {
        val deck = Harness()
        deck.ask(id = "r1", machineId = "studio")
        deck.ask(id = "r2", machineId = "laptop")
        deck.ask(id = "r3", machineId = "studio")

        deck.responder.machineLost("studio")

        assertEquals("laptop's question is the one left standing", "r2", deck.responder.asking?.id)
        assertEquals(0, deck.responder.queued)
    }

    @Test
    fun `losing a machine that asked nothing leaves the screen alone`() {
        val deck = Harness()
        deck.ask(id = "r1", machineId = "studio")
        deck.responder.machineLost("laptop")

        assertEquals("r1", deck.responder.asking?.id)
    }

    /* -------------------------------------------------------------- the clock -- */

    @Test
    fun `a question nobody answered comes off the screen with no reply`() {
        // Past the decide window the desktop has already told the person at the keyboard that
        // nobody answered, so an answer arriving now is dropped over there. Sending a refusal would
        // be reporting a decision nobody made.
        val deck = Harness()
        deck.ask()
        deck.expiry.fire()

        assertNull(deck.responder.asking)
        assertEquals(listOf<ClientMessage>(ClientMessage.CredentialAck("r1")), deck.messages())
    }

    @Test
    fun `an expiry armed for one question cannot take a later one off the screen`() {
        val deck = Harness()
        deck.ask(id = "r1")
        deck.ask(id = "r2")
        deck.responder.approve(remember = false)

        assertEquals("r2", deck.responder.asking?.id)
        // The first question's timer was cancelled when it left the screen, so exactly one is armed
        // and firing everything armed can only affect r2.
        assertEquals(1, deck.expiry.pending)
        deck.expiry.fire()
        assertNull(deck.responder.asking)
    }

    /* ------------------------------------------------------------------ nothing -- */

    @Test
    fun `pressing a button with nothing asked sends nothing`() {
        val deck = Harness()
        deck.responder.approve(remember = true)
        deck.responder.deny()

        assertTrue(deck.messages().isEmpty())
    }

    @Test
    fun `reset clears everything without answering anything`() {
        val deck = Harness()
        deck.ask(id = "r1")
        deck.ask(id = "r2")
        deck.responder.reset()

        assertNull(deck.responder.asking)
        assertEquals(0, deck.responder.queued)
        assertEquals(2, deck.messages().size)
        assertTrue(deck.messages().all { it is ClientMessage.CredentialAck })
    }

    @Test
    fun `the screen is told when a question arrives and when it goes`() {
        // The view model refolds its whole state off this, so a question that changed nothing
        // observable would be a prompt that never appeared.
        val deck = Harness()
        val before = deck.changes
        deck.ask()
        assertTrue(deck.changes > before)
        assertNotNull(deck.responder.asking)
    }
}
