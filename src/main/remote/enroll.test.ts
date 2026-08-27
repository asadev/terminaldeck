import { randomBytes } from 'node:crypto'
import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { MAX_FAILED_ATTEMPTS, RemoteAuth } from './device-auth'
import { DeviceKinds } from './device-kind'
import { createEnrollAccess, SIGN_IN_BAD_KEY } from './enroll'
import { SIGN_IN_NOT_SERVED } from './server'
import type { verifyLoopbackSsh } from './ssh-verify'

/**
 * The sign-in road, with the SSH probe stood in for.
 *
 * The three things this file proves are the three that make sign-in safe rather
 * than a back door: the probe is spent only when the address is allowed to spend
 * it (so this host is not a brute-force amplifier), the secret exists nowhere
 * after the call, and a minted device is one of the owner's own, approved, bound
 * to the key that will reconnect it.
 */

type VerifyResult = Awaited<ReturnType<typeof verifyLoopbackSsh>>

const dirs: string[] = []
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
  vi.restoreAllMocks()
})

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'terminaldeck-enroll-'))
  dirs.push(dir)
  return dir
}

function clock(start = 1_760_000_000_000): { now: () => number; advance: (ms: number) => void } {
  let t = start
  return { now: () => t, advance: (ms: number) => (t += ms) }
}

const KEY = () => randomBytes(32)
const ADDRESS = '100.86.107.119'
const SSH_SECRET = 'correct horse battery staple'

/** A verifier that records its calls and answers with what the test programmed. */
function fakeVerifier(answers: VerifyResult[] | (() => Promise<VerifyResult>)) {
  const calls: Array<{ username: string; secret: string; method: string; port: number }> = []
  const queue = Array.isArray(answers) ? [...answers] : null
  const verify: typeof verifyLoopbackSsh = async (input) => {
    calls.push({ username: input.username, secret: input.secret, method: input.method, port: input.port })
    if (queue) return queue.shift() ?? { ok: true }
    return (answers as () => Promise<VerifyResult>)()
  }
  return { verify, calls }
}

function build(
  verify: typeof verifyLoopbackSsh,
  env: NodeJS.ProcessEnv = {},
): { access: ReturnType<typeof createEnrollAccess>; auth: RemoteAuth; kinds: DeviceKinds; dir: string } {
  const dir = tempDir()
  const time = clock()
  const auth = new RemoteAuth(dir, { now: time.now })
  const kinds = new DeviceKinds(dir, time.now)
  const access = createEnrollAccess({ auth, kinds, env, verify })
  return { access, auth, kinds, dir }
}

function signIn(access: ReturnType<typeof createEnrollAccess>, over: { secret?: string; peerPublicKey?: Buffer } = {}) {
  return access.signIn({
    username: 'asad',
    secret: over.secret ?? SSH_SECRET,
    method: 'password',
    deviceName: 'Asad’s iPhone',
    address: ADDRESS,
    peerPublicKey: over.peerPublicKey ?? KEY(),
  })
}

describe('a good sign-in', () => {
  it('mints a pre-approved device of the owner’s own, bound to the key', async () => {
    const { verify } = fakeVerifier([{ ok: true }])
    const { access, auth, kinds } = build(verify)
    const key = KEY()

    const result = await signIn(access, { peerPublicKey: key })
    expect(result.ok).toBe(true)
    if (!result.ok) throw new Error('unreachable')

    const device = auth.listDevices().find((d) => d.id === result.deviceId)
    expect(device?.status).toBe('approved')
    expect(kinds.kindOf(result.deviceId)).toBe('mine')
    // The key was bound at mint, which is what makes the credential useless
    // without the phone that holds the private half.
    expect(auth.deviceHoldsKey(result.deviceId, key)).toBe(true)
    expect(auth.deviceHoldsKey(result.deviceId, KEY())).toBe(false)
  })

  it('dials the sshd port: the override, then the SSH session’s own port, then 22', async () => {
    // Set by hand: it wins, exactly as before.
    const override = fakeVerifier([{ ok: true }])
    await signIn(build(override.verify, { TERMINALDECK_SSHD_PORT: '2200' }).access)
    expect(override.calls[0]?.port).toBe(2200)

    // Not set, but this host is running inside the SSH session that just
    // authenticated on 2222 — his WSL box. `SSH_CONNECTION` is
    // "<client-ip> <client-port> <server-ip> <server-port>", so the last field is
    // the port sshd answered on, and no variable has to be set for it to be
    // found. This is the case the module header's whole apology was written for.
    const detected = fakeVerifier([{ ok: true }])
    await signIn(build(detected.verify, { SSH_CONNECTION: '100.64.0.9 51875 100.86.107.119 2222' }).access)
    expect(detected.calls[0]?.port).toBe(2222)

    // Both present: the explicit override still wins, so a box that needs a value
    // it cannot detect can always force one.
    const both = fakeVerifier([{ ok: true }])
    await signIn(
      build(both.verify, {
        TERMINALDECK_SSHD_PORT: '2200',
        SSH_CONNECTION: '100.64.0.9 51875 100.86.107.119 2222',
      }).access,
    )
    expect(both.calls[0]?.port).toBe(2200)

    // Neither: OpenSSH's default.
    const bare = fakeVerifier([{ ok: true }])
    await signIn(build(bare.verify, {}).access)
    expect(bare.calls[0]?.port).toBe(22)

    // A malformed SSH_CONNECTION is ignored rather than trusted — a probe pointed
    // somewhere odd is worse than one pointed at 22.
    const junk = fakeVerifier([{ ok: true }])
    await signIn(build(junk.verify, { SSH_CONNECTION: 'not-a-connection-string' }).access)
    expect(junk.calls[0]?.port).toBe(22)
  })
})

