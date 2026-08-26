package dev.terminaldeck.android.protocol

/**
 * What one login is *called* on this phone. One rule, written once, for every screen that has to
 * name an account.
 *
 * ## The complaint this file is the whole of
 *
 * Asad, 2026-08-26, on a screen recording: he opens a session, presses the account chip on the bar
 * over the terminal, and the sheet that comes up reads
 *
 *     Default
 *     Default (Codex CLI)
 *     Default (Gemini CLI)
 *
 *   > *"when we click on this link it should clearly mention the name of the account here instead of
 *   > saying default — name of the account should be there."*
 *
 * "Default" is not a name anybody gave a login. It is the key `systemProfileId` in
 * `src/main/profiles.ts` mints for the machine's own install — `system`, `system:codex`,
 * `system:gemini` — and it is a statement about *precedence*, not about whose account it is. It is
 * the internal slug of the one control whose entire job is saying which login a session runs as.
 *
 * He has said the same thing before, on the desktop, about the same slug on the same kind of chip —
 * 2026-08-21, with the terminal three lines below the chip reading *"Welcome back Sherzod
 * Davlatov"*:
 *
 *   > *"It is saying default, so never default. Whatever is actual account should be visible here,
 *   > never default."*
 *
 * ## This is a transcription, not a second rule
 *
 * `profileLoginLabel` and `namedLogin` in `src/renderer/accounts.ts` already decide this on the
 * desktop, and `ios/TerminalDeck/Protocol/AccountNaming.swift` is the same three rungs on the other
 * phone. This is that, in Kotlin, because the far machine sends all three clients the same facts and
 * the one thing that must never happen is two of them naming one login two different ways. Grep
 * either desktop name to find the original; the reasoning is restated rather than referenced,
 * because a rule whose *why* lives in another language in another folder is a rule the next person
 * quietly re-invents.
 *
 * The three rungs, in order:
 *
 *  1. the address the agent's own CLI named — but only when the sign-in state says it is genuinely
 *     signed in;
 *  2. failing that, the name, but only when a *person* chose it, because a generated key is not a
 *     name;
 *  3. failing that, which install it is — *"Your own Claude Code install"*.
 */

/**
 * The address the agent's own CLI named, or null — rung 1, and the trap.
 *
 * **Gated on the state, not on the address being present.** `claude auth status --json` answers
 * `{"loggedIn": false, "email": "…"}` for an *expired* login, so the address outlives the session it
 * belonged to. Reading `account` alone would put a stale address on the chip of a session that is
 * signed in as nobody — worse than "Default", because it is confidently wrong rather than merely
 * useless.
 *
 * This is the one rung of the three that must never be copied out of here. The desktop carries the
 * same warning over its own `accountLabel` for the same reason: it was written after the bug.
 */
fun accountAddress(signIn: SignInWire?): String? {
    if (signIn == null || signIn.state != SignInWire.SIGNED_IN) return null
    return signIn.account?.trim()?.ifEmpty { null }
}

/**
 * Whether an id names an agent's own install rather than an account somebody made.
 *
 * The ids come from `systemProfileId` in `src/main/profiles.ts`: `system` for Claude,
 * `system:<agent>` for the rest. It matters because those two kinds of account have names of two
 * different kinds — one is a word a person typed, the other is generated — and only the first is an
 * identity.
 *
 * Looser than the main process's own test, which checks the suffix against the agents it knows, and
 * that is the right direction to be loose in: an id shaped like a system one that the far machine
 * does not recognise resolves to no account there at all, so treating it as generated here costs
 * nothing, whereas treating a generated name as an identity is the whole bug.
 */
fun isGeneratedAccountId(id: String): Boolean = id == "system" || id.startsWith("system:")

/**
 * Whether this account's name was generated rather than chosen.
 *
 * The flag **or** the shape of the id, and the `or` is load-bearing on a client shipped against
 * machines older than itself. [AccountWire.system] defaults to `false`, so a desktop whose build
 * predates the field arrives here as an explicit `false` — and trusting the flag alone would read
 * that as *"somebody named this account Default (Gemini CLI)"* and print the slug he filmed. The id
 * cannot be wrong the other way: `profiles.ts` mints `system` and `system:<agent>` for the installs
 * and never for an account anybody added.
 */
