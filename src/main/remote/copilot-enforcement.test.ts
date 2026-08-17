import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ActionLog } from '../deck-control/action-log'
import { buildCatalogue } from '../deck-control/catalogue'
import { ConsentBroker } from '../deck-control/consent'
import { DeckControl } from '../deck-control/control'
import type { DeckSurface } from '../deck-control/surface'
import { CopilotLinks, REMOTE_GRANTABLE_TIERS, remoteCopilotCaller } from './copilot-link'
import { copilotFrameAllowed } from './copilot-remote'
import { COPILOT_FRAME_TIER, COPILOT_UNTIERED_FRAMES } from './protocol'

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

/**
 * A store with one device **connected to the copilot**, the way a person does it.
 *
 * Not `set()`, and the difference is the whole revision this file was rewritten
 * for. Copilot access is no longer a box ticked beside a paired device; it is a
 * separate connection with its own code and its own credential, and
 * `CopilotLinks.set` refuses to create a record precisely so that a panel cannot
 * be a second door onto it. A test that reached for `set()` on an unconnected
 * device would be testing a path the product does not have.
 *
 * So every fixture here mints a code at the desk and redeems it, which is what
 * the ceremony is, and the tiers travel with the code because that is where the
 * decision is made.
 */
async function connected(tiers: Record<string, boolean>, deviceId = 'phone-1'): Promise<CopilotLinks> {
  const links = new CopilotLinks(dir)
  const offer = links.offer(tiers)
  const outcome = await links.redeem(offer.code, deviceId)
  expect(outcome.ok, 'the fixture failed to connect a device').toBe(true)
  return links
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-copilot-enforce-'))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})


/* -------------------------------------------------------- the tier check -- */

describe('a watching connection cannot reach a tool above its grant', () => {
  /**
   * The proof obligation `COPILOT-REMOTE.md` §3 writes out, driven off the
   * catalogue.
   *
   * Every tool that declares `act` or `alter` is asked for by a caller built the
   * only way the transport is allowed to build one — through
   * {@link remoteCopilotCaller} — from a store in which this device's copilot
   * connection holds `read` and nothing else. All of them must come back
   * `not-granted`, and the log row must say so, because the row is what the
   * device is shown as a refusal in the copilot's own words.
   */
  it('refuses every act and alter tool in the catalogue', async () => {
    const links = await connected({ read: true })
    const deck = control()
    const caller = remoteCopilotCaller(links, 'phone-1')

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
      // The row carries the device, because "which of my devices did that" has
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
  it('lets the same connection reach a read tool', async () => {
    const links = await connected({ read: true })
    const deck = control()

    const result = await deck.call('sessions.list', {}, { caller: remoteCopilotCaller(links, 'phone-1') })
    expect(result.ok).toBe(true)
    expect(result.refusal).toBeNull()
  })

  /**
   * **A device paired for sessions has no copilot reach.**
   *
   * This is the headline property of the whole revision and it is asserted at
   * the layer that matters — the dispatcher, not the transport. `phone-2` is
   * exactly the shape of a device that has been paired, approved, and given
   * folders: `RemoteAuth` would let it open a channel and start terminals all
   * day. It has simply never redeemed a copilot code, so `CopilotLinks.granted`
   * answers nothing for it and every tool, *including the read ones*, is
   * refused.
   *
   * The read tools are the important half. A device that could call
   * `sessions.list` through the copilot would have copilot reach — less of it
   * than `act`, but not none, and "not none" is what this design exists to
   * refuse.
   */
  it('refuses a device that is paired but has never connected the copilot', async () => {
    // A real store with a *different* device connected, so the refusal is about
    // this device rather than about an empty file.
    const links = await connected({ read: true, act: true, alter: true }, 'phone-1')
    const deck = control()
    const caller = remoteCopilotCaller(links, 'phone-2')
    expect(caller.tiers).toEqual({ read: false, act: false, alter: false })

    for (const id of ['sessions.list', 'sessions.send', 'settings.write']) {
      const result = await deck.call(id, {}, { caller })
      expect(result.ok, id).toBe(false)
      expect(result.refusal, id).toBe('not-granted')
    }
  })

  /**
   * Disconnecting lands on the **next tool call**, not on the next reconnect.
   *
   * The shape of this test is the whole of its value, so it is worth saying why
   * it is written this way rather than the shorter way.
   *
   * `remoteCopilotCaller` returns a plain `Caller` — a *snapshot* of the tiers at
   * the moment it was called. That is correct, and it is why the live property
   * cannot live in that function: what re-reads the store is the **caller
   * function on the token-table entry**, which `deck-control/server.ts` invokes
   * per request (`grant.caller()`, never captured) and which `copilot-runs.ts`
   * registers as `() => remoteCopilotCaller(links, deviceId)`.
   *
   * So the entry is modelled here exactly as a live run registers it, and it is
   * resolved twice across a disconnect. Holding one `Caller` object across the
   * disconnect instead would test the opposite thing — it would assert that a
   * snapshot goes stale, which is true, uninteresting, and would go green on a
   * build where the transport had captured the caller once at hello and lost the
   * property entirely.
   */
  it('refuses on the next call after the copilot is disconnected, with no restart', async () => {
    const links = await connected({ read: true, act: true })
    const deck = control()
    // The token-table entry, as `CopilotRuns.start` builds it.
    const entry = { attended: true, caller: () => remoteCopilotCaller(links, 'phone-1') }

    const before = await deck.call('sessions.list', {}, { caller: entry.caller() })
    expect(before.ok).toBe(true)

    links.disconnect('phone-1')

    const after = await deck.call('sessions.list', {}, { caller: entry.caller() })
    expect(after.ok).toBe(false)
    expect(after.refusal).toBe('not-granted')
  })

  /**
   * `alter` is reachable now, and reaching it still means a person said yes.
   *
   * This assertion is the inverse of the one it replaced. The old file proved
   * that a device holding every grantable tier *still* could not write a
   * setting, because `alter` was not grantable at all; the argument was that the
   * tier's safety property is a human at the machine saying yes and the party
   * holding the phone is not that human.
   *
   * What changed is not the safety property, it is what stands behind it — see
   * `copilot-link.ts`. So the tier check now passes, and the call still only
   * succeeds because the broker in {@link control} answers yes. The row records
   * that a confirmation was required and granted, which is what keeps
   * "authorised by a person" and "allowed by a rule" different rows in the log.
   */
  it('lets a connection holding alter reach an alter tool, through the gate', async () => {
    const links = await connected({ read: true, act: true, alter: true })
    const deck = control()
    const caller = remoteCopilotCaller(links, 'phone-1')
    expect(caller.tiers.alter).toBe(true)

    const result = await deck.call(
      'settings.write',
      { scope: 'settings', patch: { 'appearance.density': 'compact' } },
      { caller },
    )
    expect(result.ok, result.error ?? '').toBe(true)
    expect(result.row.confirmed.required).toBe(true)
    expect(result.row.confirmed.granted).toBe(true)
  })

  /**
   * And the tier is still a tier: `act` is not `alter`.
   *
   * The whole point of keeping tiers as a concept once `alter` became grantable
   * is that somebody can connect a device read-only, or connect it to work but
   * not to change things. If this went green with `act` alone, the three
   * checkboxes on the settings panel would be decoration.
   */
  it('refuses an alter tool for a connection that holds only act', async () => {
    const links = await connected({ read: true, act: true })
    const deck = control()
    const caller = remoteCopilotCaller(links, 'phone-1')

    const alter = buildCatalogue().filter((spec) => spec.tier === 'alter')
    expect(alter.length).toBeGreaterThan(0)
    for (const spec of alter) {
      const result = await deck.call(spec.id, {}, { caller })
      expect(result.ok, spec.id).toBe(false)
      expect(result.refusal, spec.id).toBe('not-granted')
    }
  })

  /**
   * A hand-edited file cannot mint a connection.
   *
   * `copilot-link.json` sits under `<userData>`, which the copilot itself can
   * write until the records fence covers it, so "somebody typed a grant into
   * this file" is a case with a real path to it rather than a hypothetical.
   *
   * The rule that replaced the `alter` scrub: **no credential, no link.** A
   * record with tiers and no credential is a grant with no connection behind it,
   * which is exactly the shape this design replaced, and it is dropped on read
   * rather than repaired — there is no honest way to invent the second factor
   * for somebody. What the old scrub protected against is now protected against
   * by there being nothing to scrub: the tiers are real, and the thing that
   * makes them reachable is a credential this file cannot forge.
   */
  it('ignores a connection typed into the store by hand with no credential', async () => {
    writeFileSync(
      join(dir, 'copilot-link.json'),
      `${JSON.stringify({
        version: 1,
        links: { 'phone-1': { connectedAt: 1, lastSeenAt: null, tiers: { read: true, act: true, alter: true } } },
      })}\n`,
    )
    const links = new CopilotLinks(dir)
    const deck = control()
    const caller = remoteCopilotCaller(links, 'phone-1')
    expect(caller.tiers).toEqual({ read: false, act: false, alter: false })
    expect(links.linked('phone-1')).toBe(false)

    const result = await deck.call('sessions.list', {}, { caller })
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-granted')
  })

  /**
   * Every tier the ceiling names is genuinely reachable.
   *
   * A sweep rather than three named cases, so that a fourth tier added to
   * `deck-control` and added to {@link REMOTE_GRANTABLE_TIERS} without being
   * plumbed through the store fails here rather than in somebody's hands.
   */
  it('stores and returns every tier in the ceiling', async () => {
    const links = await connected(Object.fromEntries(REMOTE_GRANTABLE_TIERS.map((tier) => [tier, true])))
    const caller = remoteCopilotCaller(links, 'phone-1')
    for (const tier of REMOTE_GRANTABLE_TIERS) {
      expect(caller.tiers[tier], tier).toBe(true)
    }
  })
})

/* ------------------------------------------------- the transport's own gate */

describe('the transport refuses the frame a device should not be able to send', () => {
  /**
   * Layer one, stated as what it is.
   *
   * This is the check `server.ts` runs before a `copilot.*` frame reaches a
   * handler, and the assertion is deliberately about the *frame* — the thing a
   * device can actually construct — rather than about a tool. A read-only
   * connection sending `copilot.say` is the exact case: talking to the copilot
   * is `sessions.send` by the time it lands, which is why `say` is `act` and why
   * `read` is worth having as a grant on its own.
   */
  it('allows the watching verbs and refuses the acting ones for a read-only grant', () => {
    const watching = { read: true, act: false, alter: false }
    for (const [verb, tier] of Object.entries(COPILOT_FRAME_TIER)) {
      expect(copilotFrameAllowed(watching, verb), verb).toBe(tier === 'read')
    }
    // Named explicitly as well as swept, because these lines are the whole
    // argument for the tiers existing and a table walk does not read as an
    // intention.
    expect(copilotFrameAllowed(watching, 'copilot.say')).toBe(false)
    expect(copilotFrameAllowed(watching, 'copilot.start')).toBe(false)
    expect(copilotFrameAllowed(watching, 'copilot.answer')).toBe(false)
    expect(copilotFrameAllowed(watching, 'copilot.log')).toBe(true)
  })

  /**
   * **The frame a device should not be able to send**, named on its own.
   *
   * Answering a confirmation is `alter`, and a connection that may not perform
   * alter-tier work has no business deciding whether alter-tier work happens.
   * Without this line, `read` would be a way to authorise everything `act`
   * refuses — the sharpest version of the mistake OpenClaw shipped as
   * GHSA-943q-mwmv-hhvh, where the gate was on the tool name rather than on the
   * effect.
   */
  it('refuses copilot.answer for every grant below alter', () => {
    expect(copilotFrameAllowed({ read: true, act: false, alter: false }, 'copilot.answer')).toBe(false)
    expect(copilotFrameAllowed({ read: true, act: true, alter: false }, 'copilot.answer')).toBe(false)
    expect(copilotFrameAllowed({ read: true, act: true, alter: true }, 'copilot.answer')).toBe(true)
  })

  it('refuses every verb for a device with no grant at all', () => {
    for (const verb of Object.keys(COPILOT_FRAME_TIER)) {
      expect(copilotFrameAllowed({ read: false, act: false, alter: false }, verb), verb).toBe(false)
    }
  })

  /**
   * A verb that is not in the table is refused rather than allowed.
   *
   * The table *is* the definition of the tiered surface, so a frame naming
   * something outside it is either a client of a newer protocol or a probe, and
   * both of those get the same answer. The permissive reading — "unknown means
   * it must be harmless" — is how a verb added without a tier ships open.
   *
   * The three untiered frames are in this list too, and that is not an oversight
   * to be tidied. `copilot.connect`, `copilot.hello` and `copilot.bye` are the
   * authorisation ceremony and reach `server.ts` by a different door; asking
   * this function about them must not allow them on the strength of a grant they
   * exist to establish.
   */
  it('refuses a verb the tier table has never heard of, including the ceremony', () => {
    const everything = { read: true, act: true, alter: true }
    expect(copilotFrameAllowed(everything, 'copilot.tool')).toBe(false)
    expect(copilotFrameAllowed(everything, 'copilot.approve')).toBe(false)
    expect(copilotFrameAllowed(everything, 'sessions.send')).toBe(false)
    for (const verb of COPILOT_UNTIERED_FRAMES) {
      expect(copilotFrameAllowed(everything, verb), verb).toBe(false)
    }
  })
})
