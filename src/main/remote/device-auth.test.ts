import { randomBytes } from 'node:crypto'
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  LOCKOUT_MS,
  MAX_FAILED_ATTEMPTS,
  PAIRING_TTL_MS,
  REMOTE_AUTH_FILE,
  RemoteAuth,
  type Device,
} from './device-auth'
import { isCode } from '../../shared/short-code'

/**
 * These tests are the attacker's half of `auth.ts`. The happy path is two
 * lines; everything else here is a way in that has to stay shut — a token used
 * twice, a token used late, a device that was never approved, a device that was
 * taken away, a file that gives up the credential it was supposed to hash, and
 * a caller that just keeps guessing.
 *
 * Time is injected, never slept. A test that waits for a real 60 seconds does
 * not get written, so expiry would end up untested — and `Date.now()` leaking
 * into one comparison is exactly the bug that makes a token live forever.
 */

const ADDRESS = '100.86.107.119'
const ELSEWHERE = '100.64.0.9'

const dirs: string[] = []

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
  vi.restoreAllMocks()
})

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'terminaldeck-remote-auth-'))
  dirs.push(dir)
  return dir
}

/** An explicit clock. Nothing in these tests waits for the real one. */
function clock(start = 1_760_000_000_000): { now: () => number; advance: (ms: number) => void } {
  let t = start
  return { now: () => t, advance: (ms: number) => (t += ms) }
}

/** A credential for a real device with the wrong secret half. */
function wrongSecret(device: Device): string {
  return `${device.id}.${randomBytes(32).toString('base64url')}`
}

async function pair(
  auth: RemoteAuth,
  name = 'iPhone',
): Promise<{ credential: string; device: Device }> {
  const { token } = auth.createPairingToken()
  const result = await auth.redeemPairingToken(token, name)
  if (!result.ok) throw new Error(`pairing was supposed to succeed, got ${result.reason}`)
  return { credential: result.credential, device: result.device }
}

async function paired(auth: RemoteAuth, name = 'iPhone'): Promise<{ credential: string; device: Device }> {
  const result = await pair(auth, name)
  expect(auth.approveDevice(result.device.id)).toBe(true)
  return result
}

function silenceErrors(): void {
  vi.spyOn(console, 'error').mockImplementation(() => undefined)
}

/* -------------------------------------------------------------------------- */

/**
 * The four numbers the six-digit format is only sound because of.
 *
 * `shared/short-code.ts` states the arithmetic: 10^6 codes, five guesses, sixty
 * seconds, and a *pending* device at the end of a successful one. Every one of
 * those is a constant somebody could raise or lower without touching a line of
 * this file's logic, and the arithmetic in that header would silently become
 * false. So they are asserted as values, not merely used.
 *
 * If one of these has to change, the header over there changes with it — that
 * is the whole point of failing here rather than in a behavioural test that
 * would still pass with a ten-minute TTL.
 */
describe('the constants the code length is arguing against', () => {
  it('gives a code sixty seconds and no more', () => {
    expect(PAIRING_TTL_MS).toBe(60_000)
  })

  it('tolerates five wrong answers, not more', () => {
    expect(MAX_FAILED_ATTEMPTS).toBe(5)
  })

  it('locks a source out for fifteen minutes once it has spent them', () => {
    expect(LOCKOUT_MS).toBe(15 * 60_000)
  })
})

