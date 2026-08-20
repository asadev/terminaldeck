import { useCallback, useState } from 'react'
import type { SessionMeta } from '@shared/types'
import { profileLoginLabel, type SignInView } from './accounts'
import { isProviderId } from './preferences'

/**
 * Running the session you already have as a different account — the window's
 * half.
 *
 * `main/session-switch.ts` owns the facts: whether the switch can happen at all,
 * what the target account's transcript store actually holds, and whether the
 * replacement process gets the agent's continue flag. This owns the *words*,
 * for the reason every naming decision in this app already lives on this side:
 * what an account is called is a ladder — the address its own CLI reported, then
 * a name a person chose, then the state that was read — and that ladder is
 * `accounts.ts`, here, once. A second one in the main process would be a second
 * answer to "what do we call this login", and the two would disagree in the one
 * sentence where being wrong is worst.
 *
 * ## What the sentences have to do
 *
 * Say what will happen, before it happens. That is the whole requirement, and
 * it comes straight out of the complaint:
 *
 *   > *"when I change account from the dropdown it starts a new session with
 *   > that account, instead of changing it in the same session."*
 *
 * A restart nobody expected is the fault. A restart somebody read a description
 * of and agreed to is not. So every sentence below is written to be read *first*
 * — in a sheet, over the session it is about, with a Cancel beside it — and none
 * of them may soften what is being given up.
 *
 * The hard one is the conversation, because the honest answer is "it does not
 * come with you". A Claude Code transcript is written under the *account's*
 * config directory, so changing account changes which directory the CLI reads.
 * That was measured on this machine rather than reasoned about; the evidence,
 * with the commands and their output, is at the top of `main/session-switch.ts`.
 * Nothing here may imply otherwise, and in particular nothing here may say
 * "continues where you left off" about a switch that is going to open a
 * different conversation belonging to the other account.
 */

/* ------------------------------------------------------------------ model -- */

/** Mirror of `SwitchConversation` in `main/session-switch.ts`. */
export type SwitchConversation = 'follows' | 'stays' | 'theirs' | 'taken' | 'unreadable' | 'none'

const CONVERSATIONS: readonly SwitchConversation[] = [
  'follows',
  'stays',
  'theirs',
  'taken',
  'unreadable',
  'none',
]

/** Mirror of `SwitchAccount`. `provider` is a string here; the picker narrows it. */
export interface SwitchAccountView {
  id: string
  name: string
  provider: string
}

export interface SwitchPlanView {
  sessionId: string
  /** Why it cannot happen, already written for a person. Null when it can. */
  refusal: string | null
  from: SwitchAccountView | null
  to: SwitchAccountView | null
  conversation: SwitchConversation
  resume: boolean
}

function account(raw: unknown): SwitchAccountView | null {
  if (typeof raw !== 'object' || raw === null) return null
  const row = raw as Record<string, unknown>
  if (typeof row.id !== 'string' || row.id === '') return null
  if (typeof row.name !== 'string') return null
  return { id: row.id, name: row.name, provider: typeof row.provider === 'string' ? row.provider : '' }
}

/**
 * Read the answer from `session:switch-plan`.
 *
 * Narrowed rather than cast, like every other payload that crosses the bridge:
 * a build whose main process is older answers with a shape this does not know,
 * and the difference between narrowing and casting is whether that shows up as
 * "the switch is not available in this build" or as a sheet with `undefined`
 * printed in the middle of a sentence.
 *
 * A payload with no `refusal` field at all is refused rather than read as "no
 * objection". Absent is not the same as null here: null is a main process that
 * looked and found nothing wrong, and absent is a main process that was never
 * asked the question — and treating the second as the first would put a Switch
 * button in front of somebody on the strength of a message that never contained
 * an answer.
 */
export function readSwitchPlan(raw: unknown): SwitchPlanView | null {
  if (typeof raw !== 'object' || raw === null) return null
  const row = raw as Record<string, unknown>
  if (typeof row.sessionId !== 'string' || row.sessionId === '') return null
  if (!('refusal' in row)) return null
  const refusal =
    typeof row.refusal === 'string' && row.refusal !== ''
      ? row.refusal
      : row.refusal === null
        ? null
        : undefined
  if (refusal === undefined) return null
  const conversation = CONVERSATIONS.find((kind) => kind === row.conversation)
  if (conversation === undefined) return null
  return {
    sessionId: row.sessionId,
    refusal,
    from: account(row.from),
    to: account(row.to),
    conversation,
    // Only ever true when main said true. A missing field is "no", which is the
    // reading that cannot promise a continue that is not going to happen.
    resume: row.resume === true,
  }
}

