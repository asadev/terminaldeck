import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ActionLog } from '../deck-control/action-log'
import { ConsentBroker, WINDOW_SURFACE, type ConsentRequest } from '../deck-control/consent'
import { DeckControl } from '../deck-control/control'
import type { DeckSurface } from '../deck-control/surface'
import { CopilotAccess, remoteCopilotCaller } from './copilot-access'
import { CopilotRuns } from './copilot-runs'
import type { CopilotConsentQuestion, CopilotSettledRow } from './protocol'
import { resetHiddenSessions } from './hidden-sessions'

/**
 * A confirmation raised by a device's own copilot run, answered on that device,
 * all the way through to the row in `actions.jsonl`.
 *
 * `server.test.ts` proves the frames reach the run manager over a real socket.
 * This proves the other half — that the answer actually decides a tool call, and
 * that the record afterwards says **where** it was decided. Those are two
 * different failures and neither test catches the other's:
 *
 *  - a device could answer and the tool run anyway, or not run;
 *  - or it could all work and the log could say *allowed by the person*, which
 *    would make "somebody at the Mac approved this" and "somebody holding a
 *    phone approved this" the same row in the one place the difference matters.
 *
 * `COPILOT-REMOTE.md` §4.6 constraint 5 asks for the second one by name, and it
 * survived the revision that made the tier grantable: *allowed on a device* and
 * *allowed by the person at the machine* must never read the same.
 */

let dir: string

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-copilot-answer-'))
  resetHiddenSessions()
})

afterEach(() => {
  resetHiddenSessions()
  rmSync(dir, { recursive: true, force: true })
})

/**
 * A surface that would happily do everything, so a refusal here is unambiguously
 * the gate rather than a fake that could not perform the action.
 */
function permissiveSurface(): DeckSurface {
  const session = {
    id: 'sess-1',
    cwd: '/work/api',
    title: 'api',
    provider: 'claude' as const,
    exitCode: null,
    createdAt: 1_000,
  }
  return {
    listSessions: () => [session],
    sessionStatus: () => ({ status: 'idle', at: 1_000 }),
    startSession: async () => session,
    writeToSession: () => {},
    killSession: () => {},
    sessionScreen: async () => 'screen',
    listProjects: () => [{ path: '/work/api', lastOpenedAt: 1_000 }],
    deviceFolders: () => ['/work/api'],
    appStateRoot: () => join(dir, 'state'),
    copilotRoot: () => join(dir, 'state', 'copilot'),
    gitStatus: async () => ({}),
    alerts: async () => ({}),
    readSettings: () => ({ settings: {}, preferences: {} }),
    writeSettings: () => ({}),
    writePreferences: () => ({}),
    snapshotSettings: () => ({ ok: true, path: join(dir, 'snap.json'), at: 1_000 }),
    transcriptsIn: async () => [],
    transcriptBytes: async () => 0,
    readTranscriptFrom: async () => [],
    readToolTrail: async () => ({ calls: [], partial: false }),
    transcriptTotals: async () => null,
    gitChanges: async () => ({ cwd: '/work/api', files: [], truncated: false }),
    fileDiff: async () => '',
    fileModifiedAt: async () => null,
  } as unknown as DeckSurface
}

interface Rig {
  deck: DeckControl
  links: CopilotAccess
  runs: CopilotRuns
  log: ActionLog
  consent: ConsentBroker
  /** Whether a window is attached as the desktop approver. */
  desk: { attached: boolean }
  /** Everything the device was sent. */
  asked: CopilotConsentQuestion[]
  settled: CopilotSettledRow[]
  /** Subscribe a device the way `copilot.attach` does. */
  watch(deviceId: string): () => void
  /**
   * Approve a device as **one of his own**, which is the entire ceremony.
   *
   * This used to be a `connect(deviceId, tiers)` that minted a six-digit copilot
   * code, redeemed it against a store on disk and awaited the outcome — a second
   * act of authorisation on top of pairing. It is gone, and so is the `await` at
   * every call site: a device's kind is decided once, when it is approved, and
   * `CopilotAccess` reads that and nothing else. `copilot-access.ts` carries the
   * argument and preserves the one it superseded.
   *
   * Every device in this file is approved as his, because a guest raises no
   * confirmations to answer: it has no copilot, so there is no run of its own to
   * ask it anything. That property is asserted where it belongs, in
   * `copilot-enforcement.test.ts` and `server.test.ts`, rather than restated
   * here as an absence.
   */
  approve(deviceId: string): void
}