describe('pairing tokens', () => {
  it('opens once, inside its life', async () => {
    const time = clock()
    const auth = new RemoteAuth(tempDir(), { now: time.now })

    const { token, expiresAt } = auth.createPairingToken()
    expect(expiresAt).toBe(time.now() + PAIRING_TTL_MS)
    // The short code from `shared/short-code.ts`, because every pairing is now
    // a person reading a code off one screen and typing it into another — there
    // is no QR and no link. A million codes, guarded by the sixty seconds above,
    // a single use, and five wrong answers killing the code in
    // `pairingDesk.offers`; the arithmetic is written out in that file.
    expect(isCode(token)).toBe(true)
    expect(token).toMatch(/^[0-9]{6}$/)

    time.advance(PAIRING_TTL_MS - 1)
    const result = await auth.redeemPairingToken(token, 'iPhone')
    expect(result.ok).toBe(true)
  })

  it('rejects a token that has expired', async () => {
    const time = clock()
    const auth = new RemoteAuth(tempDir(), { now: time.now })
    const { token } = auth.createPairingToken()

    // Exactly the TTL, not a millisecond past it. A token minted at t with a
    // 60s life is dead at t+60000, and `>` instead of `>=` would let this one
    // through.
    time.advance(PAIRING_TTL_MS)
    const result = await auth.redeemPairingToken(token, 'iPhone')

    expect(result).toEqual({ ok: false, reason: 'expired' })
    expect(auth.listDevices()).toEqual([])
  })

  it('rejects a token that has already been redeemed', async () => {
    const auth = new RemoteAuth(tempDir(), { now: clock().now })
    const { token } = auth.createPairingToken()

    expect((await auth.redeemPairingToken(token, 'iPhone')).ok).toBe(true)
    expect(await auth.redeemPairingToken(token, 'iPhone-again')).toEqual({ ok: false, reason: 'used' })
    expect(auth.listDevices()).toHaveLength(1)
  })

  it('rejects a token nobody minted', async () => {
    const auth = new RemoteAuth(tempDir(), { now: clock().now })
    auth.createPairingToken()

    for (const guess of [randomBytes(32).toString('base64url'), 'x', 'AAAA']) {
      expect(await auth.redeemPairingToken(guess, 'iPhone')).toEqual({ ok: false, reason: 'unknown' })
    }
    expect(auth.listDevices()).toEqual([])
  })

  it('rejects a token minted by another process', async () => {
    // The documented claim: tokens live in memory, so a restart cancels a
    // pairing in flight rather than leaving a bearer secret on disk.
    const dir = tempDir()
    const time = clock()
    const first = new RemoteAuth(dir, { now: time.now })
    const { token } = first.createPairingToken()

    const second = new RemoteAuth(dir, { now: time.now })
    expect(await second.redeemPairingToken(token, 'iPhone')).toEqual({ ok: false, reason: 'unknown' })
  })

  it('burns the token even when the redemption fails afterwards', async () => {
    const auth = new RemoteAuth(tempDir(), { now: clock().now })
    const { token } = auth.createPairingToken()

    // A name of nothing but control characters cleans down to empty, so this
    // fails after the token has already matched.
    expect(await auth.redeemPairingToken(token, '\u0007\u0000')).toEqual({ ok: false, reason: 'bad-name' })
    expect(await auth.redeemPairingToken(token, 'iPhone')).toEqual({ ok: false, reason: 'used' })
    expect(auth.listDevices()).toEqual([])
  })

  it('does not burn anything on input that never matched', async () => {
    const auth = new RemoteAuth(tempDir(), { now: clock().now })
    const { token } = auth.createPairingToken()

    expect(await auth.redeemPairingToken(42, 'iPhone')).toEqual({ ok: false, reason: 'malformed' })
    expect(await auth.redeemPairingToken('', 'iPhone')).toEqual({ ok: false, reason: 'malformed' })
    expect(await auth.redeemPairingToken(`${token}x`, 'iPhone')).toEqual({ ok: false, reason: 'unknown' })

    expect((await auth.redeemPairingToken(token, 'iPhone')).ok).toBe(true)
  })

  it('keeps the newest token when a stuck caller mints in a loop', async () => {
    const auth = new RemoteAuth(tempDir(), { now: clock().now })
    let last = auth.createPairingToken()
    for (let i = 0; i < 20; i++) last = auth.createPairingToken()

    expect((await auth.redeemPairingToken(last.token, 'iPhone')).ok).toBe(true)
  })

  it('strips control characters out of a device name', async () => {
    const auth = new RemoteAuth(tempDir(), { now: clock().now })
    const { token } = auth.createPairingToken()

    // The name is rendered next to terminal output in this app, so an escape
    // sequence in it is an injection, not a typo.
    const result = await auth.redeemPairingToken(token, "  \u001b[31mAsad's iPhone\u0007  ")
    expect(result.ok && result.device.name).toBe("[31mAsad's iPhone")
  })
})