/* ------------------------------------------------------------------ words -- */

/** What the sheet needs to call the two accounts, off the identity ladder. */
export interface SwitchNames {
  /** The account the session is on now. */
  from: string
  /** The account it would move to. */
  to: string
}

/**
 * What to call the two accounts in the sheet.
 *
 * `profileLoginLabel` and nothing else, because that is the ladder every other
 * surface in this window already climbs: the address the agent's own CLI
 * reported, then a name a person chose, then "your own Claude Code install" for
 * an install nobody has named. The one thing it never prints is the stored slug,
 * and the slug is exactly what a naive `plan.to.name` would put here — `Default`,
 * the internal key that is the same word for every user and for every agent's own
 * install. Putting it in the *title* of a dialog that stops a running agent would
 * be the reported "it just says Default" bug in the one place it costs most.
 *
 * `known` is the answers the account menu has already paid for —
 * `useKnownSignIns`, a plain read of a store, no probe. The menu asks about every
 * account the moment it opens, and the only way to reach this sheet is through
 * that menu, so by the time it is on screen the addresses are in hand. When they
 * are not, the ladder falls back on its own and says something true rather than
 * waiting.
 *
 * The fallbacks are deliberately different words. A missing *target* would leave
 * the title reading "Run this session as ?", so it says "another account"; a
 * missing *source* is an ordinary state — a shell, an agent whose login this app
 * cannot isolate — where "the account it is on" is the honest phrase.
 */
export function switchNames(
  plan: Pick<SwitchPlanView, 'from' | 'to'>,
  known: Readonly<Record<string, SignInView>>,
): SwitchNames {
  const label = (row: SwitchAccountView | null, fallback: string): string =>
    row === null
      ? fallback
      : profileLoginLabel(
          { id: row.id, name: row.name, provider: isProviderId(row.provider) ? row.provider : null },
          known[row.id],
        )
  return {
    from: label(plan.from, 'the account it is on'),
    to: label(plan.to, 'another account'),
  }
}

/**
 * The one sentence that must be read before anything is stopped.
 *
 * Five outcomes and five sentences, because collapsing any two of them loses the
 * thing the reader needs. In particular `stays` and `theirs` differ by which
 * conversation is on screen afterwards, which is the single most surprising
 * thing a switch can do, and a shared sentence would have to be vague about
 * exactly that.
 *
 * Every one of them opens with where the current conversation goes, in the same
 * words, because that is the question somebody actually has and it has the same
 * answer in all five cases: it stays with the account it is on. It is not
 * deleted and it is not lost — switching back finds it — and saying so is what
 * makes the rest of the sentence something a person can weigh rather than fear.
 */
export function switchConversationNote(
  plan: Pick<SwitchPlanView, 'conversation'>,
  names: SwitchNames,
): string {
  const stays = `This conversation stays with ${names.from}.`
  switch (plan.conversation) {
    case 'follows':
      /*
       * The one outcome where the opening clause would be a lie, so it is not
       * used. These two accounts share one conversation history — Option C, and
       * `shared-projects.ts` is where it is turned on — which means the file the
       * replacement continues is the file this session is writing. Nothing stays
       * behind because nothing is left behind.
       */
      return (
        `This conversation comes with you. ${names.to} shares the same conversation history, so the ` +
        `session picks up exactly where it is now — same conversation, new account.`
      )
    case 'theirs':
      return (
        `${stays} ${names.to} has its own conversation in this folder and that is the one that ` +
        `will be continued here — not the one on screen now.`
      )
    case 'taken':
      return (
        `${stays} ${names.to} has a conversation in this folder, but another tab is already ` +
        `showing it, so this starts a new one instead.`
      )
    case 'unreadable':
      return (
        `${stays} This app cannot read where ${names.to} keeps its history, so the agent is asked ` +
        `to continue and will say for itself in the terminal whether it found anything.`
      )
    case 'none':
      return `${stays} This agent has no way to continue an earlier conversation, so ${names.to} starts fresh.`
    default:
      return `${stays} ${names.to} has no conversation in this folder, so it starts a new one.`
  }
}

