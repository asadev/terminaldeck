package dev.terminaldeck.android.credential

import dev.terminaldeck.android.github.GitHubAccount
import dev.terminaldeck.android.github.GitHubAccountStore
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.CredentialDenial
import dev.terminaldeck.android.protocol.CredentialOperation
import dev.terminaldeck.android.protocol.Protocol
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The half of the credential proxy that lives on the phone: what happens when a machine asks this
 * device for a GitHub login.
 *
 * The desktop half is built and shipping — `src/main/remote/credentials.ts` — and the iOS client
 * answers it. Until this existed, an Android phone was a device that advertised nothing and
 * therefore was never asked: git on the machine somebody had been granted a folder on would refuse
 * the push in milliseconds with "your device isn't reachable", about a phone that was sitting
 * there, connected.
 *
 * ## The policy, which is four lines and is the whole feature
 *
 *  - **Reads are silent.** fetch, pull, clone. Asking buys nothing: they are reversible, they
 *    happen constantly, and a person tapping Approve forty times a day stops reading what they are
 *    approving.
 *  - **Writes are asked about, once per repository.** A push is the irreversible one and the one
 *    where somebody should get to see whose name goes on the commit.
 *  - **Whether to ask is the desktop's answer, not this one's.** It arrives as `prompt` on the
 *    frame. The desktop is the side that knows which repositories this device has already approved
 *    *on that machine*, so it is the side that decides — and a phone that second-guessed it would
 *    be a second source of truth with no way to reconcile the two.
 *  - **No account is not a refusal.** It is a different thing to be told and has a different fix,
 *    so it gets its own code and the desktop writes a sentence that points at this phone rather
 *    than at the person who pushed.
 *
 * This is the same policy as `ios/TerminalDeck/App/CredentialResponder.swift`, deliberately to the
 * letter and not to the line: three clients answering one desktop have to agree about *when a
 * person is interrupted*, and a policy that drifted between two of them would be a feature that
 * behaves differently depending on which phone is in the pocket.
 *
 * ## Every request is acknowledged first, including the ones about to be refused
 *
 * The desktop gives a device four seconds to say it is there and only then starts the sixty seconds
 * a person gets to decide. That split is the difference between "your device isn't reachable — open
 * the app to approve this push", arriving in seconds, and a thirty-second stall on a `git push`
 * with nothing on screen, which is how people stop trusting a feature. So the acknowledgement goes
 * out before anything else is worked out, on every path — before the account is looked at, before
 * the queue is looked at, before anything is drawn.
 *
 * ## What this object never does
 *
 * It never logs a token, never puts one in an error, and never holds one between requests: the
 * bytes are read out of the Keystore-wrapped store at the moment a reply is built and go into that
 * reply and nowhere else. It also keeps no record of what has been approved — that memory belongs
 * to the desktop, in its own process, for as long as its app is running.
 */

/**
 * One question, as a phone needs to render it.
 *
 * [origin] rather than `host` for what the wire calls `host`, because on this side of the
 * connection "host" already means *the machine this phone is paired with* — and the two are on the
 * same screen at the same time. This one is `github.com`; the machine is [machineName].
 */
data class CredentialQuestion(
    /** The desktop's id for this question. Every reply carries it back. */
    val id: String,
    /**
     * Which paired machine asked.
     *
     * Replies are routed by it, and getting it wrong would answer one machine's question on
     * another's socket. Routing by **id** rather than by holding the link is deliberate: a machine
     * can be forgotten while its question is on screen, and answering through an object that has
     * been torn down would be answering nobody, quietly.
     */
    val machineId: String,
    /**
     * What the user calls that machine.
     *
     * The third line of the prompt, and the one the design brief says the whole feature rests on:
     * *which machine asked*. "Approve a push" is not answerable. "Approve a push from Work PC" is.
     */
    val machineName: String,
    /** The git host — `github.com`, or an enterprise one. */
    val origin: String,
    /**
     * `owner/name`, or null when the desktop could not derive one.
     *
     * Null is shown as null. The one screen in this feature that exists to tell the truth about
     * what is being approved must not be capable of naming the wrong thing.
     */
    val repo: String?,
    val operation: CredentialOperation,
    /** Whether a person is being asked. The desktop's answer, carried through. */
    val prompt: Boolean,
)