describe('device trust', () => {
  it('starts a paired device pending, and pending cannot attach', async () => {
    const auth = new RemoteAuth(tempDir(), { now: clock().now })
    const { credential, device } = await pair(auth)

    expect(device.status).toBe('pending')
    expect(device.approved).toBe(false)
    expect(await auth.verifyCredential(credential, ADDRESS)).toEqual({ ok: false, reason: 'pending' })
  })

  it('lets an approved device attach', async () => {
    const time = clock()
    const auth = new RemoteAuth(tempDir(), { now: time.now })
    const { credential, device } = await pair(auth)

    expect(auth.approveDevice(device.id)).toBe(true)
    // Approving twice is not a second grant of anything.
    expect(auth.approveDevice(device.id)).toBe(false)

    const result = await auth.verifyCredential(credential, ADDRESS)
    expect(result.ok).toBe(true)
    expect(result.ok && result.device.status).toBe('approved')
    expect(result.ok && result.device.lastSeenAt).toBe(time.now())
  })

  it('stops a revoked device attaching', async () => {
    const auth = new RemoteAuth(tempDir(), { now: clock().now })
    const { credential, device } = await paired(auth)
    expect((await auth.verifyCredential(credential, ADDRESS)).ok).toBe(true)

    expect(auth.revokeDevice(device.id)).toBe(true)
    expect(await auth.verifyCredential(credential, ADDRESS)).toEqual({ ok: false, reason: 'revoked' })

    // Revocation is final. Approving it back would hand the credential to
    // whoever the revocation was aimed at.
    expect(auth.approveDevice(device.id)).toBe(false)
    expect(auth.listDevices()[0].status).toBe('revoked')
    expect(await auth.verifyCredential(credential, ELSEWHERE)).toEqual({ ok: false, reason: 'revoked' })
  })

  it('answers the same way for an unknown device and a wrong secret', async () => {
    const auth = new RemoteAuth(tempDir(), { now: clock().now })
    const { device } = await paired(auth)

    const unknown = `${randomBytes(12).toString('base64url')}.${randomBytes(32).toString('base64url')}`
    expect(await auth.verifyCredential(unknown, ADDRESS)).toEqual({ ok: false, reason: 'denied' })
    expect(await auth.verifyCredential(wrongSecret(device), ELSEWHERE)).toEqual({
      ok: false,
      reason: 'denied',
    })
  })

  it('refuses credentials that are not credentials', async () => {
    const auth = new RemoteAuth(tempDir(), { now: clock().now })
    for (const junk of ['', '.', 'nodot', 'id.', '.secret', 42, null, undefined]) {
      expect(await auth.verifyCredential(junk, ADDRESS)).toEqual({ ok: false, reason: 'malformed' })
    }
  })

  it('names every device it knows, newest first', async () => {
    const time = clock()
    const auth = new RemoteAuth(tempDir(), { now: time.now })
    await pair(auth, 'iPhone')
    time.advance(1000)
    const second = await pair(auth, 'iPad')
    auth.approveDevice(second.device.id)

    expect(auth.listDevices().map((d) => [d.name, d.status])).toEqual([
      ['iPad', 'approved'],
      ['iPhone', 'pending'],
    ])
  })

  it('keeps trust across a restart', async () => {
    const dir = tempDir()
    const time = clock()
    const { credential, device } = await paired(new RemoteAuth(dir, { now: time.now }), 'iPad')

    const restarted = new RemoteAuth(dir, { now: time.now })
    expect(restarted.listDevices().map((d) => d.id)).toEqual([device.id])
    expect((await restarted.verifyCredential(credential, ADDRESS)).ok).toBe(true)

    // And revocation survives too, which is the half that matters.
    restarted.revokeDevice(device.id)
    const again = new RemoteAuth(dir, { now: time.now })
    expect(await again.verifyCredential(credential, ADDRESS)).toEqual({ ok: false, reason: 'revoked' })
  })

  it('does not rewrite the file for every attach', async () => {
    const time = clock()
    const auth = new RemoteAuth(tempDir(), { now: time.now })
    const { credential } = await paired(auth)

    await auth.verifyCredential(credential, ADDRESS)
    const first = statSync(auth.file).mtimeMs
    const seenAt = JSON.parse(readFileSync(auth.file, 'utf8')).devices[0].lastSeenAt

    // A client reconnecting in a loop must not turn every attach into a write.
    for (let i = 0; i < 5; i++) await auth.verifyCredential(credential, ADDRESS)
    expect(statSync(auth.file).mtimeMs).toBe(first)
    expect(JSON.parse(readFileSync(auth.file, 'utf8')).devices[0].lastSeenAt).toBe(seenAt)
  })
})

