import { mkdtempSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  CopilotGrants,
  copilotGrantFrom,
  REMOTE_COPILOT_FILE,
  REMOTE_GRANTABLE_TIERS,
  grantsNothing,
  remoteCopilotCaller,
} from './copilot-grants'
import { ActionLog } from '../deck-control/action-log'
import { ConsentBroker } from '../deck-control/consent'
import { DeckControl } from '../deck-control/control'
import type { DeckSurface } from '../deck-control/surface'
import type { SessionMeta } from '../../shared/types'

/**
 * Per-device copilot access.
 *
 * Two halves, and the second is the one that matters. The store on its own is a
 * small file; what has to be true is that a grant produces the behaviour a
 * person expects when a call actually arrives — so the bottom of this file wires
 * the real store to the real dispatcher and asks the question in the user's
 * words: my phone may look, and may not touch.
 *
 * The rule the whole thing exists for is the one a boolean cannot express.
 * Granting a device "the copilot" grants it `settings.write` and
 * `sessions.stop`, because the tool names are the same on both surfaces. That
 * is OpenClaw's GHSA-943q-mwmv-hhvh (OC-02) exactly, and it is the reason a
 * grant here is three answers rather than one.
 */

function tempDir(): string {
  return mkdtempSync(join(tmpdir(), 'td-copilot-grants-'))
}

/* -------------------------------------------------------------- the store -- */

describe('what a device is granted', () => {
  it('gives an unknown device nothing at all', () => {
    const grants = new CopilotGrants(tempDir())
    // Not null, and not "whatever the desktop offers" — which is what
    // `folder-grants.ts` does, deliberately, for a capability that predates its
    // own grant file. Nobody has ever had remote copilot access, so nobody can
    // be locked out of it by defaulting to off.
    expect(grants.granted('phone-1')).toEqual({ read: false, act: false, alter: false })
    expect(grants.list()).toEqual([])
  })

  it('keeps a read-only grant, which is the point of the whole shape', () => {
    const grants = new CopilotGrants(tempDir())
    expect(grants.set('phone-1', { read: true })).toEqual({ read: true, act: false, alter: false })
    expect(grants.granted('phone-1')).toEqual({ read: true, act: false, alter: false })
  })

  it('never grants alter, however it is asked for', () => {
    /*
     * `alter` is the tier whose entire safety property is "a person at the
     * machine says yes", and the person holding the phone is by definition not
     * that person. Granting it remotely would be granting away the property.
     */
    const grants = new CopilotGrants(tempDir())
    const stored = grants.set('phone-1', { read: true, act: true, alter: true })
    expect(stored.alter).toBe(false)
    expect(grants.granted('phone-1').alter).toBe(false)
    expect(REMOTE_GRANTABLE_TIERS).toEqual(['read', 'act'])
  })

  it('does not write alter into the file, even as false', () => {
    // A `"alter": false` in a file a person may open reads like a switch that
    // could be turned on. It cannot be.
    const dir = tempDir()
    const grants = new CopilotGrants(dir)
    grants.set('phone-1', { read: true, act: true, alter: true })
    const raw = JSON.parse(readFileSync(join(dir, REMOTE_COPILOT_FILE), 'utf8')) as {
      devices: Record<string, Record<string, boolean>>
    }
    expect(Object.keys(raw.devices['phone-1']).sort()).toEqual(['act', 'read'])
  })

  it('survives a restart', () => {
    const dir = tempDir()
    new CopilotGrants(dir).set('phone-1', { read: true, act: true })
    expect(new CopilotGrants(dir).granted('phone-1')).toEqual({ read: true, act: true, alter: false })
  })

  it('stores nothing for a device granted nothing', () => {
    const dir = tempDir()
    const grants = new CopilotGrants(dir)
    grants.set('phone-1', { read: true })
    grants.set('phone-1', { read: false })
    expect(grants.list()).toEqual([])
    expect(new CopilotGrants(dir).granted('phone-1').read).toBe(false)
  })

  it('forgets a revoked device', () => {
    const dir = tempDir()
    const grants = new CopilotGrants(dir)
    grants.set('phone-1', { read: true })
    expect(grants.forget('phone-1')).toBe(true)
    expect(grants.forget('phone-1')).toBe(false)
    expect(new CopilotGrants(dir).granted('phone-1').read).toBe(false)
  })

  it('is written 0600, like every other file in this directory', () => {
    const dir = tempDir()
    const grants = new CopilotGrants(dir)
    grants.set('phone-1', { read: true })
    // Not a secret in the sense a token is, but it is a permission, and it goes
    // through `writeSecretFile` for the atomicity as well as the mode.
    expect(statSync(grants.file).mode & 0o777).toBe(0o600)
  })
})

/* ------------------------------------------------------- reading the file -- */