/**
 * The whole chain, assembled out of the real objects the app assembles.
 *
 * The only fakes are the surface above and the run spawn, which cannot start a
 * Claude CLI in a test. Everything that decides anything — the store, the
 * broker, the dispatcher, the log — is the real class, wired the way
 * `deck-control/index.ts` and `main/index.ts` wire them.
 */
function rig(): Rig {
  // The roster of devices somebody at this keyboard approved as their own, which
  // in the app is `remote-device-kinds.json` read through `DeviceKinds.kindOf`.
  // A mutable set rather than a fixed list because `CopilotAccess` asks the
  // question on every call rather than snapshotting an answer, and a fixture
  // that could not change underneath it would quietly stop testing that.
  const mine = new Set<string>()
  const links = new CopilotAccess({ isMine: (deviceId) => mine.has(deviceId) })
  const log = new ActionLog({ dir: join(dir, 'log') })
  const desk = { attached: false }
  const asked: CopilotConsentQuestion[] = []
  const settledRows: CopilotSettledRow[] = []

  let runs: CopilotRuns
  const consent = new ConsentBroker({
    // The fan-out `deck-control/index.ts` performs: the device first, then the
    // window, and `delivered` is an OR because one surface is enough.
    ask: (request: ConsentRequest) => {
      const remote = runs.ask(request)
      return desk.attached || remote
    },
    settled: (id, outcome) => runs.settled(id, outcome),
    timeoutMs: 5_000,
  })
  runs = new CopilotRuns({
    links,
    consent: () => consent,
    callers: { set: () => {}, delete: () => true },
    endpoint: () => ({ url: 'http://127.0.0.1:5599/mcp' }),
    copilotRoot: () => join(dir, 'copilot'),
    spawn: async () => 'run-1',
    isAlive: () => true,
    stop: () => {},
    say: () => {},
    interrupt: () => {},
    desk: () => ({ status: 'running', profile: 'Personal', signedIn: true, available: true, reason: null }),
    cost: () => ({ tools: 11, turnTokens: 900 }),
    sessions: () => [],
    log: () => ({ rows: [], more: false }),
    chat: () => () => {},
  })

  const deck = new DeckControl({ surface: permissiveSurface(), log, consent })

  return {
    deck,
    links,
    runs,
    log,
    consent,
    desk,
    asked,
    settled: settledRows,
    watch: (deviceId) =>
      runs.watch(deviceId, {
        state: () => {},
        chat: () => {},
        tool: () => {},
        sessions: () => {},
        pending: () => {},
        ask: (question) => asked.push(question),
        settled: (row) => settledRows.push(row),
      }),
    approve: (deviceId) => {
      mine.add(deviceId)
      // A guard on the fixture rather than decoration: if `CopilotAccess` ever
      // stopped answering off the kind, every ownership assertion below would
      // pass against a rig in which nobody could raise a question at all.
      expect(links.granted(deviceId).alter, 'the fixture failed to approve a device').toBe(true)
    },
  }
}

/** The one alter-tier call these tests drive, with real arguments. */
function writeDensity(deck: DeckControl, caller: ReturnType<typeof remoteCopilotCaller>) {
  return deck.call(
    'settings.write',
    { scope: 'settings', patch: { 'appearance.density': 'compact' } },
    { caller },
  )
}

