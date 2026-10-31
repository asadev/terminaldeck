import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ActionLog } from '../deck-control/action-log'
import { buildCatalogue } from '../deck-control/catalogue'
import { ConsentBroker } from '../deck-control/consent'
import { DeckControl } from '../deck-control/control'
import type { DeckSurface, Tier, TierGrant } from '../deck-control/surface'
import { CopilotAccess, FULL_TIERS, remoteCopilotCaller } from './copilot-access'
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
 * is the first one: a caller holding the watching grant, asking for every tool
 * the catalogue declares above that tier, and being told `not-granted` every
 * time — *without* the transport being involved at all.
 *
 * ## Where the grants in this file come from, since 2026-08-19
 *
 * Two places, deliberately, and the split is worth reading before the tests are.
 *
 * The ones that matter to the product come from a real {@link CopilotAccess}
 * built the way `index.ts` builds it, off a device's **kind**: one of his own
 * devices gets everything, a guest gets nothing, and there is no third answer
 * and no ceremony in between. The separate copilot connection those fixtures
 * used to perform — mint a six-digit code at the desk, redeem it, let the tiers
 * travel with it — is gone, and `copilot-access.ts` argues why it was proving a
 * fact that pairing had already proved.
 *
 * The ones that hold a *partial* grant come from {@link narrowed}, a four-line
 * stub, because nothing in the product can produce one any more. The tier check
 * they exercise is real and still runs on every dispatch; see that helper for
 * the full argument for keeping them.
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
 * Access, produced the only way the product produces it: from a device's kind.
 *
 * This is the whole of the fixture now, and the shrinkage is the point. It used
 * to mint a six-digit copilot code at the desk, redeem it against a store on
 * disk, and assert the redemption worked — three lines of ceremony standing in
 * for a second act of authorisation. There is no such act any more: pairing a
 * device as **My device** already is one, it is minted at this keyboard, typed
 * at the other end, and cannot be changed afterwards without pairing again.
 * `copilot-access.ts` carries that argument and the one it superseded.
 *
 * So there is nothing to construct but the question itself. A `Set` rather than
 * a list because one test below revokes a device mid-flight, and the live
 * re-read is exactly what it is proving.
 */
function access(mine: ReadonlySet<string> = new Set(['phone-1'])): CopilotAccess {
  return new CopilotAccess({ isMine: (deviceId) => mine.has(deviceId) })
}

/**
 * A **narrowed** grant, which only a test can make.
 *
 * What is being tested through this is real and still runs on every call:
 * `DeckControl.call` refuses a tool whose tier the caller does not hold. That
 * check has not moved and is not weaker than it was.
 *
 * What has gone is any way for the *product* to produce a partial remote grant.
 * A device is one of his or it is a guest; the first gets {@link FULL_TIERS} and
 * the second gets nothing, and there is deliberately no screen, no file and no
 * frame that produces anything in between — see `copilot-access.ts`, which
 * argues that a tick box between the two was proving the same fact twice.
 *
 * The alternative to this stub was deleting the tests below, which would mean
 * deleting the coverage of a check that still runs on every tool call, against
 * the day somebody reintroduces a narrower caller from a different transport.
 * `remoteCopilotCaller` takes `Pick<CopilotAccess, 'granted'>` precisely so that
 * the thing under test is the tier check rather than the store the tiers came
 * from, and a four-line object is a smaller lie than a green suite that has
 * stopped checking.
 */
