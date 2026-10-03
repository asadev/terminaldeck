import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { ActionLog } from './action-log'
import { ConsentBroker } from './consent'
import { DeckControl, refusedWhileDriving } from './control'
import { NO_TIERS, type Caller, type DeckSurface } from './surface'
import type { SessionMeta } from '../../shared/types'
import { TourStage, type TourWindow } from './tour-stage'
import { tourTool } from './tour-tool'

/**
 * The three gates driving mode carries beyond its tier.
 *
 * `tour.play` is `act` — logged, visible, undoable — and `act` alone is not
 * enough for it, because two of its failure modes are about *who is there*
 * rather than about what it changes:
 *
 *  1. **Local only.** A paired phone must never make this Mac's screen move.
 *  2. **Attended only.** A routine at 03:00 must not play a tour to nobody.
 *  3. **Nothing changes while it plays**, because in that window the person's
 *     model of cause and effect is suspended and a change is one they cannot
 *     attribute.
 *
 * All three are checks rather than sentences in an instruction file, because the
 * prose version of a rule has been tried twice in this codebase and broken both
 * times. Each is exercised through the real dispatcher, so a refactor that moved
 * one out of the path fails here rather than in a screenshot.
 */

const SESSION: SessionMeta = {
  id: 's1',
  cwd: '/work/api',
  title: 'api',
  provider: 'shell',
  exitCode: null,
  createdAt: 1_000,
}

function surface(): DeckSurface {
  return {
    listSessions: () => [SESSION],
    sessionStatus: () => null,
    startSession: async () => SESSION,
    writeToSession: () => undefined,
    killSession: () => undefined,
    sessionScreen: async () => 'the build failed',
    sessionScrollback: () => 'the build failed',
    listProjects: () => [{ path: '/work/api', lastOpenedAt: 1 }],
    appStateRoot: () => '/state',
    copilotRoot: () => '/state/copilot',
    gitStatus: async () => ({}),
    alerts: async () => [],
    readSettings: () => ({ settings: {}, preferences: {} }),
    writeSettings: () => ({}),
    writePreferences: () => ({}),
    snapshotSettings: () => ({ path: '/state/last-good.json', at: 1 }),
    transcriptsIn: async () => [],
    transcriptBytes: async () => 0,
    readTranscriptFrom: async () => [],
    readToolTrail: async () => ({ events: [], compactions: [], fileBytes: 0, fromByte: 0, partial: false }),
    transcriptTotals: async () => null,
    gitChanges: async () => ({
      repo: true,
      root: '/work/api',
      branch: 'main',
      ahead: 0,
      behind: 0,
      files: [
        { path: 'a.ts', group: 'unstaged', kind: 'modified', insertions: 1, deletions: 0, binary: false },
      ],
      reason: null,
    }),
    fileDiff: async () => '',
    fileModifiedAt: async () => null,
  }
}

const PLAN = {
  question: 'what happened?',
  headline: 'this happened',
  stops: [
    {
      kind: 'screen',
      sessionId: 's1',
      quote: 'the build failed',
      note: 'it failed',
      why: 'files-changed',
    },
  ],
}

function build(options: { window?: Partial<TourWindow>; settings?: Record<string, boolean> } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'tour-gates-'))
  let onGone: (() => void) | null = null
  const window: TourWindow = {
    /*
     * Answers the way the renderer does: on the next turn of the queue, not
     * inside `send`. The stage is not yet holding the tour when `send` returns —
     * that is the whole shape of "the plan is offered and driving begins when
     * the window says it began" — so an acknowledgement from inside `send` would
     * be answering a question that has not been asked.
     */
    send: (record) => {
      queueMicrotask(() => tours.acknowledge(record.id))
      return true
    },
    watch: (handler) => {
      onGone = handler
      return () => undefined
    },
    ...options.window,
  }
  const tours = new TourStage({ dir, window })
  const control = new DeckControl({
    surface: { ...surface(), readSettings: () => ({ settings: options.settings ?? {}, preferences: {} }) },
    log: new ActionLog({ dir }),
    consent: new ConsentBroker({ ask: () => false, settled: () => undefined }),
    extraTools: [tourTool(tours)],
    driving: () => tours.driving(),
  })
  return {
    control,
    tours,
    /** Play a tour. The fake window acknowledges it, as a real one would. */
    async play(caller?: Caller, attended = true) {
      return await control.call('tour.play', PLAN, {
        attended,
        ...(caller === undefined ? {} : { caller }),
      })
    },
    gone: () => onGone?.(),
  }
}

const REMOTE: Caller = { kind: 'remote', deviceId: 'phone-1', tiers: { read: true, act: true, alter: true } }