describe('storage', () => {
  it('never writes the credential it handed out', async () => {
    const auth = new RemoteAuth(tempDir(), { now: clock().now })
    const { credential } = await paired(auth)
    const secret = credential.slice(credential.indexOf('.') + 1)

    const onDisk = readFileSync(auth.file, 'utf8')
    expect(onDisk).not.toContain(credential)
    expect(onDisk).not.toContain(secret)
    // Not the raw bytes under another encoding either.
    expect(onDisk).not.toContain(Buffer.from(secret, 'base64url').toString('base64'))
    expect(onDisk).not.toContain(Buffer.from(secret, 'base64url').toString('hex'))

    // What is there is a salted hash, and it is not enough to become the device.
    const stored = JSON.parse(onDisk).devices[0].credential
    expect(stored.salt).toMatch(/^[A-Za-z0-9+/=]+$/)
    expect(Buffer.from(stored.hash, 'base64')).toHaveLength(32)
    expect(stored.n).toBeGreaterThanOrEqual(16384)
  })

  /**
   * POSIX-only, and skipped rather than softened off it. Windows has no mode
   * bits behind `chmod`: this file comes back 0o666 there whatever it was
   * written with, because Node synthesises the mode from the read-only
   * attribute alone (measured on Windows 11 — 438, not 384). Keeping the paired
   * device secrets owner-only on Windows is an ACL question, and this module
   * does not ask it; asserting 0o666 would only record that.
   */
  it.skipIf(process.platform === 'win32')('keeps the file readable only by its owner', async () => {
    const auth = new RemoteAuth(tempDir(), { now: clock().now })
    await pair(auth)
    expect(statSync(auth.file).mode & 0o777).toBe(0o600)
  })

  it('trusts nobody when the file is corrupt, and keeps the original', () => {
    silenceErrors()
    const dir = tempDir()
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, REMOTE_AUTH_FILE), '{ this is not json', 'utf8')

    const auth = new RemoteAuth(dir, { now: clock().now })
    expect(auth.listDevices()).toEqual([])

    // Failing closed is right; destroying the only copy of the user's device
    // list on the next write is not.
    const aside = readdirSync(dir).filter((name) => name.includes('.corrupt-'))
    expect(aside).toHaveLength(1)
    expect(readFileSync(join(dir, aside[0]), 'utf8')).toBe('{ this is not json')
  })

  it('drops a device record it cannot read and keeps the rest', async () => {
    silenceErrors()
    const dir = tempDir()
    const time = clock()
    const auth = new RemoteAuth(dir, { now: time.now })
    const { credential } = await paired(auth, 'iPad')

    const state = JSON.parse(readFileSync(auth.file, 'utf8'))
    state.devices.push({ id: 'half-a-record', name: 'ghost', addedAt: 1 })
    writeFileSync(auth.file, JSON.stringify(state), 'utf8')

    const reloaded = new RemoteAuth(dir, { now: time.now })
    expect(reloaded.listDevices().map((d) => d.name)).toEqual(['iPad'])
    expect((await reloaded.verifyCredential(credential, ADDRESS)).ok).toBe(true)
  })

  it('reads a damaged trust flag as revoked, not as approved', async () => {
    const dir = tempDir()
    const time = clock()
    const auth = new RemoteAuth(dir, { now: time.now })
    const { credential } = await paired(auth)

    const state = JSON.parse(readFileSync(auth.file, 'utf8'))
    delete state.devices[0].revoked
    writeFileSync(auth.file, JSON.stringify(state), 'utf8')

    // A missing flag is a question, and the only safe answer to "is this
    // device still trusted?" is no.
    const reloaded = new RemoteAuth(dir, { now: time.now })
    expect(reloaded.listDevices()[0].status).toBe('revoked')
    expect(await reloaded.verifyCredential(credential, ADDRESS)).toEqual({ ok: false, reason: 'revoked' })
  })
})

