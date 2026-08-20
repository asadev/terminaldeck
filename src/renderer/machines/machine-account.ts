/**
 * Whose login a session on one of his own machines is running as, and running
 * it as another one.
 *
 * ## The complaint
 *
 * Asad, 2026-08-20, on a session running on his PC:
 *
 *   > *"Then also bring the account selection here for the remote sessions too."*
 *
 * There was no chip on that bar at all. The note where one should have been said
 * why, and it was true when it was written: *"which account an agent on another
 * machine was spawned under is not a fact any frame on the wire carries"*. It is
 * carried now — `CAPABILITY.account`, in `src/main/remote/protocol.ts` — and this
 * is the window's end of it.
 *
 * ## Why the account is read here and not inside the control cluster
 *
 * Because the chip is not in the cluster. It sits on the title line beside the
 * folder, where the local one sits, and *"exactly like the local ones"* is the
 * whole requirement — so it is mounted where that one is mounted and reads what
 * it needs from where it is.
 *
 * That is a second reader of the same machine, which is a thing this codebase is
 * rightly nervous about: the last time two components on one bar asked the same
 * question of two *different sources*, the account chip drew a picker over a
 * running agent while the model chip forty pixels away withdrew itself. This is
 * not that. There is one source — the far machine — reached through one
 * capability, and what the two readers ask for does not overlap: the cluster
 * asks `controls.read`, this asks `account.read`. They cannot disagree about a
 * fact because they are not reading the same fact.
 *
 * ## What it costs over there, and why it is not on the output schedule
 *
 * A state file and a spawn record: `listProfiles` is one JSON read and
 * `sessionAccount` answers from what that machine established when it spawned
 * the process. Cheap, but it does not change when a session prints — an account
 * changes when somebody adds one, signs one in, or switches this session — so
 * this deliberately does **not** ride `session:data` the way the model chip
 * does. It reads on mount, when the session changes, and when the menu is
 * opened, which is the moment somebody is about to look at the list.
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import { parseSignIn, type SignInView } from '../accounts'
import type { ProviderId } from '@shared/types'

/** One login on the far machine, as the chip draws it. Mirrors `AccountWire`. */
export interface MachineAccount {
  id: string
  name: string
  /** Null when the far end did not say. Never guessed — a wrong mark is worse. */
  provider: ProviderId | null
  /** A custom-property name from `tokens.css`, wrapped in `var()` at render. */
  color: string | null
  system: boolean
  /**
   * What that machine's own CLI said about this login, or null when it did not
   * say at all.
   *
   * Null is a build over there older than `AccountWire.signIn`, and it is kept
   * apart from every state inside a `SignInView` on purpose: "that machine does
   * not report this" and "that machine could not tell" are different facts with
   * different remedies. {@link NOT_REPORTED} is the sentence for the first.
   */
  signIn: SignInView | null
}

/**
 * What the chip is told when the far machine's build carries no sign-in at all.
 *
 * A state, and a sentence that says which machine is the one that cannot answer
 * — not "Checking…", which is what an absent answer used to resolve to and which
 * never resolves to anything else. A spinner that runs forever is not even a
 * claim, so there is nothing for a person to disbelieve; `UNCHECKABLE` in
 * `accounts.ts` makes the same trade for the same reason, one machine closer.
 */
export const NOT_REPORTED: SignInView = {
  state: 'unknown',
  account: null,
  plan: null,
  detail: 'That machine is running a build that does not say which login it is signed in as.',
  command: '',
}

/**
 * The sign-in facts for one row, or the sentence for a machine that sent none.
 *
 * One function so the chip, its tooltip and its menu rows cannot disagree about
 * which of the two absences they are looking at.
 */
export function signInOf(account: MachineAccount | null): SignInView {
  return account?.signIn ?? NOT_REPORTED
}

export interface MachineAccountState {
  /** The login this session is on, or null when that machine could not say. */
  current: MachineAccount | null
  /** Every login that machine has. Empty until the first answer lands. */
  accounts: MachineAccount[]
  /** False until an answer has landed, whatever that answer was. */
  loaded: boolean
  /** Ask again — after a switch, or when the menu is opened. */
  reload(): void
}

interface Bridge {
  readMachineAccount?(machineId: string, sessionId: string): Promise<unknown>
  switchMachineAccount?(machineId: string, sessionId: string, accountId: string): Promise<unknown>
}

/**
 * `globalThis` rather than `window`, because the shell's components are rendered
 * to a string in their own tests, where there is no `window` at all — reading it
 * during render throws and takes the whole bar down with it.
 */
