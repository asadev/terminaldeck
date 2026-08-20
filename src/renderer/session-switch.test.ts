import { describe, expect, it } from 'vitest'
import type { SignInView } from './accounts'
import {
  readSwitchPlan,
  switchConversationNote,
  switchConversationTag,
  switchNames,
  switchProblem,
  SWITCH_KEEPS,
  type SwitchPlanView,
} from './session-switch'

const names = { from: 'work@example.com', to: 'home@example.com' }

const payload = (over: Record<string, unknown> = {}): Record<string, unknown> => ({
  sessionId: 's1',
  refusal: null,
  from: { id: 'work', name: 'Work', provider: 'claude' },
  to: { id: 'home', name: 'Home', provider: 'claude' },
  conversation: 'stays',
  resume: false,
  ...over,
})

describe('reading the plan off the bridge', () => {
  it('narrows a well-formed answer', () => {
    expect(readSwitchPlan(payload())).toEqual({
      sessionId: 's1',
      refusal: null,
      from: { id: 'work', name: 'Work', provider: 'claude' },
      to: { id: 'home', name: 'Home', provider: 'claude' },
      conversation: 'stays',
      resume: false,
    })
  })

  it('keeps a refusal as the sentence the main process wrote', () => {
    const read = readSwitchPlan(payload({ refusal: 'A plain shell has no account to sign in to.' }))
    expect(read?.refusal).toBe('A plain shell has no account to sign in to.')
  })

  /**
   * The distinction a `?? null` would have thrown away.
   *
   * `null` is a main process that looked and found nothing wrong. A *missing*
   * field is a main process that was never asked the question — an older build,
   * a payload from somewhere else — and reading the second as the first would
   * put a Switch button in front of somebody on the strength of a message that
   * never contained an answer.
   */
  it('refuses a payload with no refusal field at all', () => {
    const raw = payload()
    delete raw.refusal
    expect(readSwitchPlan(raw)).toBeNull()
  })

  it('refuses a payload with no session, or an unknown conversation', () => {
    expect(readSwitchPlan(payload({ sessionId: '' }))).toBeNull()
    expect(readSwitchPlan(payload({ conversation: 'whatever' }))).toBeNull()
    expect(readSwitchPlan(null)).toBeNull()
    expect(readSwitchPlan('nope')).toBeNull()
  })

  it('never reads a missing resume flag as a promise to continue', () => {
    const raw = payload({ conversation: 'theirs' })
    delete raw.resume
    expect(readSwitchPlan(raw)?.resume).toBe(false)
  })

  it('drops an account that is not one rather than half-reading it', () => {
    expect(readSwitchPlan(payload({ to: { name: 'Home' } }))?.to).toBeNull()
    expect(readSwitchPlan(payload({ from: 7 }))?.from).toBeNull()
  })
})

describe('the sentence somebody reads before anything stops', () => {
  const note = (conversation: SwitchPlanView['conversation']): string =>
    switchConversationNote({ conversation }, names)

  it('always says where the conversation on screen goes, first', () => {
    for (const kind of ['stays', 'theirs', 'taken', 'unreadable', 'none'] as const) {
      expect(note(kind).startsWith(`This conversation stays with ${names.from}.`)).toBe(true)
    }
  })

  /**
   * The most surprising thing a switch can do, said outright.
   *
   * `--continue` re-reads the newest conversation in the folder *of the store it
   * is pointed at*, and under the other account that is the other account's own
   * conversation — a different one from the one on screen. Discovering that
   * afterwards is indistinguishable from a bug, so the sentence has to name it
   * before the button is pressed.
   */
  it('says plainly when a different conversation is what will be continued', () => {
    expect(note('theirs')).toContain('not the one on screen now')
    expect(note('theirs')).toContain(names.to)
  })

  it('distinguishes “nothing there” from “another tab has it”', () => {
    expect(note('stays')).toContain('no conversation in this folder')
    expect(note('taken')).toContain('another tab is already')
  })

  it('says the store could not be read rather than that it was empty', () => {
    expect(note('unreadable')).toContain('cannot read')
    expect(note('unreadable')).toContain('will say for itself')
  })

  it('never promises that the conversation comes with you', () => {
    /*
     * The one claim that would be false in every case. A transcript lives under
     * the account's own config directory — measured, see the top of
     * `main/session-switch.ts` — so no wording here may imply it travels.
     */
    for (const kind of ['stays', 'theirs', 'taken', 'unreadable', 'none'] as const) {
      expect(note(kind)).not.toMatch(/carr(y|ies|ied) over|where you left off|picks? up/i)
    }
  })

  it('says what does survive, separately from what does not', () => {
    // Merged into one paragraph, the cost sits in the middle of a reassurance
    // and gets read past.
    expect(SWITCH_KEEPS).toContain('Same tab, same folder')
    expect(SWITCH_KEEPS).toContain('has not written to disk')
  })
})