function narrowed(tiers: Partial<TierGrant>): Pick<CopilotAccess, 'granted'> {
  const grant: TierGrant = Object.freeze({ read: false, act: false, alter: false, ...tiers })
  return { granted: () => grant }
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-copilot-enforce-'))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})


/* -------------------------------------------------------- the tier check -- */

describe('a caller cannot reach a tool above its grant', () => {
  /**
   * The proof obligation `COPILOT-REMOTE.md` §3 writes out, driven off the
   * catalogue.
   *
   * Every tool that declares `act` or `alter` is asked for by a caller built the
   * only way the transport is allowed to build one — through
   * {@link remoteCopilotCaller} — holding `read` and nothing else. All of them
   * must come back `not-granted`, and the log row must say so, because the row
   * is what the device is shown as a refusal in the copilot's own words.
   *
   * The grant comes from {@link narrowed} rather than from a real
   * {@link CopilotAccess}, and that helper says at length why: the tier check is
   * what is under test here, and the product no longer has a way to hand a
   * remote caller a partial grant.
   */
  it('refuses every act and alter tool in the catalogue', async () => {
    const deck = control()
    const caller = remoteCopilotCaller(narrowed({ read: true }), 'phone-1')

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
  it('lets the same caller reach a read tool', async () => {
    const deck = control()

    const caller = remoteCopilotCaller(narrowed({ read: true }), 'phone-1')
    const result = await deck.call('sessions.list', {}, { caller })
    expect(result.ok).toBe(true)
    expect(result.refusal).toBeNull()
  })

  /**
   * **A guest reaches nothing at all**, from a real {@link CopilotAccess}.
   *
   * This is the headline property of the whole design and it is asserted at the
   * layer that matters — the dispatcher, not the transport. `phone-2` is exactly
   * the shape of a device somebody was lent: `RemoteAuth` would let it open a
   * channel and start terminals in the folder it was given all day. Its kind is
   * `guest`, so `CopilotAccess.granted` answers nothing for it and every tool
   * — *including the read ones* — is refused.
   *
   * The read tools are the important half. A device that could call
   * `sessions.list` through the copilot would have copilot reach: less of it
   * than `act`, but not none, and "not none" is what *"the copilot is never
   * shared"* refuses. So the sweep is the **whole** catalogue rather than the
   * part above some tier, which is what makes this a different assertion from
   * every other one in this file.
   *
   * A second device is one of his in the same store, so the refusal is about
   * this device's kind rather than about a question that answers no to everyone.
   */
  it('gives a guest device nothing, and refuses every tool it asks for', async () => {
    const deck = control()
    const links = access(new Set(['phone-1']))
    const caller = remoteCopilotCaller(links, 'phone-2')
    expect(caller.tiers).toEqual({ read: false, act: false, alter: false })
    expect(links.linked('phone-2')).toBe(false)

    const everything = buildCatalogue()
    // The same guard on the guard as above: an empty catalogue would make every
    // assertion below vacuous and this file would report a boundary it never
    // touched.
    expect(everything.length).toBeGreaterThan(3)
    for (const spec of everything) {
      const result = await deck.call(spec.id, {}, { caller })
      expect(result.ok, `${spec.id} was not refused`).toBe(false)
      expect(result.refusal, `${spec.id} was refused for the wrong reason`).toBe('not-granted')
    }
  })

  /**
   * **One of his own devices holds all three, with nothing else having
   * happened.**
   *
   * The other half of the same fact, and the assertion that would have gone red
   * on every build of the design this replaced. Nothing is minted, nothing is
   * typed, nothing is redeemed and nothing is written to disk: the device was
   * approved as his, and that is the entire ceremony. `alter` is in the list, so
   * this device can answer its own confirmations — which is what
   * `copilot-access.ts` argues the approval screen's own wording already told
   * the person handing it over.
   *
   * Swept over {@link FULL_TIERS} rather than written out as three names, so
   * that a tier added to that literal without being reachable through
   * `granted()` fails here rather than in somebody's hands. Not swept over
   * `TIERS`: the whole reason `FULL_TIERS` is a frozen literal is that a fourth
   * tier added to `deck-control` must **not** become remotely grantable by
   * existing, and a test walking `TIERS` would demand exactly that.
   */
  it('gives one of his own devices every tier FULL_TIERS names, including alter', () => {
    const links = access()
    const caller = remoteCopilotCaller(links, 'phone-1')

    expect(links.linked('phone-1')).toBe(true)
    expect(caller.tiers).toEqual(FULL_TIERS)
    expect(caller.tiers.alter).toBe(true)
    for (const tier of Object.keys(FULL_TIERS) as Tier[]) {
      expect(caller.tiers[tier], tier).toBe(true)
    }
  })

  /**
   * Revoking a device lands on the **next tool call**, not on the next
   * reconnect.
   *
   * The shape of this test is the whole of its value, so it is worth saying why
   * it is written this way rather than the shorter way.
   *
   * `remoteCopilotCaller` returns a plain `Caller` — a *snapshot* of the tiers at
   * the moment it was called. That is correct, and it is why the live property
   * cannot live in that function: what re-reads access is the **caller function
   * on the token-table entry**, which `deck-control/server.ts` invokes per
   * request (`grant.caller()`, never captured) and which `copilot-runs.ts`
   * registers as `() => remoteCopilotCaller(links, deviceId)`.
   *
   * So the entry is modelled here exactly as a live run registers it, and it is
   * resolved twice across the revocation. Holding one `Caller` object across it
   * instead would test the opposite thing — it would assert that a snapshot goes
   * stale, which is true, uninteresting, and would go green on a build where the
   * transport had captured the caller once at hello and lost the property
   * entirely.
   *
   * What changed with the store's departure is the *event*. There is no
   * "disconnect the copilot" any more, because there is no separate connection
   * to disconnect: revoking the **device** is the one remedy, and it drops the
   * kind record, which is what the `isMine` callback reads. That makes the live
   * re-read matter more than it did rather than less — it is now the only thing
   * standing between a revoked phone and the run it left behind.
   */
  it('refuses on the next call after the device is revoked, with no restart', async () => {
    const mine = new Set(['phone-1'])
    const links = access(mine)
    const deck = control()
    // The token-table entry, as `CopilotRuns.start` builds it.
    const entry = { attended: true, caller: () => remoteCopilotCaller(links, 'phone-1') }

    const before = await deck.call('sessions.list', {}, { caller: entry.caller() })
    expect(before.ok).toBe(true)

    // What `remote:device:revoke` does, as far as this layer can see it: the
    // kind is gone, so the device is a guest on the very next question.
    mine.delete('phone-1')

    const after = await deck.call('sessions.list', {}, { caller: entry.caller() })
    expect(after.ok).toBe(false)
    expect(after.refusal).toBe('not-granted')
  })

  /**
   * `alter` is reachable, and reaching it still means a person said yes.
   *
   * This assertion is the inverse of the one it replaced twice over. The
   * original file proved that a device holding every grantable tier *still*
   * could not write a setting, because `alter` was not grantable at all; the
   * argument was that the tier's safety property is a human at the machine
   * saying yes and the party holding the phone is not that human.
   *
   * What changed is not the safety property, it is what stands behind it. For
   * two days that was a separate copilot connection with its own code; it is now
   * the kind chosen when the device was approved, which has every property the
   * code was minted to have and one the code did not — it cannot be changed
   * without pairing again. `copilot-access.ts` carries both arguments.
   *
   * So the tier check passes, and the call still only succeeds because the
   * broker in {@link control} answers yes. The row records that a confirmation
   * was required and granted, which is what keeps "authorised by a person" and
   * "allowed by a rule" different rows in the log.
   */
  it('lets one of his own devices reach an alter tool, through the gate', async () => {
    const links = access()
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
   * Narrowed through {@link narrowed} for the reason that helper gives — no
   * remote caller in the shipped product holds `act` without `alter` any more,
   * and `DeckControl.call` does not know or care where its caller came from.
   * The ladder between the tiers is checked on every dispatch from every
   * transport, including the desk's own, so a test that stopped exercising it
   * because one transport can no longer produce the input would be leaving the
   * check itself unwatched.
   */
  it('refuses an alter tool for a caller that holds only read and act', async () => {
    const deck = control()
    const caller = remoteCopilotCaller(narrowed({ read: true, act: true }), 'phone-1')

    const alter = buildCatalogue().filter((spec) => spec.tier === 'alter')
    expect(alter.length).toBeGreaterThan(0)
    for (const spec of alter) {
      const result = await deck.call(spec.id, {}, { caller })
      expect(result.ok, spec.id).toBe(false)
      expect(result.refusal, spec.id).toBe('not-granted')
    }
  })

  /**
   * A kind store that cannot answer is a guest, not a grant.
   *
   * This is what became of the test above it, which used to write a grant into
   * `copilot-link.json` by hand and prove the store ignored it. There is no such
   * file any more, so the hypothetical it defended against — *somebody typed a
   * permission into a file under `<userData>`* — has moved one module along, to
   * `remote-device-kinds.json`. `device-kind.ts` owns that surface and its own
   * tests own the parsing, so what is left to check here is the seam: the
   * question this file asks reaches a file on disk, a file on disk can be
   * missing, truncated or unreadable, and a throw crossing that line would land
   * inside a decision about whether to dispatch a tool.
   *
   * It fails closed in the same direction as everything else, and the reason it
   * is worth an assertion rather than a comment is that the safe answer and the
   * convenient answer point in opposite directions here: a `catch` that
   * swallowed and returned the last known value would look reasonable in review
   * and would hand a revoked phone a grant.
   */
  it('refuses when the kind store throws rather than answers', async () => {
    const links = new CopilotAccess({
      isMine: () => {
        throw new Error('remote-device-kinds.json is not readable')
      },
    })
    const deck = control()
    const caller = remoteCopilotCaller(links, 'phone-1')
    expect(caller.tiers).toEqual({ read: false, act: false, alter: false })
    expect(links.linked('phone-1')).toBe(false)

    const result = await deck.call('sessions.list', {}, { caller })
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-granted')
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
   * The untiered frames are in this list too, and that is not an oversight to be
   * tidied. `copilot.hello` and `copilot.bye` open and close the stream and
   * reach `server.ts` by a different door; asking this function about them must
   * not allow them on the strength of a grant they exist to establish. There
   * were three of them until `copilot.connect` was deleted with the copilot's
   * separate credential, and the list is swept rather than named here so that
   * arithmetic never needs repeating in a test.
   */
  it('refuses a verb the tier table has never heard of, including hello and bye', () => {
    const everything = { read: true, act: true, alter: true }
    expect(copilotFrameAllowed(everything, 'copilot.tool')).toBe(false)
    expect(copilotFrameAllowed(everything, 'copilot.approve')).toBe(false)
    expect(copilotFrameAllowed(everything, 'sessions.send')).toBe(false)
    for (const verb of COPILOT_UNTIERED_FRAMES) {
      expect(copilotFrameAllowed(everything, verb), verb).toBe(false)
    }
  })
})