describe('rate limiting', () => {
  it('locks a device out after enough wrong guesses, then lets it back', async () => {
    const time = clock()
    const auth = new RemoteAuth(tempDir(), { now: time.now })
    const { credential, device } = await paired(auth)

    for (let i = 0; i < MAX_FAILED_ATTEMPTS; i++) {
      expect(await auth.verifyCredential(wrongSecret(device), ADDRESS)).toEqual({
        ok: false,
        reason: 'denied',
      })
    }

    // Even the real credential is refused now — that is the point of a lockout.
    const blocked = await auth.verifyCredential(credential, ADDRESS)
    expect(blocked.ok).toBe(false)
    expect(blocked.ok === false && blocked.reason).toBe('rate-limited')
    expect(blocked.ok === false && blocked.retryAfterMs).toBe(LOCKOUT_MS)

    // Retrying during the cooldown must not extend it, or the owner never gets
    // back in while an attacker keeps knocking.
    await auth.verifyCredential(wrongSecret(device), ADDRESS)
    time.advance(LOCKOUT_MS - 1)
    expect((await auth.verifyCredential(credential, ADDRESS)).ok).toBe(false)

    time.advance(1)
    expect((await auth.verifyCredential(credential, ADDRESS)).ok).toBe(true)
  })

  it('locks the source address too, not just the device', async () => {
    const time = clock()
    const auth = new RemoteAuth(tempDir(), { now: time.now })
    const first = await paired(auth, 'iPhone')
    const second = await paired(auth, 'iPad')

    for (let i = 0; i < MAX_FAILED_ATTEMPTS; i++) {
      await auth.verifyCredential(wrongSecret(first.device), ADDRESS)
    }

    // The second device never failed, but it is knocking from the address that
    // did — otherwise guessing device ids in turn would cost nothing.
    const sameAddress = await auth.verifyCredential(second.credential, ADDRESS)
    expect(sameAddress.ok === false && sameAddress.reason).toBe('rate-limited')

    expect((await auth.verifyCredential(second.credential, ELSEWHERE)).ok).toBe(true)
  })

  it('counts a guess against an id nobody has paired', async () => {
    const time = clock()
    const auth = new RemoteAuth(tempDir(), { now: time.now })
    const { credential } = await paired(auth)

    for (let i = 0; i < MAX_FAILED_ATTEMPTS; i++) {
      const junk = `${randomBytes(12).toString('base64url')}.${randomBytes(32).toString('base64url')}`
      expect((await auth.verifyCredential(junk, ADDRESS)).ok).toBe(false)
    }

    const blocked = await auth.verifyCredential(credential, ADDRESS)
    expect(blocked.ok === false && blocked.reason).toBe('rate-limited')
  })

  it('clears the count once a device gets in', async () => {
    const time = clock()
    const auth = new RemoteAuth(tempDir(), { now: time.now })
    const { credential, device } = await paired(auth)

    for (let i = 0; i < MAX_FAILED_ATTEMPTS - 1; i++) {
      await auth.verifyCredential(wrongSecret(device), ADDRESS)
    }
    expect((await auth.verifyCredential(credential, ADDRESS)).ok).toBe(true)

    // The near-miss run is forgotten, so a fat-fingered evening does not lock
    // the device out the next morning.
    for (let i = 0; i < MAX_FAILED_ATTEMPTS - 1; i++) {
      await auth.verifyCredential(wrongSecret(device), ADDRESS)
    }
    expect((await auth.verifyCredential(credential, ADDRESS)).ok).toBe(true)
  })

  it('never locks out a device that is only waiting to be approved', async () => {
    const time = clock()
    const auth = new RemoteAuth(tempDir(), { now: time.now })
    const { credential, device } = await pair(auth)

    // Polling until someone presses approve is the intended flow.
    for (let i = 0; i < MAX_FAILED_ATTEMPTS + 2; i++) {
      expect(await auth.verifyCredential(credential, ADDRESS)).toEqual({ ok: false, reason: 'pending' })
    }

    auth.approveDevice(device.id)
    expect((await auth.verifyCredential(credential, ADDRESS)).ok).toBe(true)
  })

  it('rate-limits token guessing when the caller has an address to blame', async () => {
    const time = clock()
    const auth = new RemoteAuth(tempDir(), { now: time.now })
    const { token } = auth.createPairingToken()

    for (let i = 0; i < MAX_FAILED_ATTEMPTS; i++) {
      const guess = randomBytes(32).toString('base64url')
      expect(await auth.redeemPairingToken(guess, 'iPhone', ADDRESS)).toEqual({
        ok: false,
        reason: 'unknown',
      })
    }

    const blocked = await auth.redeemPairingToken(token, 'iPhone', ADDRESS)
    expect(blocked.ok === false && blocked.reason).toBe('rate-limited')
    // The real token is still unspent — being shouted at from one address must
    // not cancel the pairing the owner is in the middle of.
    expect((await auth.redeemPairingToken(token, 'iPhone', ELSEWHERE)).ok).toBe(true)
  })
})