describe('a device answers its own run’s confirmation', () => {
  it('is asked with the arguments, allows it, and the tool actually runs', async () => {
    const r = rig()
    r.approve('phone-1')
    r.watch('phone-1')

    const call = writeDensity(r.deck, remoteCopilotCaller(r.links, 'phone-1'))
    // The question reaches the device synchronously — `ask` runs inside
    // `consent.request`, before the promise is returned — so one microtask is
    // enough and no timer is needed.
    await Promise.resolve()
    expect(r.asked).toHaveLength(1)
    expect(r.asked[0]).toMatchObject({
      tool: 'settings.write',
      tier: 'alter',
      origin: 'device:phone-1',
    })
    // The value that will actually be written is on the screen of the person
    // being asked. Without it the prompt is a shape, and a prompt that is a
    // shape gets a reflex Yes.
    expect(r.asked[0].args).toEqual({ scope: 'settings', patch: { 'appearance.density': 'compact' } })

    expect(r.runs.answer('phone-1', r.asked[0].id, true)).toBe(true)
    const result = await call
    expect(result.ok).toBe(true)
  })

  /**
   * **The log row.**
   *
   * Three fields carry the whole story and each of them would be a different
   * kind of wrong on its own: `caller.deviceId` says which device *caused* the
   * call, `confirmed.by` says which surface *approved* it, and `detail` is the
   * one line a person scanning the Activity pane reads.
   *
   * They are not the same question. A call caused by a phone and approved at the
   * desk is an ordinary supervised action; a call caused by a phone and approved
   * on that phone is the thing this feature added, and somebody reading the log
   * a week later has to be able to tell them apart at a glance.
   */
  it('writes a row that says which device caused it and where it was allowed', async () => {
    const r = rig()
    r.approve('phone-1')
    r.watch('phone-1')

    const call = writeDensity(r.deck, remoteCopilotCaller(r.links, 'phone-1'))
    await Promise.resolve()
    r.runs.answer('phone-1', r.asked[0].id, true)
    const result = await call

    expect(result.row.caller).toEqual({ kind: 'remote', deviceId: 'phone-1' })
    expect(result.row.confirmed).toMatchObject({
      required: true,
      granted: true,
      by: 'device:phone-1',
    })
    expect(result.row.detail).toContain('allowed on a connected device')
    expect(result.row.detail).not.toContain('allowed by the person')

    // And it is on disk, not only in the returned object: the append is in a
    // `finally`, so the shortest path to "acted without leaving a record" runs
    // through a process crash.
    const tail = r.log.tail(10)
    expect(tail.at(-1)?.confirmed?.by).toBe('device:phone-1')
  })

  /**
   * The desktop's own approval still reads as the desktop's.
   *
   * The counterfactual that makes the assertion above mean something: if
   * `detail` said "allowed on a connected device" for everything, the test
   * before this one would pass while the distinction was gone.
   */
  it('still says allowed by the person when the desk answers', async () => {
    const r = rig()
    r.desk.attached = true

    const call = r.deck.call('settings.write', {
      scope: 'settings',
      patch: { 'appearance.density': 'compact' },
    })
    await Promise.resolve()
    const [waiting] = r.consent.list()
    expect(waiting.origin).toBe(WINDOW_SURFACE)
    r.consent.respond(waiting.id, true, WINDOW_SURFACE)
    const result = await call

    expect(result.ok).toBe(true)
    expect(result.row.detail).toContain('allowed by the person')
    expect(result.row.confirmed.by).toBe(WINDOW_SURFACE)
  })

  /**
   * Refusing is a first-class answer, and it is what the run is told.
   *
   * `declined` says *stop asking* rather than *try again*, which is the whole
   * reason the refusal reasons are a closed set. A device that refuses must
   * produce the same outcome the desktop's Refuse button does.
   */
  it('refuses, and the call is declined rather than failed', async () => {
    const r = rig()
    r.approve('phone-1')
    r.watch('phone-1')

    const call = writeDensity(r.deck, remoteCopilotCaller(r.links, 'phone-1'))
    await Promise.resolve()
    expect(r.runs.answer('phone-1', r.asked[0].id, false)).toBe(true)
    const result = await call

    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('declined')
    expect(result.row.confirmed.by).toBe('device:phone-1')
  })
})