/**
 * The same five outcomes as two words, for the sheet to *show*.
 *
 * `switchConversationNote` above is a sentence, and a sentence is what he
 * banned from this screen:
 *
 *   > *"See again here you have a very long description… remove this full shit.
 *   > I don't want any kind of long descriptions anywhere. Just if somewhere
 *   > it's very required, give the i icon like other ones."*
 *
 * The sentence was moved behind the ⓘ once and half the job was done: the case
 * that draws it is `conversation !== 'follows'`, which is precisely the case
 * where the conversation is *not* coming with him — so the clean sheet was the
 * one where nothing was at stake and the paragraph came back for the one that
 * mattered. This is what the sheet shows instead: a state, beside the arrow,
 * shorter than the buttons under it. The sentence is not deleted — it is what
 * the ⓘ on the same line now carries.
 *
 * Null for `follows`, and that is not an omission. The conversation coming with
 * you is the ordinary outcome, and a tag saying so would be the statement he
 * asked to be rid of, printed on every switch this app makes.
 *
 * `taken`, `none` and `stays` collapse to one word deliberately: three
 * different reasons, one consequence — the session on screen afterwards is on a
 * conversation that did not exist a moment ago. The reason is in the ⓘ, where a
 * reason belongs.
 */
export function switchConversationTag(plan: Pick<SwitchPlanView, 'conversation'>): string | null {
  switch (plan.conversation) {
    case 'follows':
      return null
    case 'theirs':
      return 'their conversation'
    case 'unreadable':
      return 'conversation unknown'
    default:
      return 'new conversation'
  }
}

/**
 * What the switch does to everything that is not the conversation.
 *
 * Kept apart from the sentence above because it is the half that is *reassuring*
 * and the half that is not, and running them together produces a paragraph whose
 * shape hides the cost in the middle. This one is fixed text: the tab, the
 * folder and the place in the strip genuinely do not change, and that is the
 * entire difference between this and what the menu used to do.
 */
export const SWITCH_KEEPS =
  'Same tab, same folder, same place on the bar. The agent running in it is stopped and started again as the other account, so anything it has not written to disk goes with it.'

/* ----------------------------------------------------------------- bridge -- */

export interface SwitchBridge {
  planSessionSwitch(sessionId: string, profileId: string): Promise<unknown>
  switchSessionAccount(sessionId: string, profileId: string): Promise<SessionMeta>
  /**
   * Arm the same switch for his next message instead of doing it now.
   *
   * Optional, and the whole controller must keep working without it: a build
   * whose preload predates this answers `undefined` here, and the sheet then
   * offers the immediate switch alone rather than disabling itself. That is why
   * `bridge()` below does not test for it — requiring it would turn a missing
   * *extra* into "switching accounts is not wired into this build", which is
   * the failure shape this file already carries a comment about.
   */
  switchSessionAccountLater?(sessionId: string, profileId: string): Promise<unknown>
}

function bridge(): SwitchBridge | null {
  const deck = (globalThis as { deck?: Partial<SwitchBridge> }).deck
  if (!deck || typeof deck.planSessionSwitch !== 'function') return null
  if (typeof deck.switchSessionAccount !== 'function') return null
  return deck as SwitchBridge
}

/**
 * The sheet's state: which switch is being asked about, what it would do, and
 * what went wrong if it did.
 *
 * A hook rather than four `useState`s in `App.tsx`, because these four move
 * together and the ways they can be inconsistent are all bugs somebody would
 * see: a plan for a session that is no longer the one being asked about, a
 * "Switching…" that never clears, an old failure still on screen under a new
 * question. Keeping them in one reducer-ish place is what makes "opening the
 * sheet clears the last answer" one line rather than a rule four call sites have
 * to remember.
 */
export interface SwitchRequest {
  sessionId: string
  profileId: string
}

export interface SwitchController {
  /** The switch being asked about, or null when the sheet is shut. */
  asking: SwitchRequest | null
  /** What it would do. Null while the answer is still being fetched. */
  plan: SwitchPlanView | null
  /** True while the plan is being fetched, or while the switch is running. */
  busy: boolean
  /** What went wrong, from the main process, in its own words. */
  problem: string | null
  ask(request: SwitchRequest): void
  cancel(): void
  /** Do it. Resolves with the replacement session, or null if it did not happen. */
  confirm(): Promise<SessionMeta | null>
  /**
   * Whether this build can defer a switch at all.
   *
   * Read from the bridge rather than assumed, so the second button is absent on
   * a build whose preload predates it instead of present and inert.
   */
  canDefer: boolean
  /**
   * Arm it for his next message and shut the sheet.
   *
   * Resolves `true` when the main process took it. Nothing is stopped and
   * nothing has started, so there is no session to hand back — the replacement
   * arrives later, through `onSessionSwitched`, whenever he next sends
   * something.
   */
  defer(): Promise<boolean>
  /**
   * Put a failure that happened without anybody asking in front of the person.
   *
   * The one caller is the deferred switch: it fires inside a keystroke, minutes
   * after the sheet was shut, so a rejection there has no promise to reject and
   * no dialog to land in. Called straight after `ask`, which is what fills the
   * sheet in with the two account names — this only adds the reason, and does
   * not touch the plan, because the plan is still the true description of what
   * *would* have happened.
   */
  report(problem: string): void
}