describe('what the file is allowed to say', () => {
  it('reads a hand-edited alter back out again', () => {
    const dir = tempDir()
    writeFileSync(
      join(dir, REMOTE_COPILOT_FILE),
      JSON.stringify({ version: 1, devices: { 'phone-1': { read: true, alter: true } } }),
    )
    // Somebody who edits the JSON has not found a way past the rule; they have
    // found a way to write a word this parser drops.
    expect(new CopilotGrants(dir).granted('phone-1')).toEqual({ read: true, act: false, alter: false })
  })

  it('treats a boolean-shaped grant as no grant', () => {
    /*
     * The migration this design exists to never need. If a `true` ever appears
     * where an object belongs — hand-written, or from a build that got this
     * wrong — it reads as *nothing*, not as "they meant all of it". Guessing
     * generously at a permission is how a permission gets widened by a parser.
     */
    expect(copilotGrantFrom(true)).toEqual({ read: false, act: false, alter: false })
    const dir = tempDir()
    writeFileSync(join(dir, REMOTE_COPILOT_FILE), JSON.stringify({ version: 1, devices: { 'phone-1': true } }))
    expect(grantsNothing(new CopilotGrants(dir).granted('phone-1'))).toBe(true)
  })

  it('grants on a literal true and nothing else', () => {
    // A JSON file a person edits will eventually contain one of these.
    expect(copilotGrantFrom({ read: 'true' }).read).toBe(false)
    expect(copilotGrantFrom({ read: 1 }).read).toBe(false)
    expect(copilotGrantFrom({ read: 'yes' }).read).toBe(false)
    expect(copilotGrantFrom({ read: true }).read).toBe(true)
  })

  it('fails closed on a corrupt file', () => {
    /*
     * The opposite of `folder-grants.ts`, on purpose. That file decides which
     * folder a session starts in for a machine already approved, and failing
     * closed would strand a paired phone over a JSON typo — with the failure on
     * the phone and the fix on the desktop. This decides whether a phone can
     * drive an agent that spends money, and the worst case of failing closed is
     * re-ticking a box on the desktop, which is where the box is anyway.
     */
    const dir = tempDir()
    writeFileSync(join(dir, REMOTE_COPILOT_FILE), '{ not json at all')
    expect(new CopilotGrants(dir).granted('phone-1').read).toBe(false)
  })
})

/* --------------------------------------------------- wired to the gate -- */

const SESSION: SessionMeta = {
  id: 'human-1',
  cwd: '/work/api',
  title: 'api',
  provider: 'claude',
  exitCode: null,
  createdAt: 1_000,
}

function surface(): { surface: DeckSurface; killed: string[]; started: number } {
  const state = { surface: {} as DeckSurface, killed: [] as string[], started: 0 }
  state.surface = {
    listSessions: () => [SESSION],
    sessionStatus: () => ({ status: 'working', at: 1 }),
    startSession: async () => {
      state.started += 1
      return SESSION
    },
    writeToSession: () => undefined,
    killSession: (id) => {
      state.killed.push(id)
    },
    sessionScreen: async () => '',
    listProjects: () => [{ path: '/work/api', lastOpenedAt: 1 }],
    gitStatus: async () => ({ repo: true }),
    alerts: async () => ({ alerts: [] }),
    readSettings: () => ({ settings: {}, preferences: {} }),
    writeSettings: () => ({}),
    writePreferences: () => ({}),
    snapshotSettings: () => ({ path: '/tmp/settings.last-good.json', at: 0 }),
    newestTranscript: async () => null,
    transcriptBytes: async () => 0,
    readTranscriptFrom: async () => [],
  }
  return state
}

describe('a phone with a read-only grant, end to end', () => {
  it('may look at the fleet and may not touch it', async () => {
    const dir = tempDir()
    const grants = new CopilotGrants(dir)
    grants.set('phone-1', { read: true })

    const state = surface()
    const control = new DeckControl({
      surface: state.surface,
      log: new ActionLog({ dir: join(dir, 'log') }),
      // An approver that says yes to everything. The refusals below are not
      // the confirmation gate holding — they are the grant holding *before* it.
      consent: new ConsentBroker({ ask: () => true, timeoutMs: 50 }),
    })
    const caller = remoteCopilotCaller(grants, 'phone-1')

    expect((await control.call('sessions_list', {}, { caller })).ok).toBe(true)
    expect((await control.call('alerts_list', { projectPath: '/work/api' }, { caller })).ok).toBe(true)

    const stopped = await control.call('sessions_stop', { sessionId: 'human-1' }, { caller })
    expect(stopped.refusal).toBe('not-granted')
    const started = await control.call('sessions_start', { cwd: '/work/api' }, { caller })
    expect(started.refusal).toBe('not-granted')

    expect(state.killed).toEqual([])
    expect(state.started).toBe(0)
  })

  it('cannot reach the alter tier even after being granted everything grantable', async () => {
    const dir = tempDir()
    const grants = new CopilotGrants(dir)
    grants.set('phone-1', { read: true, act: true, alter: true })

    const state = surface()
    const control = new DeckControl({
      surface: state.surface,
      log: new ActionLog({ dir: join(dir, 'log') }),
      consent: new ConsentBroker({ ask: () => true, timeoutMs: 50 }),
    })
    const caller = remoteCopilotCaller(grants, 'phone-1')

    // `settings.write` is alter by declaration, and `sessions.stop` escalates to
    // alter for a session this copilot did not start. Neither is reachable from
    // a phone, whatever the settings panel was asked for.
    expect((await control.call('settings_write', { scope: 'preferences', patch: { theme: 'light' } }, { caller })).refusal).toBe(
      'not-granted',
    )
    expect((await control.call('sessions_stop', { sessionId: 'human-1' }, { caller })).refusal).toBe('not-granted')
    expect(state.killed).toEqual([])
  })
})
