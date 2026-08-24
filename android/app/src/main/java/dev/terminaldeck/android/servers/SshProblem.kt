package dev.terminaldeck.android.servers

/**
 * What went wrong reaching a server, as something a person can act on.
 *
 * A port of `ios/TerminalDeck/Servers/SSHSession.swift`'s `SSHProblem`, which is itself a port of
 * the argument in `src/main/servers/connection.ts`: the sentences live where the failure is
 * recognised, once, rather than as ten `catch` blocks each inventing their own wording. Every one
 * of these is a sentence that reaches a screen, so they are here rather than at the call sites.
 *
 * Note what is deliberately *not* claimed — which half of a sign-in was wrong. A server does not
 * tell a client whether the username or the credential was the problem, so neither does this.
 *
 * The wording is iOS's, word for word, wherever the situation is the same. That is not laziness:
 * the two clients talk to the same servers and fail the same ways, and two apps that describe one
 * server's refusal in two different sentences are two apps somebody has to learn separately. Where
 * a sentence differs it is because the platform differs, and it says so where it is written.
 */
sealed interface SshProblem {

    val headline: String
    val advice: String

    /** The name did not resolve. A typo in the address, or a name that only exists elsewhere. */
    data object NoSuchAddress : SshProblem {
        override val headline = "That address could not be found"
        override val advice =
            "Check the address. A name has to resolve from this phone's network, so a name that " +
                "only exists on your office network will not be found from a mobile one."
    }

    /** The socket would not open. Off, firewalled, or the wrong port. */
    data object NoAnswer : SshProblem {
        override val headline = "That address did not answer"
        override val advice =
            "The server may be off, the port may be wrong, or something in between may be " +
                "blocking it. Check the port — SSH is usually 22, and a server set up to use " +
                "another number will not answer on 22 at all."
    }

    /** Something is listening and it is not SSH. */
    data object NotAServer : SshProblem {
        override val headline = "That answered, but not as a server"
        override val advice =
            "Something is listening on that port and it is not SSH. That usually means the port " +
                "belongs to something else — a website, a database — rather than to the server's " +
                "own sign-in."
    }

    /** The server said no to the account with that password or key. */
    data object SignInRefused : SshProblem {
        override val headline = "That sign-in was refused"
        override val advice =
            "The server did not accept that account with that password or key. It will not say " +
                "which of the two it disliked, so check both. A key has to have been added to " +
                "that account on the server before it will be accepted."
    }

    /**
     * The host key is not the one this phone wrote down.
     *
     * Nothing is sent when this happens — the check runs before a credential is offered, which is
     * the whole reason the fingerprint is stored at all.
     */
    data class IdentityChanged(val seen: String, val stored: String) : SshProblem {
        override val headline = "That server is not the one you added"
        override val advice =
            "It answered with $seen. When you added it, it was $stored. That is what a rebuilt " +
                "server looks like, and it is also what an impostor looks like — so nothing was " +
                "sent. Forget this server and add it again only if you know why it changed."
    }

    /** The pasted key cannot be used. Carries the reader's own sentences. */
    data class BadKey(val problem: PrivateKeyProblem) : SshProblem {
        override val headline = problem.headline
        override val advice = problem.advice
    }

    /**
     * No shared algorithms.
     *
     * Rarer here than on iOS and worded for it. NIOSSH does not implement RSA at all, so a server
     * offering only an `ssh-rsa` host key is unreachable from an iPhone; sshj does implement it,
     * so on Android this is a genuinely ancient or deliberately hardened server rather than the
     * everyday case iOS has to explain.
     */
    data object NothingInCommon : SshProblem {
        override val headline = "This phone and that server share no way to talk"
        override val advice =
            "The two ends could not agree on a cipher or a key exchange. That is a server " +
                "configured to allow only algorithms this client does not offer, or one so old " +
                "that nothing current will talk to it."
    }

    /** The connection ended under us. */
    data object Lost : SshProblem {
        override val headline = "The connection to that server ended"
        override val advice = "It closed the connection. Opening the server again reconnects."
    }

    /** It took the connection and then stopped answering. */
    data object TimedOut : SshProblem {
        override val headline = "That server stopped answering"
        override val advice =
            "It accepted the connection and then stopped answering. That is usually a server " +
                "under heavy load or a network that dropped in the middle."
    }

    /** A session channel or a command the server would not run. Carries the detail. */
    data class CommandFailed(override val advice: String) : SshProblem {
        override val headline = "That server refused the command"
    }
}

/** [SshProblem] as something that can be thrown out of a suspend function. */
class SshException(val problem: SshProblem) : Exception(problem.headline)

/** Throwing shorthand, so call sites read as the sentence rather than as the plumbing. */
fun SshProblem.raise(): Nothing = throw SshException(this)
