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

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { ProviderId } from '@shared/types'
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
 * The short form beside an account's name — the address when the CLI gave one.
 *
 * An email is the only label that tells two accounts apart with certainty; the
 * name is whatever the user typed and two people do call both of them "Work".
 * Null when there is nothing verified to show, and a caller that gets null must
 * show nothing rather than inventing a substitute.
 */
export function accountLabel(signIn: SignInView | undefined): string | null {
  if (!signIn || signIn.state !== 'signed-in') return null
  return signIn.account
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
 */
export function useAccounts(enabled = true): AccountsState {
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
            if (mine !== ticket.current) return
            setSignIn((current) => ({ ...current, [account.id]: parseSignIn(raw) }))
          })
          .catch((cause: unknown) => {
            if (mine !== ticket.current) return
            setSignIn((current) => ({
              ...current,
              [account.id]: {
                state: 'unknown',
                account: null,
                plan: null,
                detail: errorMessage(cause, 'This account’s sign-in state could not be read.'),
                command: '',
              },
            }))
          })
      }
    },
    [bridge],
  )

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
        check(false, next.accounts)
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