describe('first answer wins, and the loser is told where it went', () => {
  it('takes the desktop’s answer and withdraws the device’s dialog', async () => {
    const r = rig()
    r.approve('phone-1')
    r.watch('phone-1')

    const call = writeDensity(r.deck, remoteCopilotCaller(r.links, 'phone-1'))
    await Promise.resolve()
    const id = r.asked[0].id

    r.consent.respond(id, true, WINDOW_SURFACE)
    const result = await call
    expect(result.ok).toBe(true)
    expect(result.row.confirmed.by).toBe(WINDOW_SURFACE)

    // The device's dialog is withdrawn **saying where it was answered**, rather
    // than vanishing. A dialog that disappears on its own teaches a person that
    // the app does things behind their back.
    expect(r.settled).toEqual([{ id, granted: true, by: WINDOW_SURFACE, reason: null }])

    // And the late answer is refused, so a tap that arrives after the race
    // cannot re-run anything.
    expect(r.runs.answer('phone-1', id, true)).toBe(false)
  })

  it('takes the device’s answer and reports it to the desktop the same way', async () => {
    const r = rig()
    r.desk.attached = true
    r.approve('phone-1')
    r.watch('phone-1')

    const call = writeDensity(r.deck, remoteCopilotCaller(r.links, 'phone-1'))
    await Promise.resolve()
    const id = r.asked[0].id

    expect(r.runs.answer('phone-1', id, true)).toBe(true)
    await call
    // `settled` fires for every surface, which is what closes the dialog on the
    // Mac as well.
    expect(r.settled).toEqual([{ id, granted: true, by: 'device:phone-1', reason: null }])
    expect(r.consent.list()).toEqual([])
  })
})

describe('the ownership rule', () => {
  /**
   * **A device may not answer another device's question.**
   *
   * The rule §4.2 flags as non-obvious, at the layer that enforces it. Both
   * devices are his own and both therefore hold `alter`, so nothing about the
   * tier or the transport stops this — what stops it is that the question
   * belongs to `phone-1`'s run.
   *
   * This rule got *more* load-bearing when the separate copilot connection went
   * away, not less. Two of his devices used to be two deliberate redemptions;
   * they are now simply two devices he owns, which is the ordinary case rather
   * than the unusual one. Without this check, approving a second phone would
   * make either of them able to approve the other's actions — a permission model
   * with a shared password.
   */
  it('refuses an answer from a device that did not raise the question', async () => {
    const r = rig()
    r.desk.attached = true
    r.approve('phone-1')
    r.approve('phone-2')
    r.watch('phone-1')

    const call = writeDensity(r.deck, remoteCopilotCaller(r.links, 'phone-1'))
    await Promise.resolve()
    const id = r.asked[0].id

    expect(r.runs.answer('phone-2', id, true)).toBe(false)
    // Still waiting: the other device's tap changed nothing.
    expect(r.consent.list().map((q) => q.id)).toEqual([id])

    r.consent.respond(id, false, WINDOW_SURFACE)
    const result = await call
    expect(result.ok).toBe(false)
  })

  /**
   * And it is never *shown* to the other device either.
   *
   * The tier check and the ownership check would both refuse the answer, so this
   * is about the arguments rather than the decision: `phone-2` never receives the
   * settings patch that `phone-1` was asked about. A question a device cannot
   * answer reaches it as a watch row with no arguments on it, or not at all.
   */
  it('never sends another device the question, only the watch row', async () => {
    const r = rig()
    r.desk.attached = true
    r.approve('phone-1')
    r.approve('phone-2')

    const seen: CopilotConsentQuestion[] = []
    r.runs.watch('phone-2', {
      state: () => {},
      chat: () => {},
      tool: () => {},
      sessions: () => {},
      pending: () => {},
      ask: (question) => seen.push(question),
      settled: () => {},
    })

    const call = writeDensity(r.deck, remoteCopilotCaller(r.links, 'phone-1'))
    await Promise.resolve()
    expect(seen).toEqual([])

    const [waiting] = r.consent.list()
    /*
     * It is visible to `phone-2` as a watch row, flagged as not theirs — that is
     * the *watching* half of the surface and it is deliberate: a device that
     * cannot answer can still say *go and look*, which is the failure this
     * feature was built against.
     *
     * What it does not get is `args`. The row has exactly six fields and the
     * arguments are not among them, asserted by shape rather than by searching
     * the text — because the *summary* is a sentence composed for a person and
     * will often name the value, which is the point of it. The distinction is
     * real: a summary is one line the desktop wrote, and `args` is the whole
     * object, which for `sessions.send` is the text about to be typed into
     * somebody's terminal.
     */
    const rows = r.runs.pending('phone-2')
    expect(rows).toEqual([expect.objectContaining({ id: waiting.id, mine: false })])
    expect(Object.keys(rows[0]).sort()).toEqual(
      ['expiresAt', 'id', 'mine', 'requestedAt', 'summary', 'tool'].sort(),
    )
    expect('args' in rows[0]).toBe(false)

    r.consent.respond(waiting.id, false, WINDOW_SURFACE)
    await call
  })
})