fun isGeneratedAccount(account: AccountWire): Boolean =
    account.system || isGeneratedAccountId(account.id)

/**
 * The login itself, when there is one to name, and null when there is not.
 *
 * The top two rungs of [accountLoginLabel] with the fallback removed, so a caller can ask *"did
 * anybody actually name this login?"* and get an answer rather than a sentence about an install.
 *
 * Null is a real and common answer, and it is not a failure: an install nobody has signed into has
 * no login to name, and Codex's CLI never prints an address at all. A caller that gets null must say
 * nothing rather than invent a substitute — the substitute is always the slug.
 */
fun namedLogin(account: AccountWire): String? {
    accountAddress(account.signIn)?.let { return it }
    if (!isGeneratedAccount(account)) return account.name
    return null
}

/**
 * What one login is called in a list you choose it from — the whole rule.
 *
 * Three rungs, and every one of them is a real case measured on a real machine:
 *
 *  1. **The address the agent's own CLI named.** An email is the only label that tells two accounts
 *     apart with certainty; a name is whatever somebody typed and two people do call both of theirs
 *     "Work". Gated on the sign-in state — see [accountAddress], which holds the trap.
 *  2. **The name, when a person chose it.** A profile somebody added and called "Client work" is
 *     called "Client work", signed in or not.
 *  3. **Which install this is.** *"Your own Claude Code install."*
 *
 * ## Why rung 3 is a sentence about the install rather than the sign-in state
 *
 * Because a state is not an identity. A chip describing exactly one account can fall back to "Not
 * signed in" or "Signed in · max" and still be saying something useful. A *list* cannot: two rows
 * share a state constantly, and a sheet whose rows read "Signed in · max" and "Signed in · max" has
 * stopped being a picker. It is not a rare case either — Codex's CLI never prints an address, by
 * design, so the state rung would be the *only* one a Codex login ever reached and every Codex row
 * would be named after its plan. Which install it is holds in all of those cases, is known without
 * asking anybody, and does not change under a finger when a probe lands.
 *
 * ## Why rung 3 names the agent, and when it may be asked not to
 *
 * It names the agent by default because on this screen the agent's name is the only thing separating
 * those rows. A fresh machine has one system account per agent, so the sheet holds three of them,
 * none has an address, and without the agent's name all three read "Your own install" — the same
 * caption on three rows that are not the same account, which is precisely the failure he filmed with
 * a different word in it.
 *
 * [namesTheAgent] `= false` turns "Your own Claude Code install" into "Your own install", and it
 * exists for exactly one shape of list: one whose rows have *already* been filtered to a single
 * agent. There the name distinguishes nothing and what is left is a vendor's product name printed in
 * a pop-up, which is a thing he has asked against by name:
 *
 *   > *"You should not mention in any settings or any pop-up a specific tool or LLM, because they
 *   > can use some other also."*
 *
 * Nothing on this bar passes it today — the sheet lists every login on the far machine, across every
 * agent. It is here so that the screen that eventually does filter has somewhere to say so, instead
 * of growing a fourth copy of the rule with one rung changed.
 *
 * ## An agent this build has never heard of
 *
 * Gets "Your own install" rather than its slug. [ServerSettingsLabels.known] answers null for a
 * `custom:` agent somebody added on the far machine, and a true short sentence beats *"Your own
 * custom:my-agent install"* — the same direction the codec errs in when it meets a provider it does
 * not know, which is to keep the row rather than drop it.
 */
fun accountLoginLabel(account: AccountWire, namesTheAgent: Boolean = true): String {
    namedLogin(account)?.let { return it }
    val agent = if (namesTheAgent) account.provider?.let { ServerSettingsLabels.known(it) } else null
    return if (agent == null) "Your own install" else "Your own $agent install"
}
