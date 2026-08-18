/**
 * Accounts, as the window understands them.
 *
 * An "account" here is what `src/main/profiles.ts` calls a profile: an isolated
 * config directory handed to the agent CLI, which makes it a separate login
 * with its own history and its own transcripts. The engine has been there for a
 * while. What was missing was any way to see it, which for the person using the
 * app is the same as it not existing:
 *
 *   > "I don't see any kind of feature that I can use to have multiple accounts
 *   > in one application."
 *
 * So this file is the one model both surfaces read — the Accounts screen in
 * Settings and the account chip beside the folder — because two views of the
 * same list that parse it separately are two views that will eventually
 * disagree about which account is the default.
 *
 * ## Nothing here decides anything
 *
 * Precedence (session choice → project default → global default → your own
 * install) lives in the main process and is tested there. This narrows what
 * comes back over the bridge and nothing else. Where a value cannot be
 * established — a sign-in state that could not be read — it stays `unknown`
 * rather than being softened into a yes or a no.
 */

import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react'
import type { ProviderId } from '@shared/types'
// Relative, not '@shared/agent-catalog': vitest runs without the electron-vite
// alias, so a *value* import through it resolves in the app and throws in a
// test. Several other modules carry the same note for the same reason.
import { AGENT_CATALOG } from '../shared/agent-catalog'
import { isProviderId } from './preferences'

/* -------------------------------------------------------------- bridging -- */

/**
 * The slice of the preload bridge accounts need.
 *
 * Every method is checked against the preload by `preload/contract.test.ts`, so
 * a renamed channel fails a test rather than rendering a screen whose buttons
 * quietly do nothing. Everything arrives as `unknown` and is narrowed below.
 */
export interface AccountsBridge {
  listProfiles(): Promise<unknown>
  /**
   * Which agents can hold an account of their own, and why the others cannot.
   *
   * Asked at the moment the Add form is drawn rather than baked in, because the
   * answer is a measurement the main process made — see `provider-accounts.ts`,
   * where each agent's entry sits next to the commands it was established with.
   * The renderer's catalogue in `ProviderPicker.tsx` carries the same booleans
   * so the form can draw before this answers; this is what makes them provable.
   */
  accountProviders(): Promise<unknown>
  /**
   * @param options.provider which agent the account is a login of. Absent means
   *   Claude, which is what every caller meant before the form asked.
   */
  createProfile(name: string, options?: { provider?: ProviderId }): Promise<unknown>
  renameProfile(id: string, name: string): Promise<unknown>
  deleteProfile(id: string, options?: { deleteFiles?: boolean }): Promise<unknown>
  setDefaultProfile(id: string | null): Promise<unknown>
  setProjectDefaultProfile(projectPath: string, id: string | null): Promise<unknown>
  profileSignIn(id: string, options?: { refresh?: boolean }): Promise<unknown>
}