/**
 * Turn a rejected `invoke` back into the sentence inside it.
 *
 * Electron wraps a main-process throw as `Error invoking remote method
 * 'session:switch-account': Error: …`, and that prefix names a channel nobody
 * using this app has heard of. The same unwrapping `accounts.ts` does for
 * renames, for the same reason: what has to reach the person is the sentence the
 * main process wrote for them, and nothing else on the line.
 */
export function switchProblem(error: unknown): string {
  const raw = error instanceof Error ? error.message : String(error)
  const at = raw.lastIndexOf('Error: ')
  const message = at >= 0 ? raw.slice(at + 'Error: '.length) : raw
  return message.trim() === '' ? 'The account could not be switched.' : message.trim()
}

export function useSwitchAccount(injected?: SwitchBridge | null): SwitchController {
  const [deck] = useState<SwitchBridge | null>(() => injected ?? bridge())
  const [asking, setAsking] = useState<SwitchRequest | null>(null)
  const [plan, setPlan] = useState<SwitchPlanView | null>(null)
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)

  const ask = useCallback(
    (request: SwitchRequest) => {
      setAsking(request)
      setPlan(null)
      setProblem(null)
      if (!deck) {
        // A build whose bridge predates this feature. Said out loud rather than
        // left as a sheet that spins: a control that cannot answer has to say so.
        setProblem('Switching accounts is not wired into this build.')
        return
      }
      setBusy(true)
      void deck.planSessionSwitch(request.sessionId, request.profileId).then(
        (raw) => {
          setBusy(false)
          const read = readSwitchPlan(raw)
          if (read === null) setProblem('This build could not work out what switching would do.')
          // Answers for a question that has since been cancelled or replaced are
          // dropped. Two rapid picks would otherwise leave the second sheet
          // describing the first account.
          else setPlan((current) => (current === null ? read : current))
        },
        (error: unknown) => {
          setBusy(false)
          setProblem(switchProblem(error))
        },
      )
    },
    [deck],
  )

  const cancel = useCallback(() => {
    setAsking(null)
    setPlan(null)
    setProblem(null)
    setBusy(false)
  }, [])

  const confirm = useCallback(async (): Promise<SessionMeta | null> => {
    if (!deck || asking === null || plan === null || plan.refusal !== null) return null
    setBusy(true)
    setProblem(null)
    try {
      const meta = await deck.switchSessionAccount(asking.sessionId, asking.profileId)
      setAsking(null)
      setPlan(null)
      return meta
    } catch (error) {
      /*
       * The sheet stays open, holding the reason.
       *
       * A failed switch has left the session it was asked about running — the
       * main process starts the replacement before it stops anything — so there
       * is nothing to recover and everything to explain. Closing the sheet here
       * would put the person back in front of an unchanged session with no
       * account of why it is unchanged, which is the silent no-op this whole
       * chip has already been reported for once.
       */
      setProblem(switchProblem(error))
      return null
    } finally {
      setBusy(false)
    }
  }, [asking, deck, plan])

  /**
   * Arm the switch instead of making it.
   *
   * The sheet is shut on success, because there is nothing left to watch: the
   * session carries on exactly as it was and the only visible change is the
   * hint on the chip. On failure it stays open holding the reason, for the same
   * reason `confirm` does — an armed switch that was refused and a sheet that
   * closed anyway is a person believing something is going to happen that is
   * not.
   */
  const defer = useCallback(async (): Promise<boolean> => {
    const later = deck?.switchSessionAccountLater
    if (!deck || !later || asking === null || plan === null || plan.refusal !== null) return false
    setBusy(true)
    setProblem(null)
    try {
      await later.call(deck, asking.sessionId, asking.profileId)
      setAsking(null)
      setPlan(null)
      return true
    } catch (error) {
      setProblem(switchProblem(error))
      return false
    } finally {
      setBusy(false)
    }
  }, [asking, deck, plan])

  return {
    asking,
    plan,
    busy,
    problem,
    ask,
    cancel,
    confirm,
    canDefer: typeof deck?.switchSessionAccountLater === 'function',
    defer,
    report: setProblem,
  }
}