describe('a device that goes away defaults to refusal', () => {
  /**
   * The connection closing withdraws the question, with `caller-gone`.
   *
   * Not left for the desktop to answer: the run that asked is about to be reaped
   * and the person who asked is gone, so an approval landing afterwards is a
   * change nobody is waiting for. `caller-gone` is the reason that already
   * exists for exactly this failure one transport further in.
   */
  it('refuses its questions when its copilot connection closes', async () => {
    const r = rig()
    r.desk.attached = true
    r.approve('phone-1')
    r.watch('phone-1')

    const call = writeDensity(r.deck, remoteCopilotCaller(r.links, 'phone-1'))
    await Promise.resolve()
    expect(r.asked).toHaveLength(1)

    r.runs.closed('phone-1')
    const result = await call
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('caller-gone')
    expect(result.row.confirmed).toMatchObject({ required: true, granted: false, reason: 'caller-gone' })
  })

  /**
   * A question raised at the desk is untouched by a device leaving.
   *
   * The device's disappearance removes a *watcher*, not an approver, for
   * anything it did not raise. Refusing the desk's own question because a phone
   * went into a tunnel would be the app deciding something nobody asked it to.
   */
  it('leaves the desk’s own questions alone', async () => {
    const r = rig()
    r.desk.attached = true
    r.approve('phone-1')
    r.watch('phone-1')

    const call = r.deck.call('settings.write', {
      scope: 'settings',
      patch: { 'appearance.density': 'compact' },
    })
    await Promise.resolve()
    const [waiting] = r.consent.list()

    r.runs.closed('phone-1')
    expect(r.consent.list().map((q) => q.id)).toEqual([waiting.id])

    r.consent.respond(waiting.id, true, WINDOW_SURFACE)
    expect((await call).ok).toBe(true)
  })

  /**
   * Timing out is still a refusal, and it still says so.
   *
   * Two minutes in production, shortened here. Nothing about a device answering
   * changed the deadline: a longer window is how an approval arrives six minutes
   * later from somebody who has forgotten what they were approving.
   */
  it('refuses on the timeout with nobody answering', async () => {
    const r = rig()
    r.approve('phone-1')
    r.watch('phone-1')

    const quick = new ConsentBroker({
      ask: (request) => r.runs.ask(request),
      settled: (id, outcome) => r.runs.settled(id, outcome),
      timeoutMs: 20,
    })
    const deck = new DeckControl({
      surface: permissiveSurface(),
      log: new ActionLog({ dir: join(dir, 'log2') }),
      consent: quick,
    })

    const result = await writeDensity(deck, remoteCopilotCaller(r.links, 'phone-1'))
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('timeout')
  })
})