describe('driving is local only', () => {
  it('refuses a phone that holds act, and says asking again will not help', async () => {
    const rig = build()
    const result = await rig.control.call('tour.play', PLAN, { caller: REMOTE })
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-granted')
    expect(result.error).toContain('sitting at this machine')
    expect(rig.tours.driving()).toBe(false)
  })

  it('refuses a phone that holds nothing, for the ordinary tier reason', async () => {
    const rig = build()
    const caller: Caller = { kind: 'remote', deviceId: 'phone-1', tiers: NO_TIERS }
    const result = await rig.control.call('tour.play', PLAN, { caller })
    expect(result.refusal).toBe('not-granted')
  })

  it('allows the person at this keyboard', async () => {
    const rig = build()
    const result = await rig.play()
    expect(result.ok).toBe(true)
  })
})

describe('driving is attended only', () => {
  it('refuses an unattended run and tells it not to look for another way', async () => {
    const rig = build()
    const result = await rig.control.call('tour.play', PLAN, { attended: false })
    expect(result.refusal).toBe('not-permitted-unattended')
    expect(result.error).toContain('Do not')
    expect(rig.tours.driving()).toBe(false)
  })

  it('refuses through the narrowed caller the routine engine actually holds', async () => {
    const rig = build()
    const result = await rig.control.unattended().call('tour.play', PLAN)
    expect(result.refusal).toBe('not-permitted-unattended')
  })
})

describe('nothing changes while a tour is playing', () => {
  it('names the tools that are refused, and covers a whole family by prefix', () => {
    expect(refusedWhileDriving('sessions.send')).toBe(true)
    expect(refusedWhileDriving('sessions.start')).toBe(true)
    expect(refusedWhileDriving('sessions.stop')).toBe(true)
    expect(refusedWhileDriving('settings.write')).toBe(true)
    expect(refusedWhileDriving('routines.create')).toBe(true)
    expect(refusedWhileDriving('tour.play')).toBe(true)
  })

  it('holds the 0.16.0 tools that move the screen or the session under it', () => {
    /*
     * Pressing a key, renaming, swapping a login, clicking in the window,
     * resetting settings or installing an update while a tour plays is the same
     * unattributable change a message would be.
     */
    for (const id of [
      'sessions.keys',
      'sessions.rename',
      'sessions.account',
      'sessions.held',
      'ui.do',
      'hoot.run',
      'settings.reset',
      'agents.set_control',
      'accounts.sign_in',
      'updates.install',
      // Typing into a session on another computer, or a terminal on a server.
      'machines.session',
      'servers.shell',
    ]) {
      expect(refusedWhileDriving(id), id).toBe(true)
    }
    // Looking, waiting and reading the screen change nothing about it.
    for (const id of ['sessions.wait', 'sessions.screen', 'ui.list', 'files.read', 'machines.look', 'servers.details']) {
      expect(refusedWhileDriving(id), id).toBe(false)
    }
  })

  it('leaves reading alone, because a read changes nothing about the screen', () => {
    expect(refusedWhileDriving('sessions.list')).toBe(false)
    expect(refusedWhileDriving('git.status')).toBe(false)
    expect(refusedWhileDriving('log.note')).toBe(false)
  })

  it('refuses a send mid-tour and tells the model to wait rather than retry', async () => {
    const rig = build()
    await rig.play()
    expect(rig.tours.driving()).toBe(true)

    const result = await rig.control.call('sessions.send', { sessionId: 's1', text: 'hello' })
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-permitted-while-driving')
    expect(result.error).toContain('Wait until the tour ends')
    // The row still lands, because every call at every tier is logged — a
    // refusal is a row, not a silence.
    expect(result.row.outcome).toBe('refused')
  })

  it('still answers a read mid-tour', async () => {
    const rig = build()
    await rig.play()
    const result = await rig.control.call('sessions.list', {})
    expect(result.ok).toBe(true)
  })

  it('lifts the gate the moment the tour ends', async () => {
    const rig = build()
    await rig.play()
    rig.tours.stop()
    expect(rig.tours.driving()).toBe(false)
    const result = await rig.control.call('sessions.list', {})
    expect(result.ok).toBe(true)
  })

  it('lifts the gate when the window reloads mid-tour', async () => {
    const rig = build()
    await rig.play()
    rig.gone()
    expect(rig.tours.driving()).toBe(false)
    const result = await rig.control.call('sessions.start', { cwd: '/work/api' })
    expect(result.refusal).not.toBe('not-permitted-while-driving')
  })

  it('does not shut the gate for a plan no window ever took', async () => {
    // The failure this prevents: a fire-and-forget tour latching the gate with
    // nothing able to unlatch it, so every change is refused for the rest of the
    // run for a tour that never appeared.
    const rig = build({ window: { send: () => false } })
    const result = await rig.control.call('tour.play', PLAN)
    expect(result.ok).toBe(true)
    expect((result.value as { played: boolean }).played).toBe(false)
    expect(rig.tours.driving()).toBe(false)
    const send = await rig.control.call('sessions.list', {})
    expect(send.ok).toBe(true)
  })
})