export function accountsBridge(host?: unknown): Partial<AccountsBridge> | null {
  const source =
    host ?? (typeof globalThis === 'undefined' ? undefined : (globalThis as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return null
  const api = source as Partial<AccountsBridge>
  // The list is the one method without which there is nothing to draw at all.
  return typeof api.listProfiles === 'function' ? api : null
}

/* ----------------------------------------------------------------- model -- */

export interface AccountView {
  id: string
  name: string
  /**
   * Which agent this is a login of, or null when the main process did not say.
   *
   * Not decoration. It decides which CLI a session started under this account
   * runs — handing a Codex directory to Claude Code is a broken session, not a
   * login — and it is what the mark beside the name is drawn from. Null draws no
   * mark and claims no agent, which is the honest answer for a payload from a
   * build that predates accounts having providers; guessing Claude there would
   * put an Anthropic mark beside somebody's ChatGPT login.
   */
  provider: ProviderId | null
  /** The directory handed to the CLI. Two names can look alike; two paths cannot. */
  configDir: string
  /** The user's own install — the account every fallback chain ends on. */
  system: boolean
  /** A custom property name from tokens.css; wrapped in `var()` at render time. */
  color: string
  /** Null until a session has actually been started under it. */
  lastUsedAt: number | null
}

export interface AccountsSnapshot {
  accounts: AccountView[]
  /** Null means "the user's own install", which is the system account. */
  defaultId: string | null
  /** Canonical project path → account id. */
  projectDefaults: Record<string, string>
}

export const EMPTY_SNAPSHOT: AccountsSnapshot = {
  accounts: [],
  defaultId: null,
  projectDefaults: {},
}

/** Mirrors `SignInState` in `src/main/profiles-signin.ts`. */
export type SignInState = 'signed-in' | 'signed-out' | 'unknown' | 'unsupported'

export interface SignInView {
  state: SignInState
  /** The address the CLI named, when it named one. */
  account: string | null
  plan: string | null
  detail: string
  /** The command that produced this, so the screen can show its working. */
  command: string
}

/** What a row shows while its answer is still being read. */
export const CHECKING: SignInView = {
  state: 'unknown',
  account: null,
  plan: null,
  detail: 'Checking with the agent…',
  command: '',
}

/**
 * What a row shows in a build that cannot ask the question at all.
 *
 * Found by opening the real app against a window whose preload predated the
 * channel: `check()` returned early, no row was ever given a state, and every
 * account sat on "Checking with the agent…" for as long as the screen was open.
 * A spinner that never resolves is the worst of the three answers — it is not
 * even a claim, so there is nothing for a person to disbelieve.
 */
export const UNCHECKABLE: SignInView = {
  state: 'unknown',
  account: null,
  plan: null,
  detail: 'This build cannot check whether this account is signed in.',
  command: '',
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : null
}

/**
 * A colour is a custom-property *name*, not a colour value.
 *
 * `profiles.json` is a file a person can edit, and `var(anything they typed)`
 * is at best a dot that never appears. Anything that is not a property name is
 * replaced with the accent rather than passed through.
 */
const CUSTOM_PROPERTY = /^--[A-Za-z0-9-]{1,64}$/

export function parseAccount(value: unknown): AccountView | null {
  const raw = asRecord(value)
  if (!raw) return null
  const { id, name, configDir } = raw
  if (typeof id !== 'string' || id === '') return null
  if (typeof name !== 'string' || name === '') return null
  return {
    id,
    name,
    // Narrowed rather than cast: `profiles.json` is a file a person can edit,
    // and an unrecognised string would reach `hasProviderMark` as a provider
    // this build has no mark for. Null is the answer for both cases and both
    // draw nothing.
    provider: isProviderId(raw.provider) ? raw.provider : null,
    configDir: typeof configDir === 'string' ? configDir : '',
    system: raw.system === true,
    color: typeof raw.color === 'string' && CUSTOM_PROPERTY.test(raw.color) ? raw.color : '--accent',
    lastUsedAt: typeof raw.lastUsedAt === 'number' ? raw.lastUsedAt : null,
  }
}

export function parseSnapshot(value: unknown): AccountsSnapshot {
  const raw = asRecord(value)
  const list = Array.isArray(raw?.profiles) ? raw.profiles : []
  const accounts = list
    .map(parseAccount)
    .filter((account): account is AccountView => account !== null)

  const projectDefaults: Record<string, string> = {}
  const rawDefaults = asRecord(raw?.projectDefaults)
  if (rawDefaults) {
    for (const [path, id] of Object.entries(rawDefaults)) {
      if (typeof id === 'string') projectDefaults[path] = id
    }
  }

  return {
    accounts,
    defaultId: typeof raw?.defaultProfileId === 'string' ? raw.defaultProfileId : null,
    projectDefaults,
  }
}

const STATES: ReadonlySet<string> = new Set(['signed-in', 'signed-out', 'unknown', 'unsupported'])

/**
 * A sign-in answer, narrowed.
 *
 * Anything unrecognised becomes `unknown` with the reason on it — never
 * `signed-out`. The two are different situations and only one of them is fixed
 * by logging in again.
 */
export function parseSignIn(value: unknown): SignInView {
  const raw = asRecord(value)
  const state = typeof raw?.state === 'string' && STATES.has(raw.state) ? (raw.state as SignInState) : 'unknown'
  return {
    state,
    account: typeof raw?.account === 'string' && raw.account !== '' ? raw.account : null,
    plan: typeof raw?.plan === 'string' && raw.plan !== '' ? raw.plan : null,
    detail:
      typeof raw?.detail === 'string' && raw.detail !== ''
        ? raw.detail
        : 'This account’s sign-in state could not be read.',
    command: typeof raw?.command === 'string' ? raw.command : '',
  }
}

/* --------------------------------------------------------------- renaming -- */

/**
 * How long an account's name may be.
 *
 * Lives here rather than in the settings screen because the settings screen is
 * no longer the only place a name can be typed — the account chip inside a
 * session renames too, and a second copy of this number is a second answer to
 * "why did it stop at 60 characters" that only one of the two surfaces gives.
 */
export const MAX_ACCOUNT_NAME_LENGTH = 60

/**
 * What a typed name means, or null when it means "do nothing".
 *
 * Both callers had the same three-line dance — trim, drop if empty, drop if
 * unchanged — and both had to get all three right for a rename to be safe. The
 * empty case matters most: the main process would happily store an account
 * called `''`, and an account with no name is one the chip cannot show and the
 * settings list cannot tell apart from its neighbour.
 *
 * The length cap is applied here as well as on the input's `maxLength`, because
 * `maxLength` is a property of a DOM element and this is also reachable by
 * pasting into a field that was rendered before the cap was raised.
 */
export function normalizeAccountName(typed: string, current: string): string | null {
  const name = typed.trim().slice(0, MAX_ACCOUNT_NAME_LENGTH)
  if (name === '' || name === current.trim()) return null
  return name
}

/**
 * Rename an account, wherever the rename was asked for.
 *
 * The single call both surfaces make. It exists because the alternative — the
 * chip growing its own copy — is how the two would come to disagree about the
 * length cap, about whether a blank name is a rename, and about whether the
 * account list is re-read afterwards. The last one is not cosmetic: ids,
 * colours and config directories are assigned in the main process, so a caller
 * that patches the name into its local copy is drawing an account that does not
 * match the one on disk.
 *
 * Resolves to null on success, or to the sentence to show when it failed.
 * Never throws: every caller here is a form submit handler, and an unhandled
 * rejection in one of those loses the message with the failure in it.
 */
export async function renameAccount(
  bridge: Partial<AccountsBridge> | null,
  account: { id: string; name: string },
  typed: string,
): Promise<string | null> {
  const name = normalizeAccountName(typed, account.name)
  if (name === null) return null
  if (typeof bridge?.renameProfile !== 'function') {
    return 'Renaming accounts is not wired into this window.'
  }
  try {
    await bridge.renameProfile(account.id, name)
    return null
  } catch (cause) {
    return errorMessage(cause, 'Could not rename that account.')
  }
}

/* ---------------------------------------------------------------- labels -- */

/**
 * The two fields an address is decided from, and nothing else.
 *
 * `SignInView` satisfies this, so nothing that already holds one changes. It
 * exists for the callers that do not: the New-session dialog parses the same
 * `profiles:signin` reply into its own narrower view — deliberately, because it
 * treats an unreadable answer as "say nothing" where this file treats it as a
 * state with a sentence — and had no way to ask this question without writing
 * its own copy of the rule below. Which is the one rule in this file that must
 * never be copied: see the trap in the body.
 */
export type SignInFacts = Pick<SignInView, 'state' | 'account'>

/**
 * The short form beside an account's name — the address when the CLI gave one.
 *
 * An email is the only label that tells two accounts apart with certainty; the
 * name is whatever the user typed and two people do call both of them "Work".
 * Null when there is nothing verified to show, and a caller that gets null must
 * show nothing rather than inventing a substitute.
 */
export function accountLabel(signIn: SignInFacts | undefined): string | null {
  // Gated on the state, not on the address being present: `claude auth status
  // --json` answers `{"loggedIn": false, "email": "…"}` for an expired login,
  // so the address outlives the session it belonged to.
  if (!signIn || signIn.state !== 'signed-in') return null
  return signIn.account
}

/**
 * Whether an id names an agent's own install rather than an account somebody
 * made.
 *
 * The ids come from `systemProfileId` in `src/main/profiles.ts`: `system` for
 * Claude, `system:<agent>` for the rest. It matters here because those two
 * kinds of account have names of two different kinds — one is a word a person
 * chose and the other is generated, and only the first is an identity. See
 * {@link accountIdentity}.
 *
 * Looser than the main process's own test, which checks the suffix against the
 * agents it knows. That is the right direction to be loose in: an id shaped
 * like a system one that the main process does not recognise resolves to no
 * account at all there, so treating it as generated here costs nothing, whereas
 * treating a generated name as an identity is the whole bug.
 */
export function isSystemAccountId(id: string): boolean {
  return id === 'system' || id.startsWith('system:')
}

/** What to print where an account has to be named, and why it says that. */
export interface AccountIdentity {
  /**
   * The line for the chip. Never a generated profile name.
   *
   * *"Inside the terminal page it is still showing selected account as Default
   * and not showing the email ID."* "Default" is the key the main process
   * generates for the machine's own install — an internal slug that had reached
   * the one control whose entire job is saying which login a session is running
   * as. It is not an identity and it never tells two logins apart.
   */
  label: string
  /** The whole sentence behind the label, for the control's title. */
  detail: string
  /**
   * True only when `label` is an address the agent's own CLI named.
   *
   * Read by the chip to decide whether to draw the label as a fact or as a
   * state. Nothing here ever sets it for a string this app composed.
   */
  verified: boolean
}

/**
 * Who a session is running as, in the words that are actually true of it.
 *
 * Measured on this machine rather than assumed, because the three agents answer
 * three different amounts and the difference is the whole design of this
 * function — see `main/profiles-signin.ts` for the probes:
 *
 *   claude auth status --json  → `{"loggedIn":true,"email":"…","subscriptionType":"max"}`
 *   codex login status         → `Logged in using ChatGPT` — no address, ever
 *   gemini                     → has no status command at all; read from disk
 *
 * So an email is available for one agent out of three, and the other two get a
 * sentence about what *is* known rather than a placeholder that reads like an
 * address. The ladder:
 *
 * 1. The address the CLI named. This is the ask, and it is the only label that
 *    tells two accounts apart with certainty.
 * 2. Failing that, the account's own name — but only when a person chose it.
 *    "Work" is an identity somebody assigned; "Default (Codex CLI)" is a string
 *    this app generated and means nothing to the person reading it.
 * 3. Failing that, the state the agent reported, said plainly: signed in with
 *    no address, not signed in, or not readable.
 *
 * There is no rung that invents an address, and no rung that falls back to the
 * profile key.
 */
export function accountIdentity(
  account: { id: string; name: string; system?: boolean } | null,
  signIn: SignInView | undefined,
): AccountIdentity {
  if (!account) {
    return {
      label: 'Account',
      detail: 'Choose which account a new session here uses.',
      verified: false,
    }
  }

  const summary = signInSummary(signIn)
  if (summary.verified) return summary

  /*
   * A name a person chose is an identity; a generated one is a slug.
   *
   * `system` from the account list when it has been read, because that is the
   * main process's own answer; the id only has to carry it before the list has
   * arrived, which for the chip is most of a session's first second.
   */
  const generated = account.system ?? isSystemAccountId(account.id)
  if (generated) return summary
  return {
    label: account.name,
    detail:
      signIn === undefined
        ? `The account you named ${account.name}. Which login it holds has not been read yet.`
        : `${account.name} — ${summary.detail}`,
    verified: false,
  }
}

/**
 * What the agent said about a login, with no account name involved.
 *
 * Split out of {@link accountIdentity} because the menu's rows need exactly
 * this and not the name rung: the name is already printed on the left of the
 * row, and a right-hand column that repeated it would say the same word twice
 * and tell you nothing about whether that account can start a session.
 */
export function signInSummary(signIn: SignInView | undefined): AccountIdentity {
  /*
   * `accountLabel`, which gates the address on the login being live.
   *
   * Not `signIn.account` directly, and the difference is a real state rather
   * than a defensive one: `claude auth status --json` answers `{"loggedIn":
   * false, "email": "…"}` for an expired login, so the address survives the
   * session it belonged to. Printed on the chip it would say a session is
   * running as an account that cannot start one — the exact wrong answer, and
   * the confident-sounding kind.
   */
  const address = accountLabel(signIn)
  if (address !== null) {
    return { label: address, detail: signIn?.detail ?? `Signed in as ${address}`, verified: true }
  }
  return signInStateSummary(signIn)
}

/**
 * The same ladder with its top rung removed: what the agent said, never who.
 *
 * Split out of {@link signInSummary} for the one caller that prints an identity
 * and a state side by side — the account chip's menu, whose rows carry the login
 * on the left and its state on the right. Both halves used to come off
 * `signInSummary`, and the moment the left half stopped printing the internal
 * profile slug the two collapsed into the same string: a row reading
 * `app.imatch.ae@gmail.com … app.imatch.ae@gmail.com`, which is one fact printed
 * twice and the state — the thing that says whether this account can start a
 * session at all — printed not at all.
 *
 * So a caller that has already said *who* asks this for *how it is*, and gets a
 * sentence that can never repeat the address. Nothing else changes: the two
 * functions are one ladder with one entry point each, rather than one function
 * two callers disagree about.
 */
export function signInStateSummary(signIn: SignInView | undefined): AccountIdentity {
  switch (signIn?.state) {
    case 'signed-in':
      /*
       * Signed in, and — when this is the last rung reached — the CLI will not
       * say as whom.
       *
       * Codex is that case and it is not a gap this app can close: `codex login
       * status` prints `Logged in using ChatGPT` and the only place an address
       * exists is inside `auth.json`'s id token, which `profiles.ts` does not
       * open — never holding a credential is the property that keeps it
       * uninteresting to an attacker. So the login *method* is shown, because
       * it is the one distinguishing thing that was actually reported.
       *
       * The closing sentence is conditional because this is now also reached
       * *with* an address in hand, by a caller that has already printed it
       * elsewhere on the row. Saying "this agent's CLI does not print an email
       * address" beside a row that is printing one would be the app calling its
       * own label a fabrication.
       */
      return {
        label: signIn.plan === null ? 'Signed in' : `Signed in · ${signIn.plan}`,
        detail:
          signIn.account === null
            ? `${signIn.detail} This agent’s CLI does not print an email address.`
            : signIn.detail,
        verified: false,
      }
    case 'signed-out':
      return { label: 'Not signed in', detail: signIn.detail, verified: false }
    case 'unsupported':
      return { label: 'No login', detail: signIn.detail, verified: false }
    case 'unknown':
      // Answered, and the answer was "could not tell". Distinct from the case
      // below, which has not answered yet — one of them resolves on its own.
      return { label: 'Account unknown', detail: signIn.detail, verified: false }
    default:
      return {
        label: 'Checking…',
        detail: 'Asking the agent which account this session is running as.',
        verified: false,
      }
  }
}

/**
 * As much of an account as any of these labels ever reads.
 *
 * Structural rather than {@link AccountView}, because the four lists that have
 * to stop printing the slug hold four different records of the same thing — the
 * sidebar's `WorkspaceTab.account`, the Overview board's card, Settings'
 * `ProfileSummary` and this file's own `AccountView`. Widening the parameter is
 * what let all four share one ladder instead of growing four opinions about
 * what an account is called; converting them into a common record at each call
 * site would have been four conversions to keep in step.
 *
 * `provider` is optional and nullable for the same reason it is nullable on
 * `AccountView`: a payload from a build that predates accounts having providers
 * simply does not say, and guessing Claude there names the wrong agent.
 */
export interface NamedAccount {
  id: string
  name: string
  provider?: ProviderId | null
  /** The user's own install. Falls back to the shape of the id — see below. */
  system?: boolean
}

/**
 * Whether this account's name was generated rather than chosen.
 *
 * `system` **or** the shape of the id, and the `or` is load-bearing. The flag is
 * the main process's own answer and is the better one, but it is a required
 * boolean on every list that carries it — so a snapshot from a build that
 * predates the flag arrives as an explicit `false`, not as "unknown", and a
 * `??` here would read that as "somebody named this account Default (Gemini
 * CLI)". The id cannot be faked the other way: `profiles.ts` mints `system` and
 * `system:<agent>` for the installs and never for an account anybody added.
 *
 * {@link accountIdentity} deliberately uses `??` instead, and that is not a
 * disagreement: its `system` is optional and genuinely absent until the account
 * list has been read, so there "unknown" is a third state and the id is what
 * answers it.
 */
function isGeneratedAccount(account: NamedAccount): boolean {
  return account.system === true || isSystemAccountId(account.id)
}

/**
 * What one login is called in a list you choose it from.
 *
 * The account chip was taught this and the pickers were not, which left the
 * word the chip exists to suppress printed one line below the answer:
 *
 *     Login
 *     app.imatch.ae@gmail.com · max          [ Default  ⌄ ]
 *
 * `Default` is not a name anybody gave that login. It is the key
 * `systemProfileId` in `main/profiles.ts` generates for the machine's own
 * install — `system`, `system:codex`, `system:gemini`, rendered as "Default",
 * "Default (Codex CLI)", "Default (Gemini CLI)" — and it says something about
 * *precedence*, not about whose account it is. The row beside it already
 * carried the real answer.
 *
 * The first two rungs are {@link accountIdentity}'s, and the first one is
 * delegated rather than restated because it holds a trap worth exactly one bug:
 * an expired Claude login still reports its email, so the address has to be
 * gated on the *state* and `accountLabel` is where that is written down.
 *
 *  1. the address the agent's own CLI named,
 *  2. failing that, the name — but only when a person chose it,
 *  3. failing that, which install this is.
 *
 * The third rung is where this parts company with the chip, and deliberately.
 * The chip describes one account, so it can fall back to the *state* it read —
 * "Not signed in", "Signed in · max" — and be saying something useful. A list
 * cannot: a state is not an identity, two rows can share one, and a picker
 * whose options read "Signed in · max" and "Signed in · max" has stopped being
 * a picker. It is not a rare case either — Codex's CLI never prints an address
 * at all, by design, so the state rung is the *only* one it would ever reach,
 * and every Codex login in the list would be named after its plan. Which
 * install it is holds in all of those cases, is known without asking anybody,
 * and does not change under the pointer when a probe lands.
 *
 * ## Why the third rung may be asked to drop the agent's name
 *
 * `namesTheAgent: false` turns "Your own Claude Code install" into "Your own
 * install", and it exists for exactly one shape of list: one whose rows have
 * already been filtered to a single agent.
 *
 * The default names the agent because the name is the only thing separating
 * those rows. On a fresh machine `main/profiles.ts` generates one system
 * account per agent, so this list holds three of them, none has an address, and
 * without the agent's name all three read "Your own install" — the same
 * caption on three rows that are not the same account, which is the failure
 * {@link accountRail} spends a paragraph refusing to ship. The mark beside the
 * row carries the agent too, but a glyph is not a caption and one of those rows
 * is about to be made the default.
 *
 * Where the list has been filtered, none of that holds and the opposite rule
 * applies. The copilot's setup flow offers only the accounts its own session
 * could run as, so every row on it belongs to one agent, the name distinguishes
 * nothing, and what is left is a vendor's product name printed in a pop-up —
 * which is the thing the review asked for by name:
 *
 *   > *"You should not mention in any settings or any pop-up a specific tool or
 *   > LLM, because they can use some other also."*
 *
 * So the flag is not a style switch. It says "this list has already answered
 * the question the name was there to answer", and it is only true where the
 * caller has done the filtering.
 *
 * `system` off the list when it has been read, because that is the main
 * process's own answer, and the id only has to carry it before the list
 * arrives.
 *
 * It lives here rather than beside the dialog it was written for because it is
 * now what five surfaces print — the New-session dialog, the Overview cards,
 * both Settings lists and the chip's own menu — and a rule that five screens
 * share is a rule that belongs in the file the other four rungs are in.
 * `ProfilePicker.tsx` re-exports it so its own callers did not have to move.
 */
export function profileLoginLabel(
  account: NamedAccount,
  signIn: SignInFacts | undefined,
  options?: { namesTheAgent?: boolean },
): string {
  const address = accountLabel(signIn)
  if (address !== null) return address
  if (!isGeneratedAccount(account)) return account.name
  // An agent this build does not know still gets a true sentence rather than
  // the slug — the same direction `parseAccount` errs in when it meets one.
  const agent =
    options?.namesTheAgent === false || account.provider == null
      ? undefined
      : AGENT_CATALOG[account.provider]?.label
  return agent ? `Your own ${agent} install` : 'Your own install'
}

/**
 * The same login, for a column twelve characters wide.
 *
 * The sidebar is the one list that cannot be given the label above. Its account
 * column is capped at `12ch` in `shell.css`, and that cap is not arbitrary:
 * `ACCOUNT_NEEDS_RAIL` in `workspace-tabs.ts` works out that a 240px rail has
 * 203px of line, of which the account may have about 84 — because the session's
 * *name* is what the row exists to carry and the account is the thing that
 * gives. "Your own Claude Code install" in that column is `Your own Cl…`, which
 * identifies nothing, and the whole address is `app.imatch.…`, which cuts off
 * exactly the half that differs.
 *
 * So the rungs are the same three facts, said in the shortest true form:
 *
 *  1. the mailbox of the address — the part before the `@`. Two logins of one
 *     agent are nearly always two mailboxes at the *same* domain, so the domain
 *     is the half carrying no information in a column this narrow, and dropping
 *     it is what makes `app.imatch.ae` fit where `app.imatch.…` did not.
 *  2. the name, when a person chose it. "Work" was already short.
 *  3. nothing at all. This is the deliberate one: there is no twelve-character
 *     way to say "your own Codex CLI install" that still distinguishes it from
 *     "your own Claude Code install", and an abbreviation that drops the agent
 *     would put two identical captions on two rows that are not the same
 *     account — the exact failure this whole pass is closing. An empty column
 *     is honest, and the fact is not lost: it moves into the row's tooltip,
 *     which is the same trade `accountsWorthShowing` already makes when the
 *     rail is too narrow to caption at all.
 *
 * `note` is that tooltip clause, and it is returned from here rather than
 * composed by the caller so the two can never describe different rungs. Its
 * wording follows the rung: "signed in as" is a claim about a login and is only
 * made where there is one, while the machine's own install gets "on …", which
 * is true whether or not anybody has ever signed into it.
 */
export interface RailIdentity {
  /** The caption for the row, or null when nothing true is short enough. */
  short: string | null
  /** The same fact with room to breathe, for the row's `title`. */
  note: string
}

export function accountRail(
  account: NamedAccount,
  signIn: SignInFacts | undefined,
): RailIdentity {
  const address = accountLabel(signIn)
  if (address !== null) {
    // `split` rather than a slice at `indexOf`, and the guard is not decorative:
    // `profiles-signin.ts` hands through whatever the CLI printed, and a line
    // with no `@` in it — or one that begins with it — must not become an empty
    // caption that reads as a value which failed to load.
    const mailbox = address.split('@')[0]
    return { short: mailbox === '' ? address : mailbox, note: `signed in as ${address}` }
  }
  if (!isGeneratedAccount(account)) {
    return { short: account.name, note: `signed in as ${account.name}` }
  }
  const label = profileLoginLabel(account, signIn)
  // Lower-cased for the one rung whose label is a phrase rather than a name:
  // it is being joined into the middle of the row's tooltip, and "Session 5 —
  // on Your own Claude Code install" reads as a proper noun that is not one.
  return { short: null, note: `on ${label.charAt(0).toLowerCase()}${label.slice(1)}` }
}

/** One word for a row's right-hand column. Never a tick that was not verified. */
export function signInLabel(signIn: SignInView | undefined): string {
  switch (signIn?.state) {
    case 'signed-in':
      return 'Signed in'
    case 'signed-out':
      return 'Not signed in'
    case 'unsupported':
      return 'Not applicable'
    default:
      return 'Unknown'
  }
}

/**
 * Which account a *new* session in this folder would run as, given what is on
 * screen right now.
 *
 * The same order the main process resolves in, and it is duplicated here for
 * one reason: the chip has to be able to say which account it is about to use
 * *before* anything is started, and the authoritative answer is only produced
 * at spawn. Kept to those two levels — project default, then global default,
 * then the system account — so it cannot drift into a second opinion about
 * anything else. `profiles.ts` owns the real chain.
 */
export function accountForFolder(
  snapshot: AccountsSnapshot,
  projectPath: string | null,
): AccountView | null {
  const known = (id: string | null | undefined): AccountView | undefined =>
    typeof id === 'string' ? snapshot.accounts.find((account) => account.id === id) : undefined

  const project = projectPath === null ? undefined : known(snapshot.projectDefaults[projectPath])
  return (
    project ??
    known(snapshot.defaultId) ??
    snapshot.accounts.find((account) => account.system) ??
    snapshot.accounts[0] ??
    null
  )
}

/* ------------------------------------------------- answers already paid for -- */

/**
 * Every sign-in answer this window has read, in one place, for the lists that
 * must not ask.
 *
 * ## Why a store and not another hook
 *
 * Asking costs a process. `profiles-signin.ts` spawns the agent's own `auth
 * status` under that account's config directory, which is why {@link
 * useAccounts} probes nothing until a menu is opened and why {@link
 * useAccountIdentity} probes exactly one account — the one the chip on screen is
 * about. That rule is right and it has one consequence: the surfaces that most
 * need the address are the ones least able to ask for it. The sidebar draws a
 * row per session and is on screen for the whole life of the window; a hook per
 * row would spawn a CLI per row on mount, every mount, and the rail would cost
 * more than the terminals in it.
 *
 * So no list asks. They read what somebody else already asked, and the answer
 * outlives the component that paid for it: the chip probes the account of the
 * session you are looking at, the chip's menu probes the whole list the moment
 * it is opened, and the Accounts screen probes on open too. Each of those writes
 * here, and every list watching gets the address at the same instant the chip
 * does — which is the other half of the bug being fixed, because the rail
 * printing `Default` while the chip forty pixels above it printed the address
 * was one account wearing two names in one frame.
 *
 * ## What a reader gets before anybody has asked
 *
 * Nothing, and that is the honest answer rather than a gap. A caller reads the
 * lower rungs of {@link profileLoginLabel} or {@link accountRail} until an
 * answer lands, both of which are true without asking anyone. Only *answers*
 * are stored — never the "Checking…" placeholder — because a placeholder is not
 * a fact and a list that cached one would show it for as long as nothing else
 * refreshed it.
 *
 * ## Freshness
 *
 * The main process memoises each answer for thirty seconds (`SIGNIN_CACHE_MS`),
 * so what is held here is at worst one probe out of date, and the surfaces that
 * can ask — the chip, the menu, the Check button — refresh it as a side effect
 * of being used. A late reply for an account that has since been re-probed can
 * overwrite a newer one with an equal one; nothing here tries to order two
 * answers to the same question from the same thirty-second memo, because the
 * machinery to do it would be larger than the fact it protects.
 */
let answered: Readonly<Record<string, SignInView>> = {}
const watchers = new Set<() => void>()

/** The answers as they stand. Stable between writes, so it is safe to compare. */
export function knownSignIns(): Readonly<Record<string, SignInView>> {
  return answered
}

function rememberSignIn(id: string, view: SignInView): void {
  if (answered[id] === view) return
  answered = { ...answered, [id]: view }
  for (const watcher of watchers) watcher()
}

function watchSignIns(watcher: () => void): () => void {
  watchers.add(watcher)
  return () => {
    watchers.delete(watcher)
  }
}

/**
 * Subscribe to those answers without ever causing one.
 *
 * The whole point of the store: a list can render the address the moment it is
 * known and never be the reason a process was started. `useSyncExternalStore`
 * rather than an effect and a piece of state, because the same snapshot has to
 * serve the server renderer this project's tests use — `renderToStaticMarkup`
 * with no window at all — and a component that subscribed by effect would
 * simply render the empty map there and never say why.
 */
export function useKnownSignIns(): Readonly<Record<string, SignInView>> {
  return useSyncExternalStore(watchSignIns, knownSignIns, knownSignIns)
}

/**
 * Empty the store.
 *
 * For tests, which share one module instance across every case in a file: an
 * answer remembered by one case is a component in the next one rendering an
 * address nothing in it asked for. Nothing in the app calls this — an account's
 * sign-in state does not stop being known because a screen closed.
 */
export function forgetSignIns(): void {
  answered = {}
  for (const watcher of watchers) watcher()
}

/* ------------------------------------------------------------------ hook -- */

export interface AccountsState {
  snapshot: AccountsSnapshot
  /** Sign-in answers by account id. Absent while a check is still in flight. */
  signIn: Readonly<Record<string, SignInView>>
  /** True while the first list is still loading. */
  loading: boolean
  /** Set when the list itself could not be read. */
  error: string | null
  /** Whether the window has the accounts bridge at all. */
  available: boolean
  reload(): void
  /** Re-ask the agent about every account. `force` skips the main memo. */
  check(force?: boolean): void
}

export function errorMessage(cause: unknown, fallback: string): string {
  if (cause instanceof Error && cause.message) {
    // Electron prefixes a rejected invoke with the channel; the sentence after
    // it is the one `profiles.ts` wrote for the user.
    const tail = cause.message.split("Error: ").pop()
    return tail && tail.trim() !== '' ? tail.trim() : fallback
  }
  return fallback
}

/**
 * Load the account list, then ask the agent which of them are signed in.
 *
 * The two are separate on purpose. The list is a file read and lands in
 * milliseconds; a sign-in check spawns the CLI once per account. Waiting for
 * the second before drawing the first would leave the screen blank for the time
 * it takes to start a process, for information that is an extra line on a row.
 *
 * `enabled` exists so a menu does not spawn a process every render just by
 * being mounted: the chip passes `open`, so the check happens when it is opened
 * and not before.
 *
 * `probe` splits that gate in two, because the two halves cost wildly different
 * things and the chip needs one without the other. Reading the list is a JSON
 * file read and lands in milliseconds; checking sign-in spawns the agent's CLI
 * once per account. The chip has to know the account list from the moment it is
 * drawn — otherwise it cannot say which account a new session here would use,
 * and it spent the first second of every session with no name on it at all —
 * but it must not spawn three processes for a control nobody has clicked.
 * Defaults to `enabled`, so every existing caller behaves exactly as before.
 */
export function useAccounts(enabled = true, probe = enabled): AccountsState {
  const bridge = useMemo(() => accountsBridge(), [])
  const [snapshot, setSnapshot] = useState<AccountsSnapshot>(EMPTY_SNAPSHOT)
  const [signIn, setSignIn] = useState<Record<string, SignInView>>({})
  const [loading, setLoading] = useState(enabled)
  const [error, setError] = useState<string | null>(null)

  /**
   * Which load is the current one. Every reply checks its ticket before setting
   * state: a reload started while another is in flight would otherwise be
   * decided by whichever process happened to answer last.
   */
  const ticket = useRef(0)
  useEffect(
    () => () => {
      // Anything still in flight is answering a question nobody is asking.
      ticket.current += 1
    },
    [],
  )

  /**
   * The current account list, readable without depending on it.
   *
   * A ref rather than the state, because `check` would otherwise change
   * identity every time the snapshot did — and `reload` calls `check`, so the
   * two would take turns invalidating each other and the mount effect would
   * reload the list in a loop, spawning a process per account per pass.
   */
  const accountsRef = useRef<readonly AccountView[]>([])
  accountsRef.current = snapshot.accounts

  const check = useCallback(
    (force = false, accounts?: readonly AccountView[]) => {
      const mine = ticket.current
      const list = accounts ?? accountsRef.current
      if (list.length === 0) return

      const ask = bridge?.profileSignIn
      if (!ask) {
        // Say so once, rather than leaving every row on "Checking…" for as long
        // as the screen is open. See `UNCHECKABLE`.
        setSignIn(Object.fromEntries(list.map((account) => [account.id, UNCHECKABLE])))
        return
      }

      // Every row shows "Checking…" before the first process starts, so a slow
      // machine reads as working rather than as an empty column.
      setSignIn((current) => {
        const next = { ...current }
        for (const account of list) if (force || !next[account.id]) next[account.id] = CHECKING
        return next
      })

      for (const account of list) {
        void ask
          .call(bridge, account.id, { refresh: force })
          .then((raw) => {
            const view = parseSignIn(raw)
            // Shared before the ticket is checked, and deliberately: a reply
            // that arrived too late for *this* screen is still a true answer
            // about that account, and the rail is drawing it right now.
            rememberSignIn(account.id, view)
            if (mine !== ticket.current) return
            setSignIn((current) => ({ ...current, [account.id]: view }))
          })
          .catch((cause: unknown) => {
            const view: SignInView = {
              state: 'unknown',
              account: null,
              plan: null,
              detail: errorMessage(cause, 'This account’s sign-in state could not be read.'),
              command: '',
            }
            rememberSignIn(account.id, view)
            if (mine !== ticket.current) return
            setSignIn((current) => ({ ...current, [account.id]: view }))
          })
      }
    },
    [bridge],
  )

  /**
   * Whether a list that has just arrived should be checked as well as shown.
   *
   * A ref rather than a dependency, so `reload` keeps its identity when the
   * caller flips `probe`. As a dependency it would invalidate `reload`, which
   * would re-run the mount effect, which would re-read the list — so every open
   * *and* every close of the chip's menu would fetch the account list again for
   * no reason. The flip is handled by its own effect below instead.
   */
  const probeRef = useRef(probe)
  probeRef.current = probe

  const reload = useCallback(() => {
    if (!bridge?.listProfiles) {
      setLoading(false)
      return
    }
    const mine = (ticket.current += 1)
    setLoading(true)
    void bridge.listProfiles().then(
      (raw) => {
        if (mine !== ticket.current) return
        const next = parseSnapshot(raw)
        setSnapshot(next)
        setError(null)
        setLoading(false)
        if (probeRef.current) check(false, next.accounts)
      },
      (cause: unknown) => {
        if (mine !== ticket.current) return
        setError(errorMessage(cause, 'Could not read your accounts.'))
        setLoading(false)
      },
    )
  }, [bridge, check])

  useEffect(() => {
    if (!enabled) return
    reload()
  }, [enabled, reload])

  // The list is already in hand and the caller has just started wanting sign-in
  // state — the chip's menu opening. `check` is memoised on nothing that moves
  // and returns immediately for an empty list, so this is a no-op until there
  // is something to ask about.
  useEffect(() => {
    if (!enabled || !probe) return
    check(false)
  }, [enabled, probe, check])

  return {
    snapshot,
    signIn,
    loading,
    error,
    available: bridge !== null,
    reload,
    check,
  }
}

/**
 * The sign-in answer for **one** account, asked as soon as it is known.
 *
 * {@link useAccounts} deliberately asks about nothing until a menu is opened,
 * because asking spawns the agent's CLI once per account and the account chip
 * is on screen for the whole life of every session. That rule is right for the
 * *list* and wrong for the one account the chip is actually about — which is
 * how the chip came to print the profile key instead of the address:
 *
 *   > "inside the terminal page it is still showing selected account as Default
 *   > and not showing the email ID."
 *
 * There is no way to draw the address without asking, and the address is the
 * whole point of the control. So exactly one account is asked about: one
 * process, on a 0.27s command, and only when the id changes — switching tabs
 * between sessions on the same account asks nothing at all. `SIGNIN_CACHE_MS`
 * in the main process holds the answer for thirty seconds on top of that, so
 * even flicking between two accounts is one spawn each and then silence.
 *
 * Never refreshes: this is a read for a label, and forcing past the memo is
 * what the Accounts screen's Check button is for.
 *
 * The answer is kept in {@link knownSignIns} rather than in this hook's own
 * state, which is what makes one probe serve the whole window: the sidebar row
 * for this same session, and the Overview card for it, draw the address from
 * that store without asking anybody. It also means switching to a tab whose
 * account has already been read shows the address on the first frame instead of
 * spending a render on "Checking…" for a fact this window already has.
 */
export function useAccountIdentity(accountId: string | null): SignInView | undefined {
  const bridge = useMemo(() => accountsBridge(), [])
  const known = useKnownSignIns()

  useEffect(() => {
    if (accountId === null) return
    const ask = bridge?.profileSignIn
    if (!ask) {
      // Say so rather than leaving the chip on "Checking…" for the life of the
      // window — the failure `UNCHECKABLE` was written for, which was found by
      // running the app against a preload that predated the channel.
      rememberSignIn(accountId, UNCHECKABLE)
      return
    }

    // Not a ticket count like `useAccounts`: this asks about one id at a time
    // and every answer is stored under the id it was asked about, so a late
    // reply cannot be attributed to the account that replaced it. Nor is there
    // an unmount guard any more — the answer goes to a store rather than to
    // this component's state, and a fact about an account does not stop being
    // true because the chip that asked for it was unmounted a moment later.
    void ask
      .call(bridge, accountId)
      .then((raw) => {
        rememberSignIn(accountId, parseSignIn(raw))
      })
      .catch((cause: unknown) => {
        rememberSignIn(accountId, {
          state: 'unknown',
          account: null,
          plan: null,
          detail: errorMessage(cause, 'This account’s sign-in state could not be read.'),
          command: '',
        })
      })
  }, [accountId, bridge])

  return accountId === null ? undefined : known[accountId]
}
