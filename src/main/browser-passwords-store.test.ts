import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * The one secret file in this app that skipped `writeSecretFile`, and the
 * migration that closing that gap needs.
 *
 * `servers/credentials.ts` calls this module out by name: it wrote the
 * `safeStorage` blob with a bare `writeFileSync` — no mode, no fsync, and no
 * `icacls /inheritance:r`, which on Windows is the only one of the three that
 * exists at all. NTFS ignores the POSIX mode, so saved browser logins sat in
 * `%APPDATA%` with inherited permissions while every other credential this app
 * writes carries an explicit owner-only entry. The contents are DPAPI-encrypted
 * so another standard user cannot read them; the point is that the app's own
 * stated rule had exactly one file exempted from it.
 *
 * Routing it through `writeSecretFile` changes the on-disk *spelling* — that
 * helper writes text, so the blob goes down base64 — and the risk of that is
 * not the ACL, it is the store an existing user already has. This file's whole
 * reason to exist is the case that would otherwise be silent: a raw blob
 * written by an older build must still read, because "unreadable" here means
 * "no saved passwords at all" and nothing on screen would say a store had ever
 * existed.
 */

/**
 * A `safeStorage` stand-in that behaves like the real one in the way that
 * matters here: the ciphertext is binary and does not survive a round trip
 * through base64 unless somebody actually base64s it.
 *
 * The `v10` prefix is not decoration — that is the literal marker Chromium's
 * OSCrypt writes on Windows and Linux, and it is what makes the raw form
 * detectably not-base64 to the reader under test.
 */
const store = vi.hoisted(() => ({ available: true }))

vi.mock('electron', () => ({
  clipboard: { writeText: () => undefined },
  safeStorage: {
    isEncryptionAvailable: () => store.available,
    encryptString: (text: string) => Buffer.concat([Buffer.from('v10'), Buffer.from(text, 'utf8')]),
    decryptString: (blob: Buffer) => {
      const marker = blob.subarray(0, 3).toString('utf8')
      if (marker !== 'v10') throw new Error('not our ciphertext')
      return blob.subarray(3).toString('utf8')
    },
  },
}))

const {
  allLogins,
  forgetAllLogins,
  loginsPath,
  resetLoginsForTests,
  saveLogin,
  storeState,
  STORE_VERSION,
  TAMPERED_STORE,
  UNREADABLE_STORE,
} = await import('./browser-passwords')

const dirs: string[] = []

function userData(): string {
  const dir = mkdtempSync(join(tmpdir(), 'terminaldeck-logins-'))
  dirs.push(dir)
  return dir
}

afterAll(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true })
})

beforeEach(() => {
  store.available = true
  resetLoginsForTests()
})

const entry = {
  profileId: 'default',
  origin: 'https://example.com',
  username: 'ada',
  password: 'hunter2',
  updatedAt: 1,
}

