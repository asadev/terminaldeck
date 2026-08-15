/**
 * One code, one slot, wherever the code came from.
 *
 * ## The bug this file is written against
 *
 * Two screens mint pairing codes. The Machines screen minted from the pairing
 * desk *and* started a rendezvous beacon; the phone pairing on the Remote panel
 * minted from the same desk and started nothing. Same eight characters, same
 * shape on screen, and only one of them could be typed into another machine —
 * the other fell through to a direct attempt that most people have no route for,
 * and reported that no machine was showing the code. Nothing was broken except
 * the half that had never been wired, and the sentence a person read blamed the
 * relay.
 *
 * So publishing moved onto the desk, and there is deliberately no second way to
 * do it. What is asserted here is that one mechanism and, more importantly, its
 * *end*: a rendezvous slot must not outlive the code it answers for. A code is
 * single-use and dies in sixty seconds; a slot still sitting there afterwards is
 * this machine advertising an address that will refuse whoever dials it, which
 * looks exactly like a broken relay from the other end.
 *
 * Nothing here opens a socket. The beacon seam on `pairingDesk` is the reason it
 * can be a unit test at all — `live.test.ts` runs the same mechanism against a
 * real relay, and `ipc.test.ts` runs the screen on top of it.
 */

import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, relative } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { generateStatic } from '../../../shared/sealed'
import { hostIdFor } from '../../../shared/relay-wire'
import { PAIRING_TTL_MS, RemoteAuth } from '../device-auth'
import { authenticatorFor, pairingDesk, type PairingDesk } from '../server'
import type { Beacon, BeaconOptions, MachineOffer } from './rendezvous'

const dirs: string[] = []

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
})

const OFFER: MachineOffer = {
  relayUrl: 'wss://relay.example',
  hostId: hostIdFor(Buffer.alloc(32, 3)),
  publicKey: generateStatic().publicKey.toString('base64'),
  name: 'This Mac',
  platform: 'darwin',
}

interface Slot {
  options: BeaconOptions
  stopped: boolean
}

interface Desk {
  desk: PairingDesk
  auth: RemoteAuth
  slots: Slot[]
  /** The one slot this machine is sitting in, or null when it is in none. */
  open(): Slot | null
}

function deskWith(options: { claims?: boolean; constructible?: boolean } = {}): Desk {
  const dir = mkdtempSync(join(tmpdir(), 'deck-published-code-'))
  dirs.push(dir)
  const auth = new RemoteAuth(dir)
  const slots: Slot[] = []

  const desk = pairingDesk(auth, Date.now, (beaconOptions): Beacon | null => {
    if (options.constructible === false) return null
    const record: Slot = { options: beaconOptions, stopped: false }
    slots.push(record)
    return {
      stop: () => {
        record.stopped = true
      },
      connected: () => !record.stopped && options.claims !== false,
      ready: () => Promise.resolve(options.claims !== false),
    }
  })

  return {
    desk,
    auth,
    slots,
    open: () => slots.find((slot) => !slot.stopped) ?? null,
  }
}

describe('one mechanism, whichever screen minted the code', () => {
  it('publishes the code it minted, at the relay the offer names', async () => {
    const rig = deskWith()
    const shown = await rig.desk.show(OFFER)

    expect(shown.findable).toBe(true)
    expect(rig.slots).toHaveLength(1)
    // The code that is on screen is the code the slot is derived from. A slot
    // keyed on anything else is a slot nobody can look up.
    expect(rig.slots[0].options.code).toBe(shown.code.token)
    expect(rig.slots[0].options.offer).toEqual(OFFER)
    expect(rig.slots[0].options.relayUrl).toBe(OFFER.relayUrl)
  })

  it('still mints when there is nothing to publish, and says so', async () => {
    /*
     * The QR path, on a machine with no relay link.
     *
     * The pairing link carries this machine's address inside it, so a code that
     * cannot be looked up is still a code that works when it is scanned.
     * Refusing here would take away a pairing that works today in order to
     * protect one that could not have worked anyway — which is why `findable` is
     * reported rather than thrown, and why the two callers answer it
     * differently.
     */
    const rig = deskWith()
    const shown = await rig.desk.show(null)
    expect(shown.code.token).not.toBe('')
    expect(shown.findable).toBe(false)
    expect(rig.slots).toEqual([])
    // Minted means minted: the code is live and will be honoured.
    expect(rig.desk.offers(shown.code.token)).toBe(true)
  })

  it('reports a slot that never came up rather than a code that looks fine', async () => {
    const rig = deskWith({ claims: false })
    const shown = await rig.desk.show(OFFER)
    expect(shown.findable).toBe(false)
    // And the socket it opened on the way does not outlive the attempt.
    expect(rig.slots[0].stopped).toBe(true)
    expect(rig.open()).toBeNull()
  })

  it('reports a beacon that could not even be built', async () => {
    const rig = deskWith({ constructible: false })
    expect((await rig.desk.show(OFFER)).findable).toBe(false)
  })

  it('replaces the slot when a second code is minted, rather than keeping both', async () => {
    const rig = deskWith()
    const first = await rig.desk.show(OFFER)
    const second = await rig.desk.show(OFFER)

    expect(rig.slots).toHaveLength(2)
    // The first code is not honoured any more — one code on screen at a time —
    // so a slot still answering for it would send somebody to a machine that is
    // about to refuse them.
    expect(rig.slots[0].stopped).toBe(true)
    expect(rig.desk.offers(first.code.token)).toBe(false)
    expect(rig.open()?.options.code).toBe(second.code.token)
  })
})

