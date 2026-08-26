/**
 * What one login is *called* on this phone. One rule, written once, for every
 * screen that has to name an account.
 *
 * ## The complaint this file is the whole of
 *
 * Asad, 2026-08-26, on a screen recording: he opens a session, presses the
 * account chip on the bar over the terminal, and the sheet that comes up reads
 *
 *     Default
 *     Default (Codex CLI)
 *     Default (Gemini CLI)
 *
 *   > *"when we click on this link it should clearly mention the name of the
 *   > account here instead of saying default — name of the account should be
 *   > there."*
 *
 * "Default" is not a name anybody gave a login. It is the key `systemProfileId`
 * in `src/main/profiles.ts` mints for the machine's own install — `system`,
 * `system:codex`, `system:gemini`, which the desktop renders as "Default",
 * "Default (Codex CLI)", "Default (Gemini CLI)" — and it is a statement about
 * *precedence*, not about whose account it is. It is the internal slug of the
 * one control whose entire job is saying which login a session is running as.
 *
 * He has said the same thing before, on the desktop, about the same slug on the
 * same kind of chip — 2026-08-21, with the terminal three lines below the chip
 * reading *"Welcome back Sherzod Davlatov"*:
 *
 *   > *"It is saying default, so never default. Whatever is actual account
 *   > should be visible here, never default."*
 *
 * ## This is a port, not a second rule
 *
 * `profileLoginLabel` and `namedLogin` in `src/renderer/accounts.ts` already
 * decide this on the desktop, and the argument for each rung is written out
 * there. This file is those two functions in Swift, because the far machine
 * sends the same facts to both and the one thing that must never happen is the
 * phone and the Mac naming one login two different ways. Grep either desktop
 * name to find the original; the reasoning below is deliberately restated
 * rather than referenced, because a rule whose *why* lives in another language
 * in another folder is a rule the next person quietly re-invents.
 *
 * The three rungs, in order:
 *
 *  1. the address the agent's own CLI named — but only when the sign-in state
 *     says it is genuinely signed in;
 *  2. failing that, the name, but only when a *person* chose it, because a
 *     generated key is not a name;
 *  3. failing that, which install it is — *"Your own Claude Code install"*.
 *
 * ## Why it lives beside the wire and not in the view
 *
 * Because three things read it already — the chip on the bar, the row in the
 * sheet, and the VoiceOver label under both — and the next screen that lists
 * logins will be the fourth. Three copies of a naming rule is three chances for
 * one of them to keep printing "Default" after the other two were fixed, which
 * is the exact shape of the defect he filmed: the desktop's chip had been
 * taught this and the desktop's pickers had not, so the word the chip existed
 * to suppress was still printed one line below the answer.
 */

import Foundation

/**
 * What the far machine's own CLI said about one login.
 *
 * Two fields of the four `SignInWire` carries in `src/main/remote/protocol.ts`,
 * and the pair is not an accident: it is exactly the desktop's own `SignInFacts`
 * — *"the two fields an address is decided from, and nothing else"*. `plan` and
 * `detail` are read off the wire by the desktop because the desktop draws a
 * state line and a tooltip. This bar draws neither, and drawing neither is a
 * rule rather than an omission — `SessionBarView`'s header states it: *"There is
 * no label beside a figure, no 'not reported', no reason for an absence, no
 * caption under the row."* A field lifted here that nothing draws is a field
 * that will eventually be drawn.
 *
 * `command` is not here for the reason it is not on the wire either: it is a
 * command line for a shell on the *far* machine, so it could only ever be
 * offered to somebody who cannot run it.
 *
 * ## Why `state` is a bare string
 *
 * Because the wire's is. `SignInWire.state` is deliberately not a union on the
 * far side — this app is shipped against desktops that may have grown a state it
 * has never heard of — and the only question ever asked of it is *"is this the
 * signed-in one?"*. An unrecognised state answers no, which is the conservative
 * answer and the one that costs nothing: the row falls to a lower rung and says
 * something true about the install instead of claiming an address.
 */
struct WireSignIn: Equatable, Hashable {
    /// The far machine's own word: `signed-in`, `signed-out`, `unknown`,
    /// `unsupported` — or something this build has never seen.
    let state: String
    /// The address the CLI named, when it named one. Null is common and honest:
    /// `codex login status` prints *"Logged in using ChatGPT"* and never an
    /// address, by design.
    let account: String?

    /// The one state that lets rung 1 speak.
    static let signedIn = "signed-in"
}

/**
 * The address the agent's own CLI named, or nil — rung 1, and the trap.
 *
 * **Gated on the state, not on the address being present.** `claude auth status
 * --json` answers `{"loggedIn": false, "email": "…"}` for an *expired* login, so
 * the address outlives the session it belonged to. Reading `account` alone would
 * put a stale address on the chip of a session that is not signed in as anybody
 * — worse than "Default", because it is confidently wrong rather than merely
 * useless.
 *
 * This is the one rung of the three that must never be copied out of here. The
 * desktop carries the same warning over its own `accountLabel` for the same
 * reason: it was written after the bug.
 */
func accountAddress(_ signIn: WireSignIn?) -> String? {
    guard let signIn, signIn.state == WireSignIn.signedIn else { return nil }
    // Trimmed here as well as in `WireCodec.signIn`, which is not redundant: the
    // decoder cleans what comes off a socket, and this keeps the rule total over
    // a value composed by hand — a fixture, a test, the next screen that builds
    // a row from something other than a frame. `{"state":"signed-in",
    // "account":"  "}` is a machine that has not named anybody, and an empty
    // caption on a row about to be pressed is worse than a sentence about the
    // install.
    guard let account = signIn.account?.trimmingCharacters(in: .whitespaces),
          !account.isEmpty else { return nil }
    return account
}