/**
 * How a delayed thing is scheduled, so the decide window can be tested by moving a hand rather than
 * by waiting a minute.
 *
 * Returns the function that cancels it. That is what removes the need for iOS's generation counter:
 * a question leaving the screen cancels its own timer, so a timer armed for one question cannot
 * take a later one off the screen because it is no longer running.
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

class CredentialResponder(
    private val accounts: GitHubAccountStore,
    private val expiry: Expiry,
    /** Bumped whenever what is on screen changes, so the view model can refold its state. */
    private val onChange: () -> Unit = {},
) {

    /** The question on screen, or null. The prompt sheet is drawn off this. */
    var asking: CredentialQuestion? = null
        private set

    /**
     * Questions behind it, oldest first.
     *
     * A person pushing two repositories at once is a real thing; two prompts stacked on top of each
     * other is not.
     */
    private val waiting = ArrayDeque<CredentialQuestion>()

    /** How many are behind the one on screen. Drawn on the prompt so nobody is surprised by a second. */
    val queued: Int get() = waiting.size

    /**
     * How a reply reaches the machine that asked, by host id.
     *
     * Set by the view model immediately after construction. The two objects are mutually recursive
     * — the model routes questions in and answers back out — and a lambda handed over afterwards is
     * how that knot is tied without either holding the other in its constructor.
     */
    var route: ((String, ClientMessage) -> Unit)? = null

    private var cancelExpiry: (() -> Unit)? = null

    /**
     * The account the prompt names. The non-secret half — nothing on screen ever holds the token.
     */
    fun account(): GitHubAccount? = accounts.account()

    /* ------------------------------------------------------------------ inbound -- */

    fun receive(question: CredentialQuestion) {
        // Before anything is decided, and before the token store is touched. See the header: this
        // is the frame the whole feature's failure mode rests on, and every path owes it.
        deliver(question.machineId, ClientMessage.CredentialAck(question.id))

        if (accounts.account() == null) {
            refuse(question, CredentialDenial.NoAccount)
            return
        }

        if (!question.prompt) {
            // A read, or a write against a repository already approved on that machine. Nobody is
            // interrupted, and the token is read here and used once.
            answerNow(question, remember = false)
            return
        }

        if (asking == null && waiting.isEmpty()) {
            present(question)
            return
        }
        if (waiting.size + 1 >= MAX_PENDING) {
            // Unreachable through a desktop that behaves: it refuses more than four in flight per
            // device and sixteen in total. It exists so a machine that has *stopped* behaving
            // cannot make this phone accumulate questions without limit, and the refusal is
            // immediate rather than silent.
            refuse(question, CredentialDenial.Denied)
            return
        }
        waiting.addLast(question)
        onChange()
    }

    /**
     * A machine's socket went down.
     *
     * Anything it asked is unanswerable now — the reply has nowhere to go — so the question comes
     * off the screen rather than staying up as three buttons that do nothing. The design brief's
     * first rule is that anything that looks pressable does something.
     */
    fun machineLost(machineId: String) {
        val hadWaiting = waiting.removeAll { it.machineId == machineId }
        if (asking?.machineId != machineId) {
            if (hadWaiting) onChange()
            return
        }
        clearAsking()
        advance()
    }

    /** Every machine, on the way out of the app. */
    fun reset() {
        clearAsking()
        waiting.clear()
        onChange()
    }

    /* --------------------------------------------------- the two buttons and the third -- */

    /**
     * Yes.
     *
     * [remember] is the "Always for this repo" button, and it is a **scope** rather than a stored
     * secret: it tells that machine it may stop asking about that repository from this device.
     * Every push still comes back here for the credential itself.
     *
     * It is dropped when the desktop could not name the repository. The desktop refuses to record
     * an approval it cannot key, so sending it would be this phone claiming a consent that nothing
     * acts on — and the prompt hides the button in that case for the same reason.
     */
    fun approve(remember: Boolean) {
        val question = asking ?: return
        clearAsking()
        answerNow(question, remember = remember && question.repo != null)
        advance()
    }

    fun deny() {
        val question = asking ?: return
        clearAsking()
        deliver(question.machineId, ClientMessage.CredentialDeny(question.id, CredentialDenial.Denied))
        advance()
    }

    /* ----------------------------------------------------------------- plumbing -- */

    /**
     * Read the token and spend it on one request.
     *
     * The store is read *here* rather than when the question arrived, which matters for a prompted
     * one: a person may take a minute to decide, and for that minute the bytes are not in this
     * process. It also means an account disconnected while the prompt was up is answered honestly —
     * the button did not fail, there is simply no account any more.
     */
    private fun answerNow(question: CredentialQuestion, remember: Boolean) {
        val account = accounts.account()
        val token = accounts.token()
        if (account == null || token == null) {
            refuse(question, CredentialDenial.NoAccount)
            return
        }
        if (account.login.length > Protocol.MAX_CREDENTIAL_USERNAME_LENGTH ||
            token.length > Protocol.MAX_CREDENTIAL_SECRET_LENGTH
        ) {
            // Longer than the desktop's parser accepts, and a refused frame closes the socket — so
            // this costs one push rather than the connection. Unreachable with anything GitHub
            // issues today; kept because "unreachable" is a claim about this week's token formats.
            refuse(question, CredentialDenial.NoAccount)
            return
        }
        deliver(
            question.machineId,
            ClientMessage.CredentialAnswer(
                id = question.id,
                username = account.login,
                password = token,
                remember = remember,
            ),
        )
    }

    private fun refuse(question: CredentialQuestion, reason: CredentialDenial) {
        deliver(question.machineId, ClientMessage.CredentialDeny(question.id, reason))
    }

    private fun deliver(machineId: String, message: ClientMessage) {
        route?.invoke(machineId, message)
    }

    private fun present(question: CredentialQuestion) {
        asking = question
        cancelExpiry = expiry.after(DECIDE_TIMEOUT_MS) {
            if (asking?.id != question.id) return@after
            /*
             * Taken off the screen with no reply sent.
             *
             * The desktop settled this question a moment ago and has already printed "nobody
             * answered on your device" in the terminal that was waiting; an answer arriving now is
             * dropped over there. So the honest local act is to stop showing a question that has no
             * answer, rather than to send a refusal for something nobody refused.
             */
            clearAsking()
            advance()
        }
        onChange()
    }

    private fun clearAsking() {
        cancelExpiry?.invoke()
        cancelExpiry = null
        asking = null
    }

    private fun advance() {
        val next = waiting.removeFirstOrNull()
        if (next == null) {
            onChange()
            return
        }
        present(next)
    }

    companion object {
        /**
         * How long a question stays on screen, in milliseconds.
         *
         * The desktop's own `DECIDE_TIMEOUT_MS`. Kept in step deliberately: past it the desktop has
         * already told the person at the keyboard that nobody answered, so the buttons here answer
         * nothing.
         *
         * It is measured from arrival on this side, which is a fraction *earlier* than the
         * desktop's — it arms its clock when the acknowledgement gets back — and that is the right
         * direction to be wrong in.
         */
        const val DECIDE_TIMEOUT_MS = 60_000L

        /**
         * How many unanswered questions this phone will hold.
         *
         * The desktop's `MAX_PENDING`, and unreachable through one that behaves. See [receive].
         */
        const val MAX_PENDING = 16
    }
}