function bridge(): Bridge | undefined {
  return (globalThis as unknown as { deck?: Bridge }).deck
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * One account off the bridge, or null.
 *
 * Total and defensive: an id and a name are the two fields a row cannot be drawn
 * without — the id is what a press sends back, the name is what a person reads —
 * so a record missing either is not a half-row, it is not a row. Everything else
 * folds onto null rather than onto a plausible value, for the reason
 * `readServers` states one file over: a mark or a colour invented here is the
 * app asserting something it did not read.
 */
export function readAccount(value: unknown): MachineAccount | null {
  if (!isRecord(value)) return null
  if (typeof value.id !== 'string' || value.id === '') return null
  if (typeof value.name !== 'string' || value.name === '') return null
  return {
    id: value.id,
    name: value.name,
    provider: typeof value.provider === 'string' ? (value.provider as ProviderId) : null,
    color: typeof value.color === 'string' && value.color !== '' ? value.color : null,
    system: value.system === true,
    /*
     * Present or absent, never composed.
     *
     * `parseSignIn` turns anything unreadable into a state with a sentence,
     * which is right for the local screen that always asks — and wrong here,
     * where a *missing* key means the far machine's build never answers this
     * question. So the key is checked first and only then narrowed.
     */
    signIn: isRecord(value.signIn) ? parseSignIn(value.signIn) : null,
  }
}

/** The whole answer, or null when there was not one to read. */
export function readAccountState(
  value: unknown,
): { current: MachineAccount | null; accounts: MachineAccount[] } | null {
  if (!isRecord(value)) return null
  const accounts: MachineAccount[] = []
  if (Array.isArray(value.accounts)) {
    for (const entry of value.accounts) {
      const row = readAccount(entry)
      if (row !== null) accounts.push(row)
    }
  }
  return { current: readAccount(value.current), accounts }
}

/**
 * The far session's login and the far machine's list.
 *
 * `machineId` null — a session on this computer — is the off switch, and it
 * answers `loaded: false` with nothing in it. The local chip has its own
 * sources and must not be handed these.
 */
export function useMachineAccount(machineId: string | null, sessionId: string | null): MachineAccountState {
  const [state, setState] = useState<{ current: MachineAccount | null; accounts: MachineAccount[]; loaded: boolean }>({
    current: null,
    accounts: [],
    loaded: false,
  })
  const [tick, setTick] = useState(0)
  /*
   * Which read is the current one. Every reply checks its ticket before setting
   * state: a reload started while another is in flight would otherwise be
   * decided by whichever round trip happened to come back last, and over a relay
   * that is not the one that was asked most recently.
   */
  const ticket = useRef(0)

  useEffect(() => {
    if (machineId === null || sessionId === null) {
      setState({ current: null, accounts: [], loaded: false })
      return
    }
    const host = bridge()
    const read = host?.readMachineAccount
    if (typeof read !== 'function') {
      // No channel in this build. Loaded, and empty — which draws a chip with
      // nothing to pick, which is the honest outcome: this build cannot switch
      // an account over there either.
      setState({ current: null, accounts: [], loaded: true })
      return
    }
    const mine = ++ticket.current
    void read
      .call(host, machineId, sessionId)
      .then((answer) => {
        if (ticket.current !== mine) return
        const parsed = readAccountState(answer)
        /*
         * A read that could not be made leaves the previous values alone, which
         * is what the control chips beside it do. Blanking the chip because one
         * round trip over a relay went missing would empty a menu that had rows
         * in it a moment ago — a regression in honesty, not an improvement.
         */
        if (parsed === null) {
          setState((was) => ({ ...was, loaded: true }))
          return
        }
        setState({ current: parsed.current, accounts: parsed.accounts, loaded: true })
      })
      .catch(() => {
        if (ticket.current === mine) setState((was) => ({ ...was, loaded: true }))
      })
  }, [machineId, sessionId, tick])

  useEffect(
    () => () => {
      // Anything still in flight is answering a question nobody is asking.
      ticket.current += 1
    },
    [],
  )

  const reload = useCallback(() => setTick((n) => n + 1), [])
  return { current: state.current, accounts: state.accounts, loaded: state.loaded, reload }
}

/**
 * Run a session on another machine as one of that machine's other logins.
 *
 * Always answers with a sentence and with the id the session has afterwards —
 * the same one on a refusal, a new one on a success — because a switch replaces
 * the process over there. A caller that ignored the id would leave the window
 * attached to a pty that has already been killed.
 */
export async function switchMachineAccount(
  machineId: string,
  sessionId: string,
  accountId: string,
): Promise<{ ok: boolean; message: string; session: string | null }> {
  const host = bridge()
  const call = host?.switchMachineAccount
  if (typeof call !== 'function') {
    return { ok: false, message: 'This build has no way to change that session’s account.', session: null }
  }
  const answer = await call.call(host, machineId, sessionId, accountId)
  if (!isRecord(answer)) {
    return { ok: false, message: 'That machine did not answer.', session: null }
  }
  return {
    ok: answer.ok === true,
    message: typeof answer.message === 'string' ? answer.message : '',
    session: typeof answer.session === 'string' && answer.session !== '' ? answer.session : null,
  }
}