describe('a file that argues with itself', () => {
  it('reads two rows claiming one device id as revoked, not as approved', async () => {
    silenceErrors()
    const dir = tempDir()
    const time = clock()
    const auth = new RemoteAuth(dir, { now: time.now })
    const { credential, device } = await paired(auth)
    expect(auth.revokeDevice(device.id)).toBe(true)

    // The row a tampered backup would put in front: same id, same hash, but
    // approved and not revoked. `find` answers with whichever comes first, so
    // the order is the whole attack.
    const state = JSON.parse(readFileSync(auth.file, 'utf8'))
    const forged = JSON.parse(JSON.stringify(state.devices[0]))
    forged.approved = true
    forged.revoked = false
    state.devices.unshift(forged)
    writeFileSync(auth.file, JSON.stringify(state), 'utf8')

    const reloaded = new RemoteAuth(dir, { now: time.now })
    expect(reloaded.listDevices()).toHaveLength(1)
    expect(reloaded.listDevices()[0].status).toBe('revoked')
    expect(await reloaded.verifyCredential(credential, ADDRESS)).toEqual({ ok: false, reason: 'revoked' })
  })

  it('drops a record whose scrypt parameters would cost the machine seconds', async () => {
    silenceErrors()
    const dir = tempDir()
    const time = clock()
    const auth = new RemoteAuth(dir, { now: time.now })
    const { credential } = await paired(auth)

    // Storing the parameters per record is what lets them be raised later; it
    // also means the file decides how much work an attach costs. These two
    // measured at 17 seconds and about two gigabytes for a single call.
    const state = JSON.parse(readFileSync(auth.file, 'utf8'))
    state.devices[0].credential.n = 1_048_576
    state.devices[0].credential.keylen = 900_000_000
    writeFileSync(auth.file, JSON.stringify(state), 'utf8')

    const reloaded = new RemoteAuth(dir, { now: time.now })
    expect(reloaded.listDevices()).toEqual([])
    const started = Date.now()
    expect(await reloaded.verifyCredential(credential, ADDRESS)).toEqual({ ok: false, reason: 'denied' })
    // Fail closed is only half of it. Failing closed slowly is still a way to
    // take the machine down.
    expect(Date.now() - started).toBeLessThan(2000)
  })

  it('keeps every quarantined copy when two starts land in the same millisecond', () => {
    silenceErrors()
    const dir = tempDir()
    const time = clock()

    writeFileSync(join(dir, REMOTE_AUTH_FILE), 'first damaged file', 'utf8')
    new RemoteAuth(dir, { now: time.now })
    writeFileSync(join(dir, REMOTE_AUTH_FILE), 'second damaged file', 'utf8')
    new RemoteAuth(dir, { now: time.now })

    // A timestamp alone is not a unique name, and renaming the second copy over
    // the first destroys exactly what the quarantine exists to keep.
    const aside = readdirSync(dir).filter((name) => name.includes('.corrupt-'))
    expect(aside.map((name) => readFileSync(join(dir, name), 'utf8')).sort()).toEqual([
      'first damaged file',
      'second damaged file',
    ])
  })
})