/**
 * Whether an id names an agent's own install rather than an account somebody
 * made.
 *
 * The ids come from `systemProfileId` in `src/main/profiles.ts`: `system` for
 * Claude, `system:<agent>` for the rest. It matters because those two kinds of
 * account have names of two different kinds — one is a word a person typed and
 * the other is generated — and only the first is an identity.
 *
 * Looser than the main process's own test, which checks the suffix against the
 * agents it knows, and that is the right direction to be loose in: an id shaped
 * like a system one that the far machine does not recognise resolves to no
 * account there at all, so treating it as generated here costs nothing, whereas
 * treating a generated name as an identity is the whole bug.
 */
func isGeneratedAccountId(_ id: String) -> Bool {
    id == "system" || id.hasPrefix("system:")
}

/**
 * Whether this account's name was generated rather than chosen.
 *
 * The flag **or** the shape of the id, and the `or` is load-bearing on this
 * client more than on any other. `WireCodec.account` decodes `system` as
 * `row["system"] as? Bool == true`, so a machine whose build predates the field
 * — and this app is shipped against machines older than itself, which is the
 * premise of every other decision in `WireCodec` — arrives here as an explicit
 * `false`. Trusting the flag alone would read that as *"somebody named this
 * account Default (Gemini CLI)"* and print the slug he filmed. The id cannot be
 * wrong the other way: `profiles.ts` mints `system` and `system:<agent>` for the
 * installs and never for an account anybody added.
 */
func isGeneratedAccount(_ account: WireAccount) -> Bool {
    account.system || isGeneratedAccountId(account.id)
}

/**
 * The login itself, when there is one to name, and nil when there is not.
 *
 * The top two rungs of {@link accountLoginLabel} with the fallback removed, so a
 * caller can ask *"did anybody actually name this login?"* and get an answer
 * rather than a sentence about an install. A port of `namedLogin` in
 * `src/renderer/accounts.ts`.
 *
 * Nil is a real and common answer, and it is not a failure: an install nobody
 * has signed into has no login to name, and Codex's CLI never prints an address
 * at all. A caller that gets nil must say nothing rather than invent a
 * substitute — the substitute is always the slug.
 */
func namedLogin(_ account: WireAccount) -> String? {
    if let address = accountAddress(account.signIn) { return address }
    if !isGeneratedAccount(account) { return account.name }
    return nil
}

/**
 * What one login is called in a list you choose it from — the whole rule.
 *
 * A port of `profileLoginLabel` in `src/renderer/accounts.ts`. Three rungs, and
 * every one of them is a real case measured on a real machine:
 *
 *  1. **The address the agent's own CLI named.** An email is the only label that
 *     tells two accounts apart with certainty; a name is whatever somebody typed
 *     and two people do call both of theirs "Work". Gated on the sign-in state —
 *     see {@link accountAddress}, which holds the trap.
 *  2. **The name, when a person chose it.** A profile somebody added and called
 *     "Client work" is called "Client work", signed in or not.
 *  3. **Which install this is.** *"Your own Claude Code install."*
 *
 * ## Why rung 3 is a sentence about the install rather than the sign-in state
 *
 * Because a state is not an identity. The chip on the desktop can fall back to
 * "Not signed in" or "Signed in · max" and still be saying something useful,
 * because it describes exactly one account. A *list* cannot: two rows share a
 * state constantly, and a sheet whose rows read "Signed in · max" and "Signed in
 * · max" has stopped being a picker. It is not a rare case either — Codex's CLI
 * never prints an address, by design, so the state rung would be the *only* one
 * a Codex login ever reached and every Codex row would be named after its plan.
 * Which install it is holds in all of those cases, is known without asking
 * anybody, and does not change under a finger when a probe lands.
 *
 * ## Why rung 3 names the agent, and when it may be asked not to
 *
 * It names the agent by default because on this screen the agent's name is the
 * only thing separating those rows. A fresh machine has one system account per
 * agent, so the sheet holds three of them, none has an address, and without the
 * agent's name all three read "Your own install" — the same caption on three
 * rows that are not the same account, which is precisely the failure he filmed
 * with a different word in it. The tinted dot beside the row carries the agent
 * too, but a dot is not a caption and one of those rows is about to be pressed.
 *
 * `namesTheAgent: false` turns "Your own Claude Code install" into "Your own
 * install", and it exists for exactly one shape of list: one whose rows have
 * *already* been filtered to a single agent. There the name distinguishes
 * nothing and what is left is a vendor's product name printed in a pop-up, which
 * is a thing he has asked against by name:
 *
 *   > *"You should not mention in any settings or any pop-up a specific tool or
 *   > LLM, because they can use some other also."*
 *
 * Nothing on this bar passes it today — the sheet lists every login on the far
 * machine, across every agent. It is here so that the screen that eventually
 * does filter has somewhere to say so, instead of growing a fourth copy of the
 * rule with one rung changed.
 *
 * ## An agent this build has never heard of
 *
 * Gets "Your own install" rather than its slug. `ServerSettingsText.knownProviderLabel`
 * answers nil for a `custom:` agent somebody added on the far machine, and a
 * true short sentence beats *"Your own custom:my-agent install"* — the same
 * direction `WireCodec.account` errs in when it meets a provider it does not
 * know, which is to keep the row rather than drop it.
 */
func accountLoginLabel(_ account: WireAccount, namesTheAgent: Bool = true) -> String {
    if let login = namedLogin(account) { return login }
    guard namesTheAgent, let provider = account.provider,
          let agent = ServerSettingsText.knownProviderLabel(provider) else {
        return "Your own install"
    }
    return "Your own \(agent) install"
}
