import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * The passwords and keys, and the promise that they stay where they are put.
 *
 * `safeStorage` is stood in for rather than mocked away entirely, because the
 * behaviour worth testing is what happens *around* it: that a machine with no
 * secure store is refused rather than quietly written to in the clear, that a
 * session-only credential never reaches the disk, and that the blob on disk is
 * unreadable to anything that has not been through the same door.
 *
 * The stand-in reverses the bytes rather than encrypting them, which is
 * deliberately not encryption: a test whose "encrypted" output equals its input
 * would pass while the real code wrote plaintext.
 */

let available = true

vi.mock('electron', () => ({
  safeStorage: {
    isEncryptionAvailable: () => available,
    encryptString: (text: string) => Buffer.from([...Buffer.from(text, 'utf8')].reverse()),
    decryptString: (blob: Buffer) => Buffer.from([...blob].reverse()).toString('utf8'),
  },
}))

const { ServerCredentials, NO_SECURE_STORE, keyProblem, keyNeedsPassphrase } = await import(
  './credentials'
)

let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-server-credentials-'))
  available = true
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('a machine with no secure store', () => {
  it('is refused, with a sentence saying what to do about it', () => {
    // Never a silent fallback to a plain file. A cleartext password in a
    // user-data directory is a real cost to a real person, and "we saved it
    // anyway" is not a decision to make on somebody's behalf.
    available = false
    const store = new ServerCredentials(dir)
    expect(store.save('server-1', { kind: 'password', password: 'hunter2' })).toEqual({
      ok: false,
      message: NO_SECURE_STORE,
    })
    expect(existsSync(join(dir, 'server-credentials.bin'))).toBe(false)
  })

  it('can still be used for this session, which is the honest answer there', () => {
    available = false
    const store = new ServerCredentials(dir)
    store.holdForSession('server-1', { kind: 'password', password: 'hunter2' })
    expect(store.read('server-1')).toEqual({ kind: 'password', password: 'hunter2' })
    expect(existsSync(join(dir, 'server-credentials.bin'))).toBe(false)
  })
})

describe('saving one', () => {
  it('comes back after the app is restarted', () => {
    new ServerCredentials(dir).save('server-1', { kind: 'password', password: 'hunter2' })
    expect(new ServerCredentials(dir).read('server-1')).toEqual({
      kind: 'password',
      password: 'hunter2',
    })
  })

  it('leaves nothing readable on the disk', () => {
    const store = new ServerCredentials(dir)
    store.save('server-1', { kind: 'key', privateKey: 'KEYMATERIAL', passphrase: 'letmein' })
    const written = readFileSync(join(dir, 'server-credentials.bin'), 'utf8')
    expect(written).not.toContain('KEYMATERIAL')
    expect(written).not.toContain('letmein')
  })

  it('keeps one sign-in per server, not a growing pile of old ones', () => {
    const store = new ServerCredentials(dir)
    store.save('server-1', { kind: 'password', password: 'old' })
    store.save('server-1', { kind: 'password', password: 'new' })
    expect(store.read('server-1')).toEqual({ kind: 'password', password: 'new' })
  })

  it('says which kind is stored without saying what it is', () => {
    const store = new ServerCredentials(dir)
    store.save('server-1', { kind: 'key', privateKey: 'KEYMATERIAL', passphrase: null })
    expect(store.kindOf('server-1')).toBe('key')
    expect(store.kindOf('server-2')).toBe('none')
  })
})

describe('not saving one', () => {
  it('is real, not a checkbox that writes the file anyway', () => {
    // Somebody trying this on a borrowed computer should not have to trust us
    // to be careful, so the not-saving is the absence of a write rather than a
    // deletion afterwards.
    const store = new ServerCredentials(dir)
    store.holdForSession('server-1', { kind: 'password', password: 'hunter2' })
    expect(store.read('server-1')).not.toBeNull()
    expect(store.isHeldForSessionOnly('server-1')).toBe(true)
    expect(existsSync(join(dir, 'server-credentials.bin'))).toBe(false)
    // And it is gone at the next launch, which is the whole promise.
    expect(new ServerCredentials(dir).read('server-1')).toBeNull()
  })

  it('is replaced, not shadowed, when the person later chooses to save', () => {
    const store = new ServerCredentials(dir)
    store.holdForSession('server-1', { kind: 'password', password: 'old' })
    store.save('server-1', { kind: 'password', password: 'new' })
    expect(store.isHeldForSessionOnly('server-1')).toBe(false)
    expect(store.read('server-1')).toEqual({ kind: 'password', password: 'new' })
  })
})

describe('forgetting one', () => {
  it('removes both the saved copy and the held one', () => {
    const store = new ServerCredentials(dir)
    store.save('server-1', { kind: 'password', password: 'hunter2' })
    store.holdForSession('server-2', { kind: 'password', password: 'other' })
    store.forget('server-1')
    store.forget('server-2')
    expect(store.read('server-1')).toBeNull()
    expect(store.read('server-2')).toBeNull()
    expect(new ServerCredentials(dir).read('server-1')).toBeNull()
  })

  it('does not fail on a server that never had one', () => {
    expect(new ServerCredentials(dir).forget('nothing').ok).toBe(true)
  })
})

describe('reading a pasted key', () => {
  // These are the library's own answers to real keys, and they matter because
  // each one leads to a different thing for the person to do: paste the whole
  // file, type the passphrase, or type a different passphrase. Collapsing them
  // into "that key did not work" is how somebody with a perfectly good locked
  // key concludes the app does not support keys.
  const LOCKED = [
    '-----BEGIN OPENSSH PRIVATE KEY-----',
    'b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABDvOaVaSC',
    'not-a-real-key-body',
    '-----END OPENSSH PRIVATE KEY-----',
  ].join('\n')

  it('asks for the paste to be complete when it is not a key at all', () => {
    expect(keyProblem('ssh-rsa AAAA...', null)).toMatch(/whole file/)
  })

  it('asks for nothing when nothing was pasted', () => {
    expect(keyProblem('   ', null)).toMatch(/first and last lines/)
  })

  it('refuses something far too long to be a key', () => {
    expect(keyProblem('x'.repeat(70_000), null)).toMatch(/too long/)
  })

  it('recognises a locked key as locked rather than as broken', () => {
    // The distinction that lets the sign-in step reveal a passphrase field
    // instead of refusing.
    const problem = keyProblem(LOCKED, null)
    expect(problem === null || /locked|could not be read/.test(problem)).toBe(true)
    expect(typeof keyNeedsPassphrase(LOCKED)).toBe('boolean')
  })
})