describe('inputs that are not the shape they claim', () => {
  it('refuses a credential with anything outside the alphabet it was minted in', async () => {
    const auth = new RemoteAuth(tempDir(), { now: clock().now })
    const { credential } = await paired(auth)
    expect((await auth.verifyCredential(credential, ADDRESS)).ok).toBe(true)

    // `Buffer.from(_, 'base64url')` drops what it does not recognise, so these
    // all decode to the same bytes as the real credential. A credential with no
    // canonical form is one nothing upstream can compare or count.
    for (const mutated of [`${credential}.=!!`, `${credential}==`, `${credential} `, `${credential}\n`]) {
      expect(await auth.verifyCredential(mutated, ADDRESS)).toEqual({ ok: false, reason: 'malformed' })
    }
  })

  it('refuses oversized inputs without hashing them', async () => {
    const auth = new RemoteAuth(tempDir(), { now: clock().now })
    const huge = 'A'.repeat(2 * 1024 * 1024)

    expect(await auth.redeemPairingToken(huge, 'iPhone')).toEqual({ ok: false, reason: 'malformed' })
    expect(await auth.verifyCredential(`abcdef.${huge}`, ADDRESS)).toEqual({ ok: false, reason: 'malformed' })
    // A name nobody could have typed is truncated, not carried around.
    const { token } = auth.createPairingToken()
    const result = await auth.redeemPairingToken(token, huge)
    expect(result.ok && result.device.name.length).toBeLessThanOrEqual(64)
  })
})

describe('running out of room', () => {
  it('never retires the pairing button because of devices that were revoked', async () => {
    const auth = new RemoteAuth(tempDir(), { now: clock().now })

    // Pair and revoke, over and over. A revoked record refuses the same
    // credential whether it is on the list or gone, so it is holding a slot and
    // not any trust — and there is no delete anywhere in this API, so filling
    // the roster with tombstones would end pairing permanently.
    for (let i = 0; i < 70; i++) {
      const { token } = auth.createPairingToken()
      const result = await auth.redeemPairingToken(token, `phone-${i}`)
      expect(result.ok).toBe(true)
      if (result.ok) expect(auth.revokeDevice(result.device.id)).toBe(true)
    }

    // And a device that is still trusted is never the one thrown away.
    const keeper = await paired(auth, 'keeper')
    for (let i = 0; i < 5; i++) {
      const { token } = auth.createPairingToken()
      expect((await auth.redeemPairingToken(token, `later-${i}`)).ok).toBe(true)
    }
    expect((await auth.verifyCredential(keeper.credential, ADDRESS)).ok).toBe(true)
  }, 60_000)
})

/**
 * Sign-in mints on the other road into the trust store. The pairing path creates
 * a pending device a human approves; this path creates one that is already
 * approved, because the proof that got here — a login to this machine's own sshd
 * — is the approval. So the attacker's questions are different: is the key really
 * required, does the credential actually work without an approve, is the limiter
 * a separate door from the credential one, and does a refused login count.
 */