describe('the saved-password store', () => {
  it('saves and reads back through the protected write path', () => {
    const dir = userData()
    expect(saveLogin(dir, entry).ok).toBe(true)

    resetLoginsForTests()
    expect(allLogins(dir)).toEqual([entry])

    // Written as text, which is what `writeSecretFile` writes — and the reason
    // the migration below has to exist.
    const raw = readFileSync(loginsPath(dir), 'utf8')
    expect(raw).toMatch(/^[A-Za-z0-9+/]+={0,2}$/)
    // The password is not sitting in the file in the clear.
    expect(raw).not.toContain('hunter2')
  })

  it('still reads a store an older build wrote raw', () => {
    /*
     * The migration. Before this change the blob went to disk as bytes; now it
     * goes as base64. A reader that only understood the new spelling would
     * answer `[]` for every existing user — and `[]` is exactly what this
     * module answers for a store encrypted by another OS user, so there would
     * be no error, no warning, and no sign that anything had been lost.
     */
    const dir = userData()
    const legacy = Buffer.concat([
      Buffer.from('v10'),
      Buffer.from(JSON.stringify({ version: 1, entries: [entry] }), 'utf8'),
    ])
    writeFileSync(loginsPath(dir), legacy)

    expect(allLogins(dir)).toEqual([entry])
  })

  it('rewrites a legacy store in the new spelling once it is touched', () => {
    /*
     * This used to say a read must never write, and that there was nothing to
     * gain from rewriting a file nobody changed. The second half stopped being
     * true: a version-1 payload carries no digest, so until it is rewritten the
     * integrity check guards nothing — and the alternative is telling somebody
     * to re-save their passwords to get a format they have never heard of,
     * which is resistance invented out of thin air. So the upgrade now happens
     * on the first read as well, and the case below still holds either way.
     */
    const dir = userData()
    writeFileSync(
      loginsPath(dir),
      Buffer.concat([
        Buffer.from('v10'),
        Buffer.from(JSON.stringify({ version: 1, entries: [entry] }), 'utf8'),
      ]),
    )
    expect(allLogins(dir)).toHaveLength(1)

    expect(saveLogin(dir, { ...entry, username: 'grace' }).ok).toBe(true)
    expect(readFileSync(loginsPath(dir), 'utf8')).toMatch(/^[A-Za-z0-9+/]+={0,2}$/)

    resetLoginsForTests()
    expect(allLogins(dir).map((row) => row.username).sort()).toEqual(['ada', 'grace'])
  })

  it('treats a store it cannot decrypt as absent rather than failing to open', () => {
    // Encrypted by a different OS user, a different machine, or an older
    // format. The alternative is a browser that will not open because a file it
    // cannot read exists.
    const dir = userData()
    writeFileSync(loginsPath(dir), Buffer.from('not ciphertext at all'))
    expect(allLogins(dir)).toEqual([])
  })

  it('says there is a file it cannot open, rather than "nothing saved yet"', () => {
    /*
     * The same emptiness, two completely different facts. A profile folder
     * carried over from another machine holds somebody's passwords and no key
     * to them; a screen that says "nothing saved yet" over it is how they
     * conclude this app lost them.
     */
    const dir = userData()
    writeFileSync(loginsPath(dir), Buffer.from('not ciphertext at all'))
    const state = storeState(dir)
    expect(state.fault).toBe('unreadable')
    expect(state.message).toBe(UNREADABLE_STORE)
    expect(state.exists).toBe(true)
  })

  it('still lets a password be saved over an unreadable file, and says so first', () => {
    /*
     * Not refused, unlike a tampered store. Nobody can recover a blob whose key
     * is on another machine, so refusing would leave somebody permanently
     * unable to use the feature on a profile they carried over — resistance
     * with nothing at the end of it. The warning carries the consequence.
     */
    const dir = userData()
    writeFileSync(loginsPath(dir), Buffer.from('not ciphertext at all'))
    expect(storeState(dir).fault).toBe('unreadable')
    expect(UNREADABLE_STORE).toMatch(/write over it/)

    expect(saveLogin(dir, entry).ok).toBe(true)
    expect(storeState(dir).fault).toBe('none')

    resetLoginsForTests()
    expect(allLogins(dir)).toEqual([entry])
  })

  it('says nothing about an unreadable file on a machine that cannot decrypt anything', () => {
    // Two explanations for one screen is worse than one. A machine with no
    // secure store already has its own sentence, and every file looks
    // unreadable there.
    store.available = false
    const dir = userData()
    writeFileSync(loginsPath(dir), Buffer.from('not ciphertext at all'))
    expect(storeState(dir).fault).toBe('none')
    expect(storeState(dir).available).toBe(false)
  })

  it('refuses to save when the OS has no secure store', () => {
    store.available = false
    const dir = userData()
    const outcome = saveLogin(dir, entry)
    expect(outcome.ok).toBe(false)
    expect(outcome.message).not.toBe('')
  })
})

