import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ActionLog } from '../deck-control/action-log'
import { buildCatalogue } from '../deck-control/catalogue'
import { ConsentBroker } from '../deck-control/consent'
import { DeckControl } from '../deck-control/control'
import type { DeckSurface } from '../deck-control/surface'
import { CopilotGrants, REMOTE_GRANTABLE_TIERS, remoteCopilotCaller } from './copilot-grants'
import { copilotFrameAllowed } from './copilot-remote'
import { COPILOT_FRAME_TIER } from './protocol'

/**
 * Where the boundary actually is, proved against the whole catalogue.
 *
 * `COPILOT-REMOTE.md` §3 describes three layers and says only the second is the
 * boundary, which is the sentence this file exists to make checkable.
 *
 * Layer one is the transport: `server.ts` refuses a `copilot.*` frame from a
 * device whose grant does not cover it. It is here to keep the UI honest — so a
 * phone with no grant draws no Copilot tab and gets a clean refusal if it sends
 * a verb anyway — and `copilot-remote.ts` says at length that it is *not* the
 * boundary, for the reason `control.ts` gives about itself: *"a rule enforced in
 * one transport is a rule the next transport does not have."*
 *
 * **Layer two is `DeckControl.call`**, on this desktop, at the point a tool is
 * dispatched. That is what the bulk of this file drives, and it drives it the
 * way §3 asks for — table-driven over `buildCatalogue()` rather than over a list
 * written out here, so that a tool added next month is covered the day it is
 * added rather than the day somebody remembers this file.
 *
 * The test that would have caught the whole class of bug this feature is about
 * is the first one: a device holding the watching grant, asking for every tool
 * the catalogue declares above that tier, and being told `not-granted` every
 * time — *without* the transport being involved at all.
 */

/* ------------------------------------------------------------------ fakes -- */

let dir: string

/**
 * A surface that would happily do everything, so that a refusal in this file is
 * unambiguously the gate.
 *
 * This matters more than it looks. If the surface threw or returned nothing, an
 * `ok: false` would be consistent with the tool having been *reached* and having
 * failed, which is the opposite of what is being proved. Every method here
 * succeeds; the only thing that can produce a refusal is the tier check.
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

/**
 * A dispatcher whose every other gate is wide open.
 *
 * The consent broker answers *yes* the instant it is asked, and that is the
 * point. §3 names the ordering as load-bearing — the tier check runs **before**
 * the consent gate, so a phone cannot manufacture a question and then have it
 * answered — and a broker that refused by default would let every assertion in
 * this file pass while that ordering was inverted. A permissive approver leaves
 * exactly one thing that can produce a refusal, which is the thing being tested.
 */
