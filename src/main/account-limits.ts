/**
 * What this app has established about a Claude login, and where that is kept.
 *
 * ## The bug this module is the answer to
 *
 * Asad, on 2026-08-18, running 0.5.0 on his Mac: *"usage page problem is not
 * fixed, it keeps coming in the running sessions"*.
 *
 * 0.5.0 already refused to ask a session twice once it had given a terminal
 * answer — the panel opened, had no plan limits in it, and would not for being
 * asked again. But that refusal was recorded on `Entry.blocked` in
 * `plan-limit.ts`, which is a field on a per-session record in a `Map` held in
 * memory, and both halves of that sentence are wrong for what it was recording:
 *
 *  - **Per session.** Five sessions open meant five free attempts at the same
 *    question, because each one had its own record and none had heard of the
 *    others. Whether a login has plan limits is a fact about the *login*.
 *  - **In memory.** Quitting the app threw every answer away. Installing the
 *    0.5.0 that contained the fix *restarted* the app, which is very likely why
 *    a fresh crop of panels arrived the moment it was installed.
 *
 * So the answer belongs against the account and it has to survive a restart.
 * It is written into `state.json` beside everything else this app remembers —
 * see `AccountLimitFact` in `store.ts` — keyed by the account's configuration
 * directory, which is what identifies an account everywhere else here.
 *
 * ## Why an interface rather than a call to `store()`
 *
 * Because `plan-limit.ts` is the module that decides whether to type into
 * somebody's terminal, and that decision is the most important thing in this
 * feature to be able to test. `store()` is a lazily-constructed singleton over
 * a real path, and a test that had to install a user-data directory to prove
 * "an account that answered once is not asked twice" would be testing the
 * filesystem. So the memory crosses into `plan-limit.ts` as an interface, the
 * app passes {@link storedAccountLimits}, and its tests pass a Map.
 */

import { store, type AccountLimitFact } from './store'

/** What Claude Code's own banner said a login is billed as. */
export type ClaudeBilling = 'subscription' | 'api'

/**
 * A terminal answer, remembered against the account that gave it.
 *
 * One member today, and it is deliberately not a boolean: the reason a session
 * stopped being asked has to be *said* on the bar, and a list of named answers
 * is what keeps the sentence and the record from drifting apart. `panel-open`
 * is not in it on purpose — a panel that would not close is a fact about a
 * terminal at a moment, not about a login, and persisting it would disable the
 * feature for good over what may have been one bad frame.
 */
export type SettledAnswer = 'no-limits'

/**
 * Everything remembered about one account.
 *
 * Both fields are absent until something has actually been observed. That is
 * the distinction the whole gate turns on: "nothing is known about this
 * account" must never read as "this account has nothing", because the first is
 * a reason to look and the second is a reason to stop.
 */
export interface AccountLimitMemory {
  /** What is remembered about this account, or null when nothing is. */
  read(configDir: string): AccountLimitFact | null
  /** Remember a field, leaving the other one alone. */
  write(configDir: string, patch: { billing?: ClaudeBilling; answer?: SettledAnswer }): void
  /** Forget everything about this account — what a person pressing Check means. */
  forget(configDir: string): void
}

/**
 * The app's own memory, backed by `state.json`.
 *
 * Constructed on demand rather than at import, for the same reason `store()`
 * itself is: the user-data directory is not known at import time in either
 * shell, and a module-level instance would pin whichever answer was current
 * when the file was first loaded.
 */
export function storedAccountLimits(): AccountLimitMemory {
  return {
    read: (configDir) => store().getAccountLimit(configDir),
    write: (configDir, patch) => {
      store().setAccountLimit(configDir, patch)
    },
    forget: (configDir) => store().forgetAccountLimit(configDir),
  }
}

/**
 * A memory that remembers nothing, for a build or a test that wires none.
 *
 * Not a null check at every call site: the gate in `plan-limit.ts` reads this
 * in four places and a missing memory has exactly one honest meaning — nothing
 * has been established — which is what this returns.
 */
export function forgetfulAccountLimits(): AccountLimitMemory {
  return { read: () => null, write: () => {}, forget: () => {} }
}
