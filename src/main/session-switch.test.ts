import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { ProviderId, SessionMeta } from '../shared/types'
import type { Profile } from './profiles'
import type { RestoreDecision, SavedSession } from './session-restore'
import {
  conversationToCarry,
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
    // Separate stores unless a case says otherwise. That is what every case
    // below was written against, and it is still the truth for two accounts
    // that have not been pointed at one shared conversation history.
    sharedStore: false,
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
    // The subject moved out of `index.ts` on 2026-08-22 so the headless build
    // could hand the same switch to its core — the pinned ordering moved with
    // it, and this reads the module both shells now share.
    const handler = readFileSync(join(__dirname, 'session-switch-run.ts'), 'utf8')
    const subject = handler.slice(handler.indexOf('const subject = async'))
    const body = subject.slice(0, subject.indexOf('const perform = async'))
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

describe('a shared conversation history changes what may be said, not what happens', () => {
  it('says the conversation follows when both accounts read one store', () => {
    /*
     * Option C from `ACCOUNT-MODEL.md`, and the reason it was recommended: with
     * both accounts' `projects/` linked into one place, the file the replacement
     * continues is the file this session is writing. `theirs` here would tell
     * somebody the conversation on screen stays behind and another one takes its
     * place, which is exactly false and is the sentence they decide on.
     */
    const answer = plan({ sharedStore: true })
    expect(answer.conversation).toBe('follows')
    expect(answer.resume).toBe(true)
  })

  it('still admits it cannot read a store it cannot read', () => {
    // `unreadable` outranks both: the app did not see the store at all, so it
    // has no business claiming the conversation comes across.
    expect(
      plan({ sharedStore: true, decision: decision({ conversation: 'unknown' }) }).conversation,
    ).toBe('unreadable')
  })

  it('does not claim a shared store when another tab holds the conversation', () => {
    // Occupancy is decided first and for a different reason: two terminals on
    // one transcript fork it silently, whoever owns the two accounts.
    expect(plan({ sharedStore: true, occupied: true }).conversation).toBe('taken')
  })
})

/**
 * Naming the conversation instead of describing it.
 *
 * `--continue` means "the folder's most recent", and the sheet promises
 * something narrower — the conversation *on screen*. Every condition below is a
 * way of not saying more than is known.
 */
describe('the conversation carried across a switch', () => {
  const carrying = plan({ decision: decision({ outcome: 'resume', conversation: 'found' }), sharedStore: true })

  it('names the id when the two accounts read one history and the file is there', () => {
    expect(carrying.conversation).toBe('follows')
    expect(
      conversationToCarry({ plan: carrying, agentSessionId: 'abc', readableInTarget: true }),
    ).toBe('abc')
  })

  it('says nothing when the transcript is not readable from the other account', () => {
    // `--resume` against an id that store cannot see is a replacement that
    // prints an error and exits — worse than the folder-newest guess it
    // replaces. Falling back leaves the old behaviour exactly as it was.
    expect(
      conversationToCarry({ plan: carrying, agentSessionId: 'abc', readableInTarget: false }),
    ).toBe(null)
  })

  it('says nothing when this app never named the conversation', () => {
    // A session this app did not start, or one that resumed rather than being
    // given an id, has none to carry.
    expect(
      conversationToCarry({ plan: carrying, agentSessionId: undefined, readableInTarget: true }),
    ).toBe(null)
    expect(conversationToCarry({ plan: carrying, agentSessionId: '', readableInTarget: true })).toBe(
      null,
    )
  })

  it('says nothing when the plan is picking up the other account\'s own conversation', () => {
    // `theirs` is the deliberate separate-stores case. Naming this session's
    // conversation there would reach into a store the sheet has just said it
    // would leave alone.
    const theirs = plan({ decision: decision({ outcome: 'resume', conversation: 'found' }) })
    expect(theirs.conversation).toBe('theirs')
    expect(conversationToCarry({ plan: theirs, agentSessionId: 'abc', readableInTarget: true })).toBe(
      null,
    )
  })

  it('says nothing when nothing is being resumed at all', () => {
    const fresh = plan({ decision: decision({ outcome: 'fresh', conversation: 'none' }) })
    expect(fresh.resume).toBe(false)
    expect(conversationToCarry({ plan: fresh, agentSessionId: 'abc', readableInTarget: true })).toBe(
      null,
    )
  })
})

/* ------------------------------------------- the flag the CLI would refuse -- */

/**
 * `--resume` on a switch, and never `--session-id`.
 *
 * ## The measurement, on this Mac, 2026-08-20
 *
 * Claude Code 2.1.237, a real conversation named by this app, and a second real
 * account whose `projects/` is linked to the first's:
 *
 *     $ cd /private/tmp/td-d1/proj
 *     $ claude --session-id aa4603b5-… -p 'Remember this codeword: PINEAPPLE-7731…'
 *     noted
 *     $ CLAUDE_CONFIG_DIR=…/acct2 claude --session-id aa4603b5-… -p 'What codeword…'
 *     Error: Session ID aa4603b5-922a-4695-ab24-38a45e702bed is already in use.
 *     $ CLAUDE_CONFIG_DIR=…/imzapremium-gmail-com claude --resume aa4603b5-… -p 'What codeword…'
 *     PINEAPPLE-7731
 *
 * Same binary, same folder, same conversation, two flags: one refuses and one
 * carries the conversation into the other login. `--session-id` *declares* an
 * id and the CLI will not declare one whose transcript exists; `--resume`
 * *joins* it.
 *
 * ## Why this is asserted against the source
 *
 * `startSession` composes the argument list inline and spawns a real pty with
 * it. There is no seam to hand a spy, and the thing that refused is the CLI —
 * which a unit test cannot ask. What can be pinned is the shape of the
 * decision, and the shape is the whole of the bug: `wanted` read
 * `agentSessionId === null ? chosen : […'--session-id', agentSessionId]`, and
 * `agentSessionId` is set on **both** paths — a fresh id on one, the id being
 * resumed on the other. So the resume path built `--session-id <the id it was
 * resuming>` and threw away the `--resume` arguments that had just been chosen
 * for it. Every account switch that carried a conversation died on start with
 * an empty terminal, which is the headline complaint the whole module exists
 * for, reintroduced by the fix for it.
 *
 * `declaredId` is null on every path but the fresh one, so the branch cannot be
 * reached from a resume at all. That is what is checked here.
 */
describe('the arguments a switch actually spawns', () => {
  const source = readFileSync(join(__dirname, 'host-core.ts'), 'utf8')

  it('builds the --session-id list only from a freshly minted id', () => {
    expect(source).toContain('const declaredId = namesConversation ? randomUUID() : null')
    expect(source).toMatch(/const wanted =\s*\n\s*declaredId === null\s*\n\s*\? chosen/)
    expect(source).toContain("'--session-id', declaredId")
    // The exact expression that shipped, which put the resumed id on the flag.
    expect(source).not.toContain("'--session-id', agentSessionId")
    expect(source).not.toMatch(/const wanted =\s*\n\s*agentSessionId === null/)
  })

  it('still records the resumed conversation on the session, without declaring it', () => {
    // `SessionMeta.agentSessionId` is what every reader downstream — the
    // context-window bar above all — uses to find *this* session's transcript.
    // A resume by name knows it; it simply must not put it on `--session-id`.
    expect(source).toMatch(
      /const agentSessionId =\s*\n\s*declaredId \?\? \(named && chosen === resumeArgs/,
    )
  })
})
