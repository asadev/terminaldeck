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

const { allLogins, loginsPath, resetLoginsForTests, saveLogin } = await import(
  './browser-passwords'
)

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
    // Migration happens on the next save rather than on read: a read must never
    // write, and there is nothing to gain from rewriting a file nobody changed.
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

  it('refuses to save when the OS has no secure store', () => {
    store.available = false
    const dir = userData()
    const outcome = saveLogin(dir, entry)
    expect(outcome.ok).toBe(false)
    expect(outcome.message).not.toBe('')
  })
})
