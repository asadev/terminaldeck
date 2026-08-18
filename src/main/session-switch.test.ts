import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { ProviderId, SessionMeta } from '../shared/types'
import type { Profile } from './profiles'
import type { RestoreDecision, SavedSession } from './session-restore'
import {
  lastLine,
  planSwitch,
  SESSION_SWITCH_CHANNEL,
  SESSION_SWITCH_PLAN_CHANNEL,
  startFailed,
  survivedStart,
  SWITCH_GRACE_MS,
  switchRefusal,
} from './session-switch'

/**
 * Running the session you already have as a different account.
 *
 * Every case here is a rule that would be broken by an obvious simplification,
 * and most of them were reachable states of the thing this replaced — a menu
 * that answered "this session cannot change account" by opening a second
 * session in the same folder.
 */

const meta = (over: Partial<SessionMeta> = {}): SessionMeta => ({
  id: 's1',
  cwd: '/w/app',
  title: 'app',
  provider: 'claude',
  exitCode: null,
  createdAt: 1,
  profileId: 'work',
  profileName: 'Work',
  ...over,
})

const saved = (over: Partial<SavedSession> = {}): SavedSession => ({
  cwd: '/w/app',
  provider: 'claude',
  profileId: 'work',
  cols: 100,
  rows: 30,
  lastSeenAt: 1,
  ...over,
})

const profile = (over: Partial<Profile> = {}): Profile => ({
  id: 'home',
  name: 'Home',
  provider: 'claude' as ProviderId,
  configDir: '/cfg/home',
  system: false,
  color: '--status-input',
  createdAt: 0,
  lastUsedAt: null,
  ...over,
})

const decision = (over: Partial<RestoreDecision> = {}): RestoreDecision => ({
  session: saved({ profileId: 'home' }),
  outcome: 'resume',
  reason: 'continuing the conversation on disk',
  configDir: '/cfg/home',
  conversation: 'found',
  ...over,
})

const plan = (over: Parameters<typeof planSwitch>[0] | Partial<Parameters<typeof planSwitch>[0]> = {}) =>
  planSwitch({
    sessionId: 's1',
    meta: meta(),
    saved: saved(),
    target: profile(),
    decision: decision(),
    occupied: false,
    ...over,
  })

describe('the channels are named where the feature lives', () => {
  it('keeps the two questions apart', () => {
    // Separate on purpose: one describes and touches nothing, the other acts.
    // A single channel could not be asked "what would this do" without doing it.
    expect(SESSION_SWITCH_PLAN_CHANNEL).toBe('session:switch-plan')
    expect(SESSION_SWITCH_CHANNEL).toBe('session:switch-account')
    expect(SESSION_SWITCH_PLAN_CHANNEL).not.toBe(SESSION_SWITCH_CHANNEL)
  })
})

describe('what cannot be switched', () => {
  it('refuses a session that is not running', () => {
    expect(switchRefusal({ meta: null, saved: saved(), target: profile() })).toContain(
      'not running any more',
    )
  })

  it('refuses one that has already ended', () => {
    // The pty is gone. Starting a replacement would not be a switch, it would be
    // opening a new session in a tab somebody had finished with.
    const why = switchRefusal({ meta: meta({ exitCode: 0 }), saved: saved(), target: profile() })
    expect(why).toContain('already ended')
  })

  /**
   * The copilot, and a session a paired device is holding inside a folder grant.
   *
   * `host-core.ts` deliberately keeps both out of the ledger, because a
   * `SavedSession` carries a folder, an agent and an account and nothing else —
   * so restarting from one produces a plain Claude Code session with no
   * instruction layer, no `deck-control` tools and no fence, or an ordinary
   * session where a confined one used to be. Either is the app quietly turning
   * a session into something else, which is the fault this whole area was just
   * fixed for. The ledger's silence is therefore the test.
   */
  it('refuses a session the app started for itself or for a device', () => {
    const why = switchRefusal({ meta: meta(), saved: null, target: profile() })
    expect(why).toContain('Only a session you opened here')
    expect(why).toContain('copilot')
  })

  it('refuses a shell in the agent’s own words, not a generic sentence', () => {
    /*
     * `finish.test.ts` pins that a shell is never described as an agent. This is
     * the same rule at the other end of the wire: an account is a config
     * directory handed to an agent, so a session with no agent in it has nothing
     * for one to be about. The sentence is `loginsNote`'s, so the chip and this
     * refusal cannot come to say two different things about one situation.
     */
    const why = switchRefusal({
      meta: meta({ provider: 'shell', profileId: undefined, profileName: undefined }),
      saved: saved({ provider: 'shell' }),
      target: profile(),
    })
    expect(why).toBe('A plain shell has no account to sign in to.')
  })

  it('refuses an account of a different agent, and names both', () => {
    // `resolveProfileId` already declines this — quietly, by falling back to the
    // machine's own install — and the quiet version is what made picking a Codex
    // account look like the app ignoring the click.
    const why = switchRefusal({
      meta: meta(),
      saved: saved(),
      target: profile({ id: 'chat', name: 'Chat', provider: 'codex' }),
    })
    expect(why).toContain('Codex CLI')
    expect(why).toContain('Claude Code')
  })

  it('refuses the account it is already running as', () => {
    const why = switchRefusal({
      meta: meta({ profileId: 'home' }),
      saved: saved(),
      target: profile({ id: 'home' }),
    })
    expect(why).toContain('already running as that account')
  })

  it('accepts another account of the same agent', () => {
    expect(switchRefusal({ meta: meta(), saved: saved(), target: profile() })).toBeNull()
  })

  it('refuses an account that is no longer on this machine', () => {
    expect(switchRefusal({ meta: meta(), saved: saved(), target: null })).toContain(
      'not on this machine',
    )
  })
})

