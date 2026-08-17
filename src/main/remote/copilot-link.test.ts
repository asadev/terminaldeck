import { mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { recordsFenceAgrees, recordsFenceList, recordsFencePaths } from '../confine/records'
import {
  COPILOT_CODE_TTL_MS,
  COPILOT_LINK_FILE,
  CopilotLinks,
  MAX_CODE_ATTEMPTS,
  MAX_OPEN_ATTEMPTS,
  REMOTE_GRANTABLE_TIERS,
  copilotGrantFrom,
  remoteCopilotCaller,
} from './copilot-link'

/**
 * The copilot connection: a second act of authorisation, proved to be one.
 *
 * The property every test here serves is the one that replaced *"the alter tier
 * cannot be granted remotely"*. That rule's argument was good and is preserved
 * in `copilot-link.ts`: the tier's safety property is a human at the machine
 * saying yes, and a dialog answered on the device that raised the request is
 * answered by the party being confirmed.
 *
 * What dissolved it is that the second factor was never really *geography* — a
 * person who walks away from an unlocked Mac has taken their geography with them
 * — it was **having an authorisation the requesting party did not already
 * hold**. So the factor moved to a separate connection: its own code, minted at
 * this machine; its own credential, stored as a hash; its own record. A device
 * paired to run terminals has none of it until somebody deliberately hands it
 * over.
 *
 * Which makes these the tests that matter:
 *
 *  - a paired device with no link is granted nothing, and cannot be granted
 *    anything by a settings write;
 *  - the credential is real, checked, and single-issue;
 *  - disconnecting is immediate and leaves the pairing alone.
 */

let dir: string

beforeEach(() => {
  // Through `realpathSync`, because the fence tests at the bottom compare
  // against paths `confine/records.ts` has resolved: `/var` is a symlink to
  // `/private/var` on macOS, and a comparison between the two spellings fails
  // for a reason that has nothing to do with what is being tested.
  dir = realpathSync(mkdtempSync(join(tmpdir(), 'td-copilot-link-')))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

/** The ceremony, in the order a person performs it. */
async function connect(
  links: CopilotLinks,
  deviceId = 'phone-1',
  tiers: Record<string, boolean> = { read: true, act: true, alter: true },
): Promise<string> {
  const offer = links.offer(tiers)
  const outcome = await links.redeem(offer.code, deviceId)
  if (!outcome.ok) throw new Error(`the fixture could not connect: ${outcome.reason}`)
  return outcome.credential
}

describe('a device paired for sessions has no copilot reach', () => {
  /**
   * The headline property, at the store that answers for it.
   *
   * `phone-2` is exactly the shape of a device `RemoteAuth` would let open a
   * channel and start terminals all day. It has never redeemed a copilot code,
   * so it is granted nothing — including `read`, which is the important half. A
   * device that could watch the copilot would have copilot reach; less of it,
   * and not none.
   */
  it('grants nothing to a device that has never connected', async () => {
    const links = new CopilotLinks(dir)
    await connect(links, 'phone-1')

    expect(links.linked('phone-2')).toBe(false)
    expect(links.granted('phone-2')).toEqual({ read: false, act: false, alter: false })
    expect(remoteCopilotCaller(links, 'phone-2').tiers).toEqual({
      read: false,
      act: false,
      alter: false,
    })
  })

  /**
   * **The settings panel is not a second door.**
   *
   * This is the single most important line in the store, and it is what keeps
   * the separate connection from being decoration: `set()` refuses to *create* a
   * record. A device with no copilot connection cannot be granted anything by
   * ticking a box, because the box is not the authorisation — the connection is.
   *
   * If this went green the other way, the whole revision would collapse back
   * into the per-device grant it replaced, with `alter` now in it.
   */
  it('cannot be given tiers by a settings write alone', () => {
    const links = new CopilotLinks(dir)
    expect(links.set('phone-2', { read: true, act: true, alter: true })).toEqual({
      read: false,
      act: false,
      alter: false,
    })
    expect(links.linked('phone-2')).toBe(false)
    expect(links.list()).toEqual([])
  })

  /**
   * A hand-written record with no credential is not a connection.
   *
   * `copilot-link.json` sits under `<userData>`, which the copilot itself can
   * write until the records fence covers it, so this is a case with a real path
   * to it. It is dropped on read rather than repaired: there is no honest way to
   * invent the second factor for somebody, and a record with tiers and no
   * credential is precisely the shape — a grant with no connection behind it —
   * that this design exists to refuse.
   */
  it('drops a record that was typed in without a credential', () => {
    writeFileSync(
      join(dir, COPILOT_LINK_FILE),
      `${JSON.stringify({
        version: 1,
        links: {
          'phone-9': { connectedAt: 1, lastSeenAt: null, tiers: { read: true, act: true, alter: true } },
        },
      })}\n`,
    )
    const links = new CopilotLinks(dir)
    expect(links.linked('phone-9')).toBe(false)
    expect(links.granted('phone-9')).toEqual({ read: false, act: false, alter: false })
  })
})

describe('the connect code', () => {
  it('hands over the tiers it was minted with, and nothing else', async () => {
    const links = new CopilotLinks(dir)
    const offer = links.offer({ read: true, act: true })
    expect(offer.tiers).toEqual({ read: true, act: true, alter: false })

    const outcome = await links.redeem(offer.code, 'phone-1')
    expect(outcome.ok).toBe(true)
    expect(links.granted('phone-1')).toEqual({ read: true, act: true, alter: false })
  })

  /**
   * Six digits, and a person types them.
   *
   * The shape is the pairing desk's one layer down, deliberately: a person reads
   * a code off this screen and types it into a device they are holding. A second
   * alphabet here would be a second thing to explain for no difference in what
   * anybody does.
   */
  it('is six digits', () => {
    const links = new CopilotLinks(dir)
    expect(links.offer().code).toMatch(/^\d{6}$/)
  })

  it('is single use', async () => {
    const links = new CopilotLinks(dir)
    const offer = links.offer()
    expect((await links.redeem(offer.code, 'phone-1')).ok).toBe(true)
    const again = await links.redeem(offer.code, 'phone-2')
    expect(again.ok).toBe(false)
    expect(links.linked('phone-2')).toBe(false)
  })

  it('is dead after sixty seconds', async () => {
    const clock = { at: 1_000 }
    const links = new CopilotLinks(dir, { now: () => clock.at })
    const offer = links.offer()
    // `>=`, not `>`: a code minted at t with a 60s TTL is dead at t+60000, not
    // alive for one more millisecond.
    clock.at += COPILOT_CODE_TTL_MS
    const outcome = await links.redeem(offer.code, 'phone-1')
    expect(outcome.ok).toBe(false)
    expect(links.linked('phone-1')).toBe(false)
  })

  /**
   * Five wrong guesses kill **the code**, not just the guesser.
   *
   * This is the other half of the entropy argument for six digits, and it is
   * `device-auth.ts`'s reasoning reproduced one layer up: a million codes is
   * enough only because a live one survives five wrong answers, lives sixty
   * seconds and can be used once. Without this, the space would be sweepable
   * inside its own lifetime.
   */
  it('dies after five wrong guesses, even from different devices', async () => {
    const links = new CopilotLinks(dir)
    const offer = links.offer()
    const wrong = offer.code === '000000' ? '111111' : '000000'
    for (let i = 0; i < MAX_CODE_ATTEMPTS; i += 1) {
      await links.redeem(wrong, `guesser-${i}`)
    }
    const outcome = await links.redeem(offer.code, 'phone-1')
    expect(outcome.ok).toBe(false)
    expect(links.linked('phone-1')).toBe(false)
  })

  it('locks a device out after five wrong guesses', async () => {
    const links = new CopilotLinks(dir)
    const wrong = '000000'
    for (let i = 0; i < MAX_CODE_ATTEMPTS; i += 1) await links.redeem(wrong, 'phone-1')
    const offer = links.offer()
    const outcome = await links.redeem(offer.code, 'phone-1')
    expect(outcome.ok).toBe(false)
    if (!outcome.ok) expect(outcome.reason).toBe('rate-limited')
  })
})

describe('the credential', () => {
  it('opens the connection it was issued for, and only that device', async () => {
    const links = new CopilotLinks(dir)
    const credential = await connect(links, 'phone-1')

    expect((await links.open('phone-1', credential)).ok).toBe(true)
    // The credential carries no device id, on purpose: it arrives on a socket
    // that has already proved which device it is. So a leaked one is not a
    // bearer token for the copilot — it is half of a pair.
    const elsewhere = await links.open('phone-2', credential)
    expect(elsewhere.ok).toBe(false)
    if (!elsewhere.ok) expect(elsewhere.reason).toBe('unknown')
  })

  it('refuses a wrong credential for a device that does have a connection', async () => {
    const links = new CopilotLinks(dir)
    await connect(links, 'phone-1')
    const outcome = await links.open('phone-1', 'bm90LXRoZS1yaWdodC1vbmU')
    expect(outcome.ok).toBe(false)
    if (!outcome.ok) expect(outcome.reason).toBe('denied')
  })

  it('locks a device out after five wrong credentials', async () => {
    const links = new CopilotLinks(dir)
    const credential = await connect(links, 'phone-1')
    for (let i = 0; i < MAX_OPEN_ATTEMPTS; i += 1) await links.open('phone-1', 'd3Jvbmc')
    const outcome = await links.open('phone-1', credential)
    expect(outcome.ok).toBe(false)
    if (!outcome.ok) expect(outcome.reason).toBe('rate-limited')
  })

  /**
   * The file holds a hash, never the secret.
   *
   * Which is what makes the file safe to read and what makes "lost it? ask for a
   * new code" the only recovery — re-issuing a credential on request would be a
   * way to get one without the ceremony, and the ceremony is the feature.
   */
  it('is never written to disk', async () => {
    const links = new CopilotLinks(dir)
    const credential = await connect(links, 'phone-1')
    const onDisk = readFileSync(join(dir, COPILOT_LINK_FILE), 'utf8')
    expect(onDisk).not.toContain(credential)
    // What is there instead: a salt, a hash and the scrypt parameters they were
    // produced with, stored per record so they can be raised later without
    // locking out every device connected before the change.
    expect(JSON.parse(onDisk).links['phone-1'].credential).toEqual(
      expect.objectContaining({ salt: expect.any(String), hash: expect.any(String), n: 16384 }),
    )
  })

  it('survives a restart, because the record does', async () => {
    const links = new CopilotLinks(dir)
    const credential = await connect(links, 'phone-1', { read: true, act: true, alter: true })

    const reloaded = new CopilotLinks(dir)
    expect(reloaded.linked('phone-1')).toBe(true)
    expect(reloaded.granted('phone-1')).toEqual({ read: true, act: true, alter: true })
    expect((await reloaded.open('phone-1', credential)).ok).toBe(true)
  })
})

describe('revoking one does not revoke the other', () => {
  /**
   * Disconnecting the copilot is immediate, and it leaves the pairing alone.
   *
   * Two halves, and both are asked for by name in the brief. Immediate, because
   * the grant is read per tool call and per frame, so there is no cached copy to
   * go stale. And separate, because this store is the only thing it touches:
   * nothing here opens `remote-auth.json`, so a device that loses the copilot
   * keeps every terminal it was paired for.
   */
  it('drops the record and the credential with it', async () => {
    const links = new CopilotLinks(dir)
    const credential = await connect(links, 'phone-1')
    expect((await links.open('phone-1', credential)).ok).toBe(true)

    expect(links.disconnect('phone-1')).toBe(true)
    expect(links.linked('phone-1')).toBe(false)
    expect(links.granted('phone-1')).toEqual({ read: false, act: false, alter: false })

    // The same answer a device that never connected gets, so the refusal cannot
    // be used to find out whether a credential was ever real.
    const outcome = await links.open('phone-1', credential)
    expect(outcome.ok).toBe(false)
    if (!outcome.ok) expect(outcome.reason).toBe('unknown')
  })

  /**
   * Unticking every box is **not** disconnecting.
   *
   * A record with all-false tiers still holds a working credential, so the
   * device can still open a connection and be refused everything. That is a real
   * state and it is kept — somebody may want a device connected and idle — but
   * it is deliberately different from having no connection, because one of them
   * still has a credential in a file.
   */
  it('keeps the connection when every tier is unticked', async () => {
    const links = new CopilotLinks(dir)
    const credential = await connect(links, 'phone-1')

    expect(links.set('phone-1', {})).toEqual({ read: false, act: false, alter: false })
    expect(links.linked('phone-1')).toBe(true)
    expect((await links.open('phone-1', credential)).ok).toBe(true)
    expect(links.granted('phone-1')).toEqual({ read: false, act: false, alter: false })
  })

  /**
   * Revoking the device takes the copilot record with it, and that is garbage
   * collection rather than a cascade.
   *
   * Revocation in `device-auth.ts` is permanent and a returning phone pairs
   * again with a *new* id, so a record left behind here could never be opened by
   * anything. Keeping it would mean the file only ever grows and a credential
   * sits in it with nobody's name against it.
   */
  it('forgets the connection when the device itself is revoked', async () => {
    const links = new CopilotLinks(dir)
    await connect(links, 'phone-1')
    expect(links.forget('phone-1')).toBe(true)
    expect(links.linked('phone-1')).toBe(false)
  })
})

describe('the grant rule', () => {
  /**
   * `alter` is grantable, and the ceiling is still a ceiling.
   *
   * `copilot-grants.ts` published this constant as `['read','act']` and called
   * the absence the mechanism. The clamp and the scrub are both gone; what the
   * constant still does is stop a fourth tier added to `deck-control` from
   * becoming remotely grantable by existing.
   */
  it('grants every tier in the ceiling and nothing outside it', () => {
    expect([...REMOTE_GRANTABLE_TIERS]).toEqual(['read', 'act', 'alter'])
    expect(copilotGrantFrom({ read: true, act: true, alter: true })).toEqual({
      read: true,
      act: true,
      alter: true,
    })
    expect(copilotGrantFrom({ read: true, sudo: true } as unknown)).toEqual({
      read: true,
      act: false,
      alter: false,
    })
  })

  /**
   * Only a literal `true` grants, and a non-object grants nothing.
   *
   * Inherited unchanged from the store this replaced, because the reasoning is
   * unchanged: a JSON file a person may edit will eventually contain `"yes"` or
   * `1`, and guessing generously at a permission is how a permission gets
   * widened by a bug in a parser.
   */
  it('reads only a literal true as a grant', () => {
    expect(copilotGrantFrom({ read: 'yes', act: 1, alter: 'true' } as unknown)).toEqual({
      read: false,
      act: false,
      alter: false,
    })
    expect(copilotGrantFrom(true)).toEqual({ read: false, act: false, alter: false })
    expect(copilotGrantFrom(null)).toEqual({ read: false, act: false, alter: false })
  })

  /**
   * An unreadable file is no copilot for anybody.
   *
   * Fails closed, the opposite of `folder-grants.ts` and the right way round: the
   * worst case is that somebody mints a new code at the machine where codes are
   * minted anyway.
   */
  it('fails closed on a damaged file', async () => {
    const links = new CopilotLinks(dir)
    await connect(links, 'phone-1')
    writeFileSync(join(dir, COPILOT_LINK_FILE), '{ not json')
    const reloaded = new CopilotLinks(dir)
    expect(reloaded.linked('phone-1')).toBe(false)
    expect(reloaded.list()).toEqual([])
  })
})

describe('the records fence names this exact file', () => {
  /**
   * The pin that was missing, and whose absence had already cost something.
   *
   * `confine/records.ts` fences five paths and one of them is this store — a
   * copilot that could edit it could raise the tiers of a connection somebody
   * made read-only, turning a device that watches into one that answers
   * confirmations. Nothing pinned the *spelling*, so when the store moved from
   * `remote-copilot.json` to `copilot-link.json` the fence went on naming a file
   * that no longer exists, and a Seatbelt rule over a path nothing writes
   * refuses nothing at all. Silently.
   *
   * `recordsFenceAgrees` exists for exactly this and is called from the module
   * that *owns* each path, rather than the fence importing the store — a
   * confinement module that imported the thing it fences would be the first
   * import a refactor broke. This is that call, from this side.
   */
  it('agrees with the path this store actually writes', () => {
    // `<userData>/remote`, which is what `remoteStorageDir()` hands this class in
    // `main/index.ts`. Constructing it against `<userData>` itself would pin the
    // fence to a path the app never uses, which is the shape of mistake this
    // pair of tests exists to catch.
    const links = new CopilotLinks(join(dir, 'remote'))
    const fenced = recordsFencePaths(dir)
    expect(
      recordsFenceAgrees(fenced, {
        // Owned by other modules; this caller checks only what it owns, which is
        // the whole point of those three being required and these two optional.
        routines: join(dir, 'routines'),
        routineState: join(dir, 'routine-state.json'),
        log: join(dir, 'copilot-log'),
        remoteCopilot: links.file,
      }),
    ).toBe(true)
  })

  it('puts it in the list the fence actually denies writes to', () => {
    const links = new CopilotLinks(join(dir, 'remote'))
    expect(recordsFenceList(recordsFencePaths(dir))).toContain(links.file)
  })
})