describe('the slot dies with the code', () => {
  it('when the code is cancelled', async () => {
    const rig = deskWith()
    await rig.desk.show(OFFER)
    rig.desk.cancel()
    expect(rig.open()).toBeNull()
  })

  it('when the code is redeemed, not sixty seconds later', async () => {
    /*
     * The path a real phone takes, through the real authenticator.
     *
     * A pairing token is single use and is burned the instant it matches, so
     * every second the slot stays up afterwards is a slot pointing at a machine
     * that will now refuse the code it is advertising. Nothing calls
     * `machines:code:cancel` on this path — the desk is cancelled from inside
     * the authenticator — which is exactly why the rendezvous had to move onto
     * the desk rather than sit beside one of the screens.
     */
    const rig = deskWith()
    const shown = await rig.desk.show(OFFER)

    const outcome = await authenticatorFor(rig.auth, rig.desk).authenticate(
      shown.code.token,
      { name: 'A phone', platform: 'ios' },
      '100.64.0.2',
      generateStatic().publicKey,
    )
    // Paired and deliberately not admitted: the credential travels, the device
    // waits for a human. Either way the code is spent.
    expect(outcome.ok).toBe(false)
    expect(rig.auth.listDevices()).toHaveLength(1)
    expect(rig.open()).toBeNull()
  })

  it('when the code runs out of guesses', async () => {
    const rig = deskWith()
    await rig.desk.show(OFFER)
    // Five wrong answers kill the code wherever they came from. The slot goes
    // with it, or the next person to type the right characters would be sent to
    // a machine that has already stopped honouring them.
    for (let attempt = 0; attempt < 5; attempt++) rig.desk.offers('ZZZZ-ZZZZ')
    expect(rig.desk.open()).toBe(false)
    expect(rig.open()).toBeNull()
  })

  it('when the code expires, with nobody asking', async () => {
    vi.useFakeTimers()
    try {
      const rig = deskWith()
      await rig.desk.show(OFFER)
      expect(rig.open()).not.toBeNull()

      /*
       * Nothing is called here. That is the assertion.
       *
       * The desk's own expiry check only runs when something asks it a
       * question, and on a machine nobody is pairing with the next question may
       * be minutes away — minutes of a live slot for a dead code. One timer,
       * armed by the code that created it and cleared by every other way that
       * code can end. Not a poll: nothing runs when nobody is pairing.
       */
      vi.advanceTimersByTime(PAIRING_TTL_MS + 1)
      expect(rig.open()).toBeNull()
    } finally {
      vi.useRealTimers()
    }
  })

  it('when the code is cancelled while its slot is still being claimed', async () => {
    // The race with a person in it: Close pressed during the second the beacon
    // takes to dial. Whoever ends the code has already stopped everything it
    // knows about, so the beacon that lands afterwards has to stop itself or it
    // is a socket nothing owns.
    const dir = mkdtempSync(join(tmpdir(), 'deck-published-code-'))
    dirs.push(dir)
    const slots: Slot[] = []
    let release: (claimed: boolean) => void = () => {}
    const desk = pairingDesk(new RemoteAuth(dir), Date.now, (beaconOptions): Beacon => {
      const record: Slot = { options: beaconOptions, stopped: false }
      slots.push(record)
      return {
        stop: () => {
          record.stopped = true
        },
        connected: () => !record.stopped,
        ready: () => new Promise<boolean>((settle) => (release = settle)),
      }
    })

    const showing = desk.show(OFFER)
    await vi.waitFor(() => expect(slots).toHaveLength(1))
    desk.cancel()
    release(true)

    expect((await showing).findable).toBe(false)
    expect(slots[0].stopped).toBe(true)
  })
})

/**
 * A source file with its comments taken out.
 *
 * The search below is for a *call*, and this file's own prose explains the call
 * it is banning — as does the handler in `server.ts`. A guard that cannot tell
 * an explanation from an occurrence would fail on the sentence describing the
 * bug it exists to prevent, which is the fastest way to get a guard deleted.
 *
 * `//` is only treated as a comment at the start of a line or after whitespace,
 * so the `wss://` in a relay URL survives it.
 */
function code(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|\s)\/\/.*$/gm, '')
}

describe('there is no second way to mint a code', () => {
  it('nothing that ships calls create() instead of show()', () => {
    /*
     * A string search, because that is what this failure was.
     *
     * `desk.create()` mints a code and publishes nothing, which is precisely the
     * defect: two callers, one of them skipping the half that makes eight typed
     * characters findable. It stays on the interface for the fixtures in these
     * test files, which mint against a desk with no relay behind it — and a
     * shipping caller of it would be the same bug growing back, silently, in a
     * form that type-checks and passes every other test in the repository.
     */
    // `src`, every subdirectory of it: the desk is handed to the Electron main
    // process and to the headless host, and a caller in either is a caller that
    // ships.
    const src = join(__dirname, '..', '..', '..')
    const offenders: string[] = []
    const walk = (dir: string): void => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const full = join(dir, entry.name)
        if (entry.isDirectory()) walk(full)
        else if (/\.tsx?$/.test(entry.name) && !entry.name.includes('.test.')) {
          if (/\bdesk\.create\s*\(/.test(code(readFileSync(full, 'utf8')))) {
            offenders.push(relative(src, full))
          }
        }
      }
    }
    walk(src)
    expect(offenders).toEqual([])
  })
})