describe('a refusal is the whole plan', () => {
  it('carries the sentence and promises nothing about the conversation', () => {
    const answer = plan({ target: null })
    expect(answer.refusal).not.toBeNull()
    expect(answer.resume).toBe(false)
    expect(answer.to).toBeNull()
  })

  it('still names the account the session is on, so the sheet can say so', () => {
    // The refusal explains why it cannot move; the reader still has to be able
    // to see what it is currently.
    expect(plan({ target: null }).from).toEqual({ id: 'work', name: 'Work', provider: 'claude' })
  })

  it('is reached before any disk question is asked', () => {
    // `decision: null` is what the handler passes on its first, cheap pass. A
    // refusal has to survive it rather than being turned into "nothing could be
    // decided", which would replace a precise sentence with a vague one.
    expect(plan({ target: null, decision: null }).refusal).toContain('not on this machine')
  })
})

describe('what happens to the conversation', () => {
  it('continues the target account’s own conversation when there is one', () => {
    const answer = plan()
    expect(answer.refusal).toBeNull()
    expect(answer.conversation).toBe('theirs')
    expect(answer.resume).toBe(true)
  })

  it('starts fresh when the target account has never worked in this folder', () => {
    const answer = plan({
      decision: decision({
        outcome: 'fresh',
        reason: 'no earlier conversation was found on disk for this folder',
        conversation: 'none',
      }),
    })
    expect(answer.conversation).toBe('stays')
    expect(answer.resume).toBe(false)
  })

  /**
   * The distinction this feature needed a new field on `RestoreDecision` for.
   *
   * "The store holds nothing" and "this app cannot read the store" both produce
   * a sentence about starting fresh if they are collapsed, and they are not the
   * same thing: the second is Codex, or any session inside WSL, where the CLI is
   * asked to continue and answers for itself. Sniffing the reason string would
   * have worked and would have broken silently the first time somebody improved
   * the wording.
   */
  it('says the store could not be read, rather than that it was empty', () => {
    const answer = plan({ decision: decision({ conversation: 'unknown' }) })
    expect(answer.conversation).toBe('unreadable')
    expect(answer.resume).toBe(true)
  })

  it('never claims a continue for an agent that has no way to continue', () => {
    // `planRestore` leaves `conversation` unset exactly when it never reached
    // the disk, which is this case and only this case for a single session.
    const answer = plan({
      decision: {
        session: saved(),
        outcome: 'fresh',
        reason: 'this agent has no way to continue a previous conversation',
      },
    })
    expect(answer.conversation).toBe('none')
    expect(answer.resume).toBe(false)
  })

  /**
   * One terminal per transcript.
   *
   * `planRestore` enforces this across a list of sessions being restored
   * together and cannot see the tabs open right now, so the live half is asked
   * separately and applied here. Without it, switching into a conversation
   * another tab is already showing would put one conversation on screen twice
   * and let two agents append to one file.
   */
  it('will not join a conversation another tab is already on', () => {
    const answer = plan({ occupied: true })
    expect(answer.conversation).toBe('taken')
    expect(answer.resume).toBe(false)
  })

  it('refuses outright when the folder itself has gone', () => {
    const answer = plan({
      decision: {
        session: saved(),
        outcome: 'skip',
        reason: 'the folder it ran in is no longer on this machine',
      },
    })
    expect(answer.refusal).toContain('no longer on this machine')
    expect(answer.resume).toBe(false)
  })

  it('refuses rather than guessing when nothing could be decided', () => {
    // Absent is not "start it fresh". A plan that produced no decision has not
    // established that a clean start is safe; it has established nothing.
    const answer = plan({ decision: null })
    expect(answer.refusal).not.toBeNull()
    expect(answer.resume).toBe(false)
  })
})