describe('sign-in mint', () => {
  const KEY = () => randomBytes(32)
  const SIGN_IN_ADDR = '100.99.1.1'

  it('mints an approved device whose credential works with no approve step', async () => {
    const auth = new RemoteAuth(tempDir())
    const key = KEY()
    const result = await auth.enrollDevice('Asad’s iPhone', SIGN_IN_ADDR, key)
    expect(result.ok).toBe(true)
    if (!result.ok) throw new Error('unreachable')

    expect(result.device.status).toBe('approved')
    // Straight in — the pending state the pairing path sits in is skipped.
    const verified = await auth.verifyCredential(result.credential, SIGN_IN_ADDR)
    expect(verified.ok).toBe(true)
    // Bound to the key, so a stolen credential from a different phone is refused.
    expect(auth.deviceHoldsKey(result.device.id, key)).toBe(true)
    expect(auth.knowsDeviceKey(key)).toBe(true)
  })

  it('refuses a device with no usable key — it could never be bound', async () => {
    const auth = new RemoteAuth(tempDir())
    expect((await auth.enrollDevice('iPhone', SIGN_IN_ADDR, Buffer.alloc(0))).ok).toBe(false)
    const short = await auth.enrollDevice('iPhone', SIGN_IN_ADDR, randomBytes(16))
    expect(short).toEqual({ ok: false, reason: 'malformed' })
  })

  it('refuses a blank name', async () => {
    const auth = new RemoteAuth(tempDir())
    expect(await auth.enrollDevice('   ', SIGN_IN_ADDR, KEY())).toEqual({ ok: false, reason: 'bad-name' })
  })

  it('persists the public key so the bind survives a reload', async () => {
    const dir = tempDir()
    const key = KEY()
    const first = new RemoteAuth(dir)
    const minted = await first.enrollDevice('iPhone', SIGN_IN_ADDR, key)
    if (!minted.ok) throw new Error('unreachable')

    const reloaded = new RemoteAuth(dir)
    expect(reloaded.deviceHoldsKey(minted.device.id, key)).toBe(true)
    expect((await reloaded.verifyCredential(minted.credential, SIGN_IN_ADDR)).ok).toBe(true)
  })

  it('never stores the minted secret in plaintext', async () => {
    const auth = new RemoteAuth(tempDir())
    const minted = await auth.enrollDevice('iPhone', SIGN_IN_ADDR, KEY())
    if (!minted.ok) throw new Error('unreachable')
    const secret = minted.credential.split('.')[1]
    const onDisk = readFileSync(auth.file, 'utf8')
    expect(onDisk).not.toContain(secret)
  })
})

describe('the sign-in limiter', () => {
  const SIGN_IN_ADDR = '100.99.2.2'

  it('locks an address out after MAX_FAILED_ATTEMPTS and reports how long', () => {
    const time = clock()
    const auth = new RemoteAuth(tempDir(), { now: time.now })

    for (let i = 0; i < MAX_FAILED_ATTEMPTS - 1; i++) {
      auth.noteEnrollFailure(SIGN_IN_ADDR)
      expect(auth.enrollAllowed(SIGN_IN_ADDR).ok).toBe(true)
    }
    auth.noteEnrollFailure(SIGN_IN_ADDR)
    const blocked = auth.enrollAllowed(SIGN_IN_ADDR)
    expect(blocked.ok).toBe(false)
    if (blocked.ok) throw new Error('unreachable')
    expect(blocked.retryAfterMs).toBeGreaterThan(0)
    expect(blocked.retryAfterMs).toBeLessThanOrEqual(LOCKOUT_MS)

    // And it clears when the lockout is served.
    time.advance(LOCKOUT_MS + 1)
    expect(auth.enrollAllowed(SIGN_IN_ADDR).ok).toBe(true)
  })

  it('is a separate door from the credential limiter', async () => {
    const time = clock()
    const auth = new RemoteAuth(tempDir(), { now: time.now })
    const { credential } = await paired(auth, 'iPhone')

    // Trip the sign-in limiter for this address.
    for (let i = 0; i < MAX_FAILED_ATTEMPTS; i++) auth.noteEnrollFailure(SIGN_IN_ADDR)
    expect(auth.enrollAllowed(SIGN_IN_ADDR).ok).toBe(false)

    // A good credential from the same address is unaffected — the two buckets do
    // not lock each other's users out.
    expect((await auth.verifyCredential(credential, SIGN_IN_ADDR)).ok).toBe(true)
  })

  it('clears the address counter on a successful mint', async () => {
    const time = clock()
    const auth = new RemoteAuth(tempDir(), { now: time.now })
    for (let i = 0; i < MAX_FAILED_ATTEMPTS - 1; i++) auth.noteEnrollFailure(SIGN_IN_ADDR)

    const minted = await auth.enrollDevice('iPhone', SIGN_IN_ADDR, randomBytes(32))
    expect(minted.ok).toBe(true)
    // The four earlier failures are wiped, so the next failure starts from one
    // rather than tripping the lockout.
    auth.noteEnrollFailure(SIGN_IN_ADDR)
    expect(auth.enrollAllowed(SIGN_IN_ADDR).ok).toBe(true)
  })
})