describe('what the tool tells the model', () => {
  it('reports the drops rather than quietly showing fewer stops', async () => {
    const rig = build()
    const withGhost = {
      ...PLAN,
      stops: [
        ...PLAN.stops,
        { kind: 'screen', sessionId: 's1', quote: 'never printed', note: 'n', why: 'files-changed' },
      ],
    }
    const result = await rig.control.call('tour.play', withGhost)
    const value = result.value as { playing: number; dropped: number }
    expect(value.playing).toBe(1)
    expect(value.dropped).toBe(1)
  })

  it('does not drive at all when every stop was dropped', async () => {
    const rig = build()
    const allGhosts = {
      ...PLAN,
      stops: [{ kind: 'screen', sessionId: 's1', quote: 'never printed', note: 'n', why: 'files-changed' }],
    }
    const result = await rig.control.call('tour.play', allGhosts)
    const value = result.value as { played: boolean }
    expect(value.played).toBe(false)
    expect(rig.tours.driving()).toBe(false)
  })

  it('refuses an over-budget plan as a rule rather than trimming it', async () => {
    const rig = build()
    const many = {
      ...PLAN,
      stops: Array.from({ length: 13 }, () => PLAN.stops[0]),
    }
    const result = await rig.control.call('tour.play', many)
    expect(result.refusal).toBe('not-permitted')
    expect(result.error).toContain('refused rather than trimmed')
  })
})


/* -------------------------------------------------------- the toggle -- */

describe('interactive mode', () => {
  it('drives by default, because the showing is the feature', async () => {
    /*
     * On unless somebody said otherwise. A person who has never opened Settings
     * asked for a copilot that drives; defaulting to quiet would make the whole
     * thing invisible until discovered, which is the same failure as shipping it
     * behind a flag.
     */
    const rig = build()
    const result = await rig.play()
    expect((result.value as { played?: boolean }).played).toBe(true)
  })

  it('with it off, does the same work and shows none of it', async () => {
    /*
     * *"Interactive mode OFF — it does the work in the background and returns
     * the final answer normally, with none of the driving. The answer must be
     * identical either way; only the showing differs."*
     *
     * So the plan is still parsed, still validated against the real fleet, and
     * still recorded with every quote that survived the checks — the record on
     * disk is the answer, and it is the same answer. What must NOT happen is a
     * window being offered a tour, or the driving gate closing over a scan with
     * nothing on screen: that would refuse every tool that changes anything with
     * nothing anywhere to lift it.
     */
    const rig = build({ settings: { 'copilot.interactive': false } })
    const result = await rig.play()
    expect(result.ok).toBe(true)

    const value = result.value as { played: boolean; shown: string; found: number; tourId: string }
    expect(value.played).toBe(false)
    expect(value.shown).toBe('background')
    expect(value.found).toBe(1)

    expect(rig.tours.driving()).toBe(false)
    const record = rig.tours.list().find((entry) => entry.id === value.tourId)
    expect(record?.shown).toBe('background')
    // Every stop the checks passed is in the record, with its verbatim quote —
    // which is what makes the answer identical to the driven one.
    expect(record?.stops.map((stop) => stop.quote)).toEqual(['the build failed'])
    expect(record?.endedAt).not.toBeNull()
  })

  it('does not let the copilot turn the light off itself', async () => {
    /*
     * Whether its own work is watched is the person's choice about their own
     * screen. `PROTECTED_SETTING_PREFIXES` already covers `copilot.`, so the key
     * is unwritable through `settings.write` with no new mechanism — but the
     * reason it is unwritable is worth a failing test rather than a comment,
     * because the prefix list is the kind of thing that gets trimmed.
     */
    const rig = build()
    const result = await rig.control.call('settings.write', {
      changes: [{ key: 'copilot.interactive', value: false }],
    })
    expect(result.ok).toBe(false)
  })
})

describe('the remote typing tools, mid-tour, through the dispatcher', () => {
  it('refuses machines.session and servers.shell while a tour plays, and says to wait', async () => {
    const { assembledExtraTools } = await import('./assembled-catalogue.fixture')
    const { ActionLog } = await import('./action-log')
    const { ConsentBroker } = await import('./consent')
    const { mkdtempSync, rmSync } = await import('node:fs')
    const { tmpdir } = await import('node:os')
    const { join } = await import('node:path')
    const dir = mkdtempSync(join(tmpdir(), 'td-tour-remote-'))
    try {
      const control = new DeckControl({
        surface: {} as never,
        log: new ActionLog({ dir }),
        consent: new ConsentBroker({ ask: () => false }),
        extraTools: assembledExtraTools(),
        driving: () => true,
      })
      for (const [tool, args] of [
        ['machines.session', { do: 'type', machineId: 'm1', sessionId: 's1', text: 'ls' }],
        ['servers.shell', { do: 'type', shellId: 'sh1', text: 'ls' }],
      ] as const) {
        const result = await control.call(tool, args)
        expect(result.refusal, tool).toBe('not-permitted-while-driving')
        expect(result.error, tool).toMatch(/Wait until the tour ends/)
      }
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})