describe('the two passes the handler makes', () => {
  /**
   * Found by driving the built app, and it is the reason `switchRefusal` exists
   * as a function of its own rather than as the first half of `planSwitch`.
   *
   * The handler asks a cheap question first — is there anything about this
   * session, this account or this agent that rules the switch out before a disk
   * is touched — and then, only if not, pays for the plan. Asking that first
   * question through `planSwitch` looks right and is not: with no decision to
   * hand it, `planSwitch` refuses, deliberately, because "nothing was decided"
   * is not "start it fresh". So every switch that was going to work perfectly
   * well came back as *"This session cannot be started again: nothing could be
   * decided about it"* — a confident, wrong sentence in a sheet whose whole job
   * is being accurate before something irreversible happens.
   *
   * It typechecked, every unit test passed, and it was visible in the first
   * screenshot.
   */
  it('asks the cheap question with switchRefusal, never with planSwitch', () => {
    const handler = readFileSync(join(__dirname, 'index.ts'), 'utf8')
    const subject = handler.slice(handler.indexOf('const switchSubject = async'))
    const body = subject.slice(0, subject.indexOf('ipcMain.handle(SESSION_SWITCH_PLAN_CHANNEL'))
    expect(body).toContain('switchRefusal({ meta, saved, target })')
    // And the plan is asked for exactly once afterwards, with a real decision.
    expect(body).toContain('await planSaved([switched])')
  })
})

/**
 * The replacement that started and then refused.
 *
 * Reproduced on this machine on 2026-08-17, and it is the reason the old session
 * is not stopped the instant the new one is spawned. A conversation created by
 * `claude -p` writes a perfectly good transcript under `projects/<encoded cwd>/`;
 * interactive `claude --continue` in that same folder answers **"No conversation
 * found to continue"** and exits. So the app looks, sees a conversation, plans a
 * resume, and the replacement dies a second later — and if the session it was
 * replacing had already been killed, a working agent would be gone and a dead
 * tab would be standing where it was.
 */
describe('a replacement that did not stay up', () => {
  const probe = (over: Partial<Parameters<typeof survivedStart>[1]> = {}) => {
    const waited: number[] = []
    return {
      waited,
      probe: {
        wait: async (ms: number) => {
          waited.push(ms)
        },
        alive: () => true,
        screen: () => '',
        ...over,
      },
    }
  }

  it('waits before deciding, because a refusal takes a moment to arrive', async () => {
    // Asked at once, every switch would answer "alive" — the pty exists the
    // instant it is spawned and the agent has not read its own arguments yet.
    const { waited, probe: p } = probe()
    await survivedStart('s9', p)
    expect(waited).toEqual([SWITCH_GRACE_MS])
  })

  it('says nothing is wrong when the session is still there', async () => {
    expect(await survivedStart('s9', probe().probe)).toEqual({ alive: true, said: null })
  })

  it('reports the agent’s own last words when it is not', async () => {
    const { probe: p } = probe({
      alive: () => false,
      screen: () => 'Some earlier output\r\nNo conversation found to continue\r\n\r\n',
    })
    expect(await survivedStart('s9', p)).toEqual({
      alive: false,
      said: 'No conversation found to continue',
    })
  })

  it('does not invent a reason when the process said nothing', async () => {
    const { probe: p } = probe({ alive: () => false, screen: () => '   \n\n' })
    expect((await survivedStart('s9', p)).said).toBeNull()
  })
})

describe('the last thing a process said', () => {
  it('is the last non-empty line, trimmed', () => {
    expect(lastLine('a\r\nb\r\n\r\n   \r\n')).toBe('b')
  })

  it('is cut rather than tidied to a word boundary', () => {
    // A line tidied to the last whole word reads as the complete message. One
    // with an ellipsis reads as truncated, which is what it is.
    const long = 'x'.repeat(200)
    const cut = lastLine(long, 20)
    expect(cut).toHaveLength(20)
    expect(cut?.endsWith('…')).toBe(true)
  })

  it('is null for a buffer with nothing in it', () => {
    expect(lastLine('')).toBeNull()
    expect(lastLine('\n\n  \n')).toBeNull()
  })
})

describe('what a failed switch tells the person', () => {
  it('names the account, quotes the agent, and says nothing was lost', () => {
    const message = startFailed('home@example.com', 'No conversation found to continue')
    expect(message).toContain('home@example.com started and stopped straight away')
    expect(message).toContain('“No conversation found to continue”')
    // The load-bearing half: they have just read a failure and will otherwise go
    // looking for what they lost.
    expect(message).toContain('This session is still running as it was.')
  })

  it('still says the session is safe when the agent said nothing', () => {
    const message = startFailed('home@example.com', null)
    expect(message).not.toContain('It said')
    expect(message).toContain('This session is still running as it was.')
  })
})