/**
 * The half `safeStorage` does not do, measured rather than assumed.
 *
 * Electron 41.10.5 on macOS, probed with no window: encrypting the same string
 * twice gives byte-identical output, and flipping one bit in an early block is
 * **accepted** — the plaintext comes back with sixteen bytes rewritten. That is
 * AES-CBC with no authentication tag, which is confidentiality and not
 * integrity. Anybody who can write this file can therefore try to move a stored
 * origin onto a host they control, and the next visit types the person's
 * password into it.
 *
 * The mock's `v10` + plaintext is not CBC, so a bit flip in it is not literally
 * the same attack. It does not need to be: what is under test is that the store
 * refuses a payload whose digest does not describe its entries, however that
 * payload came to be.
 */
describe('a store somebody edited', () => {
  function writeRaw(dir: string, payload: unknown): void {
    writeFileSync(
      loginsPath(dir),
      Buffer.concat([Buffer.from('v10'), Buffer.from(JSON.stringify(payload), 'utf8')]),
    )
  }

  it('writes a digest over the entries, inside the encryption', () => {
    const dir = userData()
    saveLogin(dir, entry)
    const payload = JSON.parse(
      Buffer.from(readFileSync(loginsPath(dir), 'utf8'), 'base64').subarray(3).toString('utf8'),
    ) as { version: number; digest: string }
    expect(payload.version).toBe(STORE_VERSION)
    expect(payload.digest).toMatch(/^[0-9a-f]{64}$/)
  })

  it('is reported, and is not read as an empty store', () => {
    /*
     * The distinction the whole fault exists for. "No saved passwords" is the
     * right answer for a blob from another machine and a dangerous one here:
     * the person sees nothing, saves everything again, and hands it to whoever
     * is editing the file.
     */
    const dir = userData()
    saveLogin(dir, entry)
    resetLoginsForTests()
    writeRaw(dir, {
      version: STORE_VERSION,
      entries: [{ ...entry, origin: 'https://not-example.com' }],
      digest: 'a'.repeat(64),
    })

    expect(allLogins(dir)).toEqual([])
    const state = storeState(dir)
    expect(state.fault).toBe('tampered')
    expect(state.message).toBe(TAMPERED_STORE)
    expect(state.path).toBe(loginsPath(dir))
  })

  it('is never written over, so the evidence survives and the fault cannot be laundered', () => {
    const dir = userData()
    writeRaw(dir, { version: STORE_VERSION, entries: [entry], digest: 'b'.repeat(64) })
    expect(storeState(dir).fault).toBe('tampered')

    const outcome = saveLogin(dir, { ...entry, username: 'grace' })
    expect(outcome.ok).toBe(false)
    expect(outcome.message).toBe(TAMPERED_STORE)
  })

  it('is cleared by forgetting everything, which is what its own sentence offers', () => {
    const dir = userData()
    writeRaw(dir, { version: STORE_VERSION, entries: [entry], digest: 'c'.repeat(64) })
    expect(storeState(dir).fault).toBe('tampered')

    expect(forgetAllLogins(dir).ok).toBe(true)
    const after = storeState(dir)
    expect(after.fault).toBe('none')
    expect(after.exists).toBe(false)
    // And saving works again, because there is nothing left to be wrong.
    expect(saveLogin(dir, entry).ok).toBe(true)
  })

  it('leaves a store written before digests existed alone, and upgrades it', () => {
    // Refusing an undigested payload would delete somebody's passwords to make
    // a point about a format they have never heard of.
    const dir = userData()
    writeRaw(dir, { version: 1, entries: [entry] })

    expect(allLogins(dir)).toEqual([entry])
    expect(storeState(dir).fault).toBe('none')

    resetLoginsForTests()
    const payload = JSON.parse(
      Buffer.from(readFileSync(loginsPath(dir), 'utf8'), 'base64').subarray(3).toString('utf8'),
    ) as { version: number; digest: string }
    expect(payload.version).toBe(STORE_VERSION)
    expect(payload.digest).toMatch(/^[0-9a-f]{64}$/)
  })
})