describe('a failure reaches the person as a sentence', () => {
  it('takes the message out of Electron’s invoke wrapper', () => {
    /*
     * The failure shape on record from this app, one channel over:
     *
     *   Error invoking remote method 'profiles:rename': ProfileError: …
     *
     * The prefix names a channel nobody using this app has heard of. What has to
     * reach the person is the sentence the main process wrote for them.
     */
    const problem = switchProblem(
      new Error(
        `Error invoking remote method 'session:switch-account': Error: Claude Code could not be found on this machine, so this session was not started.`,
      ),
    )
    expect(problem).toBe(
      'Claude Code could not be found on this machine, so this session was not started.',
    )
    expect(problem).not.toContain('invoking remote method')
  })

  it('passes a bare message straight through', () => {
    expect(switchProblem(new Error('That account is not on this machine any more.'))).toBe(
      'That account is not on this machine any more.',
    )
  })

  it('never leaves the sheet with nothing to say', () => {
    expect(switchProblem(new Error(''))).toBe('The account could not be switched.')
    expect(switchProblem(undefined)).toBe('undefined')
  })
})

describe('what the two accounts are called', () => {
  const signedIn = (address: string): SignInView => ({
    state: 'signed-in',
    account: address,
    plan: 'max',
    detail: `Signed in as ${address}.`,
    command: 'claude auth status --json',
  })

  const plan = {
    from: { id: 'system', name: 'Default', provider: 'claude' },
    to: { id: 'home', name: 'Home', provider: 'claude' },
  }

  it('uses the address the agent’s own CLI reported', () => {
    expect(
      switchNames(plan, {
        system: signedIn('work@example.com'),
        home: signedIn('home@example.com'),
      }),
    ).toEqual({ from: 'work@example.com', to: 'home@example.com' })
  })

  /**
   * The reported bug, in the one place it would cost most.
   *
   * "Default" is the internal key the main process generates for the machine's
   * own install — the same word for every user and for every agent — and it was
   * the whole of *"it is still showing selected account as Default and not
   * showing the email ID"*. Putting it in the title of a dialog that stops a
   * running agent is that bug with the volume turned up.
   */
  it('never prints the generated slug, even before any address is known', () => {
    const names = switchNames(plan, {})
    expect(names.from).not.toBe('Default')
    expect(names.from).toContain('Claude Code')
    // A name somebody chose is an identity and survives.
    expect(names.to).toBe('Home')
  })

  it('says something true when there is no account to name', () => {
    // A session with no account of its own — a shell, or an agent whose login
    // this app cannot isolate — still has to produce a readable sentence.
    const names = switchNames({ from: null, to: null }, {})
    expect(names.from).toBe('the account it is on')
    expect(names.to).toBe('another account')
  })
})

/* ------------------------------------------------- and what the sheet shows -- */

/**
 * The sentence stays reachable; what the sheet *draws* is two words.
 *
 *   > *"See again here you have a very long description… remove this full shit.
 *   > I don't want any kind of long descriptions anywhere. Just if somewhere
 *   > it's very required, give the i icon like other ones."*
 *
 * The paragraph was moved behind the ⓘ once and half the job was done: the
 * sheet drew it whenever `conversation !== 'follows'`, which is precisely the
 * case where something is about to be left behind. So the clean sheet was the
 * one where nothing was at stake and the three-line block came back for the one
 * where something was — the habit he named, a sentence written wherever
 * something is refused.
 */
describe('the state the sheet draws instead of the sentence', () => {
  it('says nothing at all when the conversation comes with you', () => {
    // The ordinary outcome. A tag saying everything is fine is the statement he
    // asked to be rid of, printed on every switch this app makes.
    expect(switchConversationTag({ conversation: 'follows' })).toBeNull()
  })

  it('is two words wherever there is one', () => {
    for (const kind of ['stays', 'theirs', 'taken', 'unreadable', 'none'] as const) {
      const tag = switchConversationTag({ conversation: kind })
      expect(tag, kind).not.toBeNull()
      expect(tag!.split(' '), kind).toHaveLength(2)
      // Shorter than the buttons under it, and never a sentence.
      expect(tag!, kind).not.toMatch(/[.,]/)
    }
  })

  it('separates the one outcome that puts a different conversation on screen', () => {
    // `theirs` is the surprising one: the replacement picks up the *other*
    // account's conversation in this folder. Three reasons collapse to "new
    // conversation" because they have one consequence; this one does not.
    expect(switchConversationTag({ conversation: 'theirs' })).toBe('their conversation')
    for (const kind of ['stays', 'taken', 'none'] as const) {
      expect(switchConversationTag({ conversation: kind })).toBe('new conversation')
    }
    expect(switchConversationTag({ conversation: 'unreadable' })).toBe('conversation unknown')
  })
})