function control(): DeckControl {
  let broker: ConsentBroker | null = null
  broker = new ConsentBroker({
    ask: (request) => {
      setTimeout(() => broker?.respond(request.id, true, 'window'), 0)
      // True means "somebody is there to be asked". Saying so is what makes this
      // approver permissive rather than absent — a broker reporting no approver
      // would refuse with `no-approver`, which is a refusal this file must not
      // be able to mistake for the tier check it is testing.
      return true
    },
  })
  return new DeckControl({
    surface: permissiveSurface(),
    log: new ActionLog({ dir: join(dir, 'log') }),
    consent: broker,
  })
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-copilot-enforce-'))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

/* -------------------------------------------------------- the tier check -- */

describe('a watching phone cannot reach a tool above its grant', () => {
  /**
   * The proof obligation `COPILOT-REMOTE.md` §3 writes out, driven off the
   * catalogue.
   *
   * Every tool that declares `act` or `alter` is asked for by a caller built the
   * only way the transport is allowed to build one — through
   * {@link remoteCopilotCaller} — from a store in which this device holds `read`
   * and nothing else. All of them must come back `not-granted`, and the log row
   * must say so, because the row is what the phone is shown as a refusal in the
   * copilot's own words.
   */
  it('refuses every act and alter tool in the catalogue', async () => {
    const grants = new CopilotGrants(dir)
    grants.set('phone-1', { read: true })
    const deck = control()
    const caller = remoteCopilotCaller(grants, 'phone-1')

    const above = buildCatalogue().filter((spec) => spec.tier !== 'read')
    // A guard on the guard. If `buildCatalogue()` ever returns nothing — a
    // refactor, a bad import, a mock left behind — every assertion below would
    // vacuously pass and this file would report that the boundary holds while
    // testing nothing at all.
    expect(above.length).toBeGreaterThan(3)

    for (const spec of above) {
      const result = await deck.call(spec.id, {}, { caller })
      expect(result.ok, `${spec.id} was not refused`).toBe(false)
      expect(result.refusal, `${spec.id} was refused for the wrong reason`).toBe('not-granted')
      expect(result.row.outcome).toBe('refused')
      // The row carries the device, because "which of my phones did that" has
      // exactly one place it can be answered from.
      expect(result.row.caller).toEqual({ kind: 'remote', deviceId: 'phone-1' })
    }
  })

  /**
   * The negative half, and it is not decoration.
   *
   * A gate that refuses everything passes the test above perfectly. This is what
   * distinguishes "the boundary holds" from "the feature is broken", and it is
   * the assertion that would go red if somebody fixed a bug by making the remote
   * caller refuse unconditionally.
   */
  it('lets the same phone reach a read tool', async () => {
    const grants = new CopilotGrants(dir)
    grants.set('phone-1', { read: true })
    const deck = control()
    const caller = remoteCopilotCaller(grants, 'phone-1')

    const result = await deck.call('sessions.list', {}, { caller })
    expect(result.ok).toBe(true)
    expect(result.refusal).toBeNull()
  })

  /**
   * A device the store has never heard of.
   *
   * Absence is no access — the opposite of `folder-grants.ts`, deliberately, and
   * that file's fallback is exactly what must not be copied here. Nobody has
   * ever had remote copilot access, so nobody can lose it by this being strict.
   */
  it('refuses a device that was never granted anything, including read tools', async () => {
    const grants = new CopilotGrants(dir)
    const deck = control()
    const caller = remoteCopilotCaller(grants, 'never-paired')

    for (const id of ['sessions.list', 'sessions.send', 'settings.write']) {
      const result = await deck.call(id, {}, { caller })
      expect(result.ok, id).toBe(false)
      expect(result.refusal, id).toBe('not-granted')
    }
  })

  /**
   * Unticking a box lands on the **next tool call**, not on the next reconnect.
   *
   * The shape of this test is the whole of its value, so it is worth saying why
   * it is written this way rather than the shorter way.
   *
   * `remoteCopilotCaller` returns a plain `Caller` — a *snapshot* of the tiers at
   * the moment it was called. That is correct, and it is why the live property
   * cannot live in that function: what re-reads the store is the **caller
   * function on the token-table entry**, which `deck-control/server.ts` invokes
   * per request (`grant.caller()`, never captured) and which `copilot-runs.ts`
   * registers as `() => remoteCopilotCaller(grants, deviceId)`.
   *
   * So the entry is modelled here exactly as a live run registers it, and it is
   * resolved twice across a revoke. Holding one `Caller` object across the
   * revoke instead would test the opposite thing — it would assert that a
   * snapshot goes stale, which is true, uninteresting, and would go green on a
   * build where the transport had captured the caller once at hello and lost the
   * property entirely.
   */
  it('refuses on the next call after the grant is taken away, with no restart', async () => {
    const grants = new CopilotGrants(dir)
    grants.set('phone-1', { read: true, act: true })
    const deck = control()
    // The token-table entry, as `CopilotRuns.start` builds it.
    const entry = { attended: true, caller: () => remoteCopilotCaller(grants, 'phone-1') }

    const before = await deck.call('sessions.list', {}, { caller: entry.caller() })
    expect(before.ok).toBe(true)

    grants.forget('phone-1')

    const after = await deck.call('sessions.list', {}, { caller: entry.caller() })
    expect(after.ok).toBe(false)
    expect(after.refusal).toBe('not-granted')
  })

  /**
   * `alter` cannot be reached even by a device that holds everything the panel
   * can give it.
   *
   * The two boxes in Settings are the whole of what is grantable, so this is the
   * strongest grant that can exist — and it still cannot write a setting. That
   * is `REMOTE_GRANTABLE_TIERS` doing its job at the point of dispatch rather
   * than at the point of storage, which is what makes it a boundary instead of a
   * default.
   */
  it('refuses alter even for a phone holding every grantable tier', async () => {
    const grants = new CopilotGrants(dir)
    grants.set('phone-1', Object.fromEntries(REMOTE_GRANTABLE_TIERS.map((tier) => [tier, true])))
    const deck = control()
    const caller = remoteCopilotCaller(grants, 'phone-1')
    expect(caller.tiers.alter).toBe(false)

    const alter = buildCatalogue().filter((spec) => spec.tier === 'alter')
    expect(alter.length).toBeGreaterThan(0)
    for (const spec of alter) {
      const result = await deck.call(spec.id, {}, { caller })
      expect(result.ok, spec.id).toBe(false)
      expect(result.refusal, spec.id).toBe('not-granted')
    }
  })

  /**
   * A hand-edited file cannot mint what the panel cannot.
   *
   * `remote-copilot.json` sits under `<userData>`, which the copilot itself can
   * write until the records fence covers it, so "somebody typed `alter: true`
   * into this file" is a case with a real path to it rather than a hypothetical.
   * The store scrubs it on read; this asserts the scrub survives all the way to
   * the dispatcher, because that is the only place it matters.
   */
  it('ignores an alter tier typed into the store by hand', async () => {
    writeFileSync(
      join(dir, 'remote-copilot.json'),
      `${JSON.stringify({ version: 1, devices: { 'phone-1': { read: true, act: true, alter: true } } })}\n`,
    )
    const grants = new CopilotGrants(dir)
    const deck = control()
    const caller = remoteCopilotCaller(grants, 'phone-1')
    expect(caller.tiers.alter).toBe(false)

    const result = await deck.call('settings.write', { key: 'general.theme', value: 'dark' }, { caller })
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-granted')
  })
})

/* ------------------------------------------------- the transport's own gate */

describe('the transport refuses the frame a phone should not be able to send', () => {
  /**
   * Layer one, stated as what it is.
   *
   * This is the check `server.ts` runs before a `copilot.*` frame reaches a
   * handler, and the assertion is deliberately about the *frame* — the thing a
   * phone can actually construct — rather than about a tool. A read-only device
   * sending `copilot.say` is the exact case: talking to the copilot is
   * `sessions.send` by the time it lands, which is why `say` is `act` and why
   * `read` is worth having as a grant on its own.
   */
  it('allows the watching verbs and refuses the acting ones for a read-only grant', () => {
    const watching = { read: true, act: false }
    for (const [verb, tier] of Object.entries(COPILOT_FRAME_TIER)) {
      expect(copilotFrameAllowed(watching, verb), verb).toBe(tier === 'read')
    }
    // Named explicitly as well as swept, because this one line is the whole
    // argument for the read tier existing and a table walk does not read as an
    // intention.
    expect(copilotFrameAllowed(watching, 'copilot.say')).toBe(false)
    expect(copilotFrameAllowed(watching, 'copilot.start')).toBe(false)
    expect(copilotFrameAllowed(watching, 'copilot.log')).toBe(true)
  })

  it('refuses every verb for a device with no grant at all', () => {
    for (const verb of Object.keys(COPILOT_FRAME_TIER)) {
      expect(copilotFrameAllowed({ read: false, act: false }, verb), verb).toBe(false)
    }
  })

  /**
   * A verb that is not in the table is refused rather than allowed.
   *
   * The table *is* the definition of this capability, so a frame naming
   * something outside it is either a client of a newer protocol or a probe, and
   * both of those get the same answer. The permissive reading — "unknown means
   * it must be harmless" — is how a verb added without a tier ships open.
   */
  it('refuses a verb the tier table has never heard of', () => {
    const everything = { read: true, act: true }
    expect(copilotFrameAllowed(everything, 'copilot.tool')).toBe(false)
    expect(copilotFrameAllowed(everything, 'copilot.approve')).toBe(false)
    expect(copilotFrameAllowed(everything, 'sessions.send')).toBe(false)
  })
})