describe('a refused sign-in', () => {
  it('collapses to unauthorized and counts against the limiter', async () => {
    const { verify, calls } = fakeVerifier([{ ok: false, reason: 'auth' }])
    const { access, auth } = build(verify)
    const spy = vi.spyOn(auth, 'noteEnrollFailure')

    const result = await signIn(access)
    expect(result).toEqual({ ok: false, code: 'unauthorized', message: expect.any(String) })
    expect(calls).toHaveLength(1)
    expect(spy).toHaveBeenCalledWith(ADDRESS)
  })

  it('never quotes the secret in the message it returns', async () => {
    const { verify } = fakeVerifier([{ ok: false, reason: 'auth' }])
    const { access } = build(verify)
    const result = await signIn(access, { secret: 's3cr3t-do-not-echo' })
    expect(result.ok).toBe(false)
    if (result.ok) throw new Error('unreachable')
    expect(result.message).not.toContain('s3cr3t-do-not-echo')
  })

  /**
   * The refusal that cost an evening, and what it now has to say.
   *
   * On 2026-08-22 a server that was running, relayed and serving sign-in refused
   * a phone all night with *"Sign-in is not available on this machine. Pair it
   * with a code instead"* — `server.ts`'s sentence for a host with the feature
   * switched off, sent from here because the loopback probe could not reach an
   * sshd that was listening on 2222. The phone dutifully printed "that server
   * does not offer sign-in". Nothing about the port, which was the whole answer,
   * appeared anywhere.
   *
   * So the port and the variable are asserted, not the tone. A sentence that
   * says "unavailable, pair with a code" is exactly what shipped and exactly
   * what must not ship again.
   */
  it('names the port and the variable when nothing answers SSH', async () => {
    const { verify } = fakeVerifier([{ ok: false, reason: 'no-sshd' }])
    const result = await signIn(build(verify, { TERMINALDECK_SSHD_PORT: '2222' }).access)
    expect(result.ok).toBe(false)
    if (result.ok) throw new Error('unreachable')
    expect(result.code).toBe('unavailable')
    expect(result.message).toContain('2222')
    expect(result.message).toContain('TERMINALDECK_SSHD_PORT')
    // The constraint is loopback, not "sshd is running": an sshd bound to one
    // interface and not to 127.0.0.1 fails here while ssh from the next desk
    // works, and that is invisible unless the sentence says it.
    expect(result.message).toContain('127.0.0.1')
    // And it is never the sentence that means the feature is switched off.
    expect(result.message).not.toBe(SIGN_IN_NOT_SERVED)
  })

  it('names the default port when nothing set one', async () => {
    const { verify } = fakeVerifier([{ ok: false, reason: 'no-sshd' }])
    const result = await signIn(build(verify).access)
    expect(result.ok).toBe(false)
    if (result.ok) throw new Error('unreachable')
    expect(result.message).toContain('port 22')
  })

  it('blames the key, not the server, for a key it could not read', async () => {
    // A passphrase-protected key is the common case and there is nowhere to type
    // one on a sign-in form. Reported as "no sshd" this reads as a broken server.
    const { verify } = fakeVerifier([{ ok: false, reason: 'bad-key' }])
    const { access, auth } = build(verify)
    const spy = vi.spyOn(auth, 'noteEnrollFailure')
    const result = await signIn(access)
    expect(result.ok).toBe(false)
    if (result.ok) throw new Error('unreachable')
    expect(result.code).toBe('unauthorized')
    expect(result.message).toBe(SIGN_IN_BAD_KEY)
    // No socket was opened and nothing was guessed at, so no limiter slot.
    expect(spy).not.toHaveBeenCalled()
  })

  it('reads a slow probe as unavailable, without counting it', async () => {
    const { verify } = fakeVerifier([{ ok: false, reason: 'timeout' }])
    const { access, auth } = build(verify)
    const spy = vi.spyOn(auth, 'noteEnrollFailure')
    const result = await signIn(access)
    expect(result.ok).toBe(false)
    if (result.ok) throw new Error('unreachable')
    expect(result.code).toBe('unavailable')
    expect(spy).not.toHaveBeenCalled()
  })
})

describe('the rate limit', () => {
  it('stops spending a probe after MAX_FAILED_ATTEMPTS from one address', async () => {
    const { verify, calls } = fakeVerifier(() => Promise.resolve({ ok: false, reason: 'auth' }))
    const { access } = build(verify)

    for (let i = 0; i < MAX_FAILED_ATTEMPTS; i += 1) {
      const r = await signIn(access)
      expect(r.ok).toBe(false)
    }
    expect(calls).toHaveLength(MAX_FAILED_ATTEMPTS)

    // The next attempt is refused before the probe — the host cannot be pointed
    // at its own sshd as a guessing amplifier.
    const blocked = await signIn(access)
    expect(blocked).toEqual({ ok: false, code: 'unauthorized', message: expect.any(String) })
    expect(calls).toHaveLength(MAX_FAILED_ATTEMPTS)
  })
})

describe('the concurrency gate', () => {
  it('never runs more than two probes at once', async () => {
    let inFlight = 0
    let peak = 0
    const release: Array<() => void> = []
    const verify: typeof verifyLoopbackSsh = () => {
      inFlight += 1
      peak = Math.max(peak, inFlight)
      return new Promise<VerifyResult>((resolve) => {
        release.push(() => {
          inFlight -= 1
          resolve({ ok: true })
        })
      })
    }
    const { access } = build(verify)

    const first = signIn(access, { peerPublicKey: KEY() })
    const second = signIn(access, { peerPublicKey: KEY() })
    // Let the two probes actually enter `verify`.
    await Promise.resolve()
    await Promise.resolve()

    const third = await signIn(access, { peerPublicKey: KEY() })
    expect(third).toEqual({ ok: false, code: 'unavailable', message: expect.any(String) })

    release.forEach((fn) => fn())
    await Promise.all([first, second])
    expect(peak).toBeLessThanOrEqual(2)
  })
})

describe('the secret exists nowhere after the call', () => {
  it('is in no stored file, no log, and no returned message', async () => {
    const logs: string[] = []
    for (const key of ['log', 'error', 'warn', 'info', 'debug'] as const) {
      vi.spyOn(console, key).mockImplementation((...args: unknown[]) => {
        logs.push(args.map((a) => String(a)).join(' '))
      })
    }
    const secret = 'nobody-should-ever-see-this-9f3a'

    // One that succeeds and one that fails, so both paths are covered.
    const good = fakeVerifier([{ ok: true }])
    const built = build(good.verify)
    const ok = await signIn(built.access, { secret })
    expect(ok.ok).toBe(true)

    const bad = createEnrollAccess({
      auth: built.auth,
      kinds: built.kinds,
      env: {},
      verify: fakeVerifier([{ ok: false, reason: 'auth' }]).verify,
    })
    const refused = await bad.signIn({
      username: 'asad',
      secret,
      method: 'password',
      deviceName: 'iPhone',
      address: '100.64.0.9',
      peerPublicKey: KEY(),
    })
    expect(refused.ok).toBe(false)

    // Not in any file under the storage dir.
    for (const name of readdirSync(built.dir)) {
      const body = readFileSync(join(built.dir, name), 'utf8')
      expect(body, `${name} must not hold the secret`).not.toContain(secret)
    }
    // Not in any console call.
    expect(logs.join('\n')).not.toContain(secret)
    // Not in either return value.
    expect(JSON.stringify(ok)).not.toContain(secret)
    expect(JSON.stringify(refused)).not.toContain(secret)
    // And the minted credential is a fresh secret, not the SSH one.
    if (ok.ok) expect(ok.credential).not.toContain(secret)
  })
})

describe('re-signing-in after a revoke', () => {
  it('mints a new id rather than resurrecting the old', async () => {
    const { verify } = fakeVerifier(() => Promise.resolve({ ok: true }))
    const { access, auth } = build(verify)

    const first = await signIn(access)
    if (!first.ok) throw new Error('unreachable')
    expect(auth.revokeDevice(first.deviceId)).toBe(true)

    const second = await signIn(access)
    if (!second.ok) throw new Error('unreachable')
    expect(second.deviceId).not.toBe(first.deviceId)
  })
})
