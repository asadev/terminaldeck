import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { generateStatic } from '../../../shared/sealed'
import { hostIdFor } from '../../../shared/relay-wire'
import { MACHINES_FILE, MachineStore, type NewMachine } from './store'

/**
 * The guest's trust store, checked for the two things it must never do: hand
 * the window a secret, and believe a file it cannot read.
 */

const dirs: string[] = []

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'deck-machines-'))
  dirs.push(dir)
  return dir
}

afterEach(() => {
  while (dirs.length > 0) rmSync(dirs.pop() as string, { recursive: true, force: true })
})

function candidate(partial: Partial<NewMachine> = {}): NewMachine {
  return {
    name: 'Studio PC',
    hostId: hostIdFor(Buffer.alloc(32, 7)),
    hostPublicKey: generateStatic().publicKey,
    relayUrl: 'wss://relay.example',
    credential: 'abcdefghijkl.0123456789',
    guestKeys: generateStatic(),
    platform: 'win32',
    ...partial,
  }
}

describe('remembering a machine', () => {
  it('stores it and hands back a row with no secret in it', () => {
    const store = new MachineStore(tempDir())
    const input = candidate()
    const machine = store.remember(input)

    expect(machine.name).toBe('Studio PC')
    expect(machine.hostId).toBe(input.hostId)
    expect(machine.platform).toBe('win32')
    expect(machine.fingerprint).toMatch(/^[A-Z2-9]{4}(-[A-Z2-9]{4}){5}$/)
    // The two things the window must never be handed.
    expect(JSON.stringify(machine)).not.toContain(input.credential)
    expect(JSON.stringify(machine)).not.toContain(input.guestKeys.privateKey.toString('base64'))
  })

  it('keeps the credential and the guest key for the dial, and only there', () => {
    const store = new MachineStore(tempDir())
    const input = candidate()
    const machine = store.remember(input)

    const secrets = store.secrets(machine.id)
    expect(secrets).not.toBeNull()
    expect(secrets?.credential).toBe(input.credential)
    expect(secrets?.guestKeys.privateKey.equals(input.guestKeys.privateKey)).toBe(true)
    expect(secrets?.hostPublicKey.equals(input.hostPublicKey)).toBe(true)
    expect(secrets?.relayUrl).toBe('wss://relay.example')
  })

  it('replaces the row when the same machine is paired again', () => {
    // Two rows for one machine would each hold a different credential and the
    // window would offer the same machine twice with no way to tell them apart.
    const store = new MachineStore(tempDir())
    const hostId = hostIdFor(Buffer.alloc(32, 3))
    store.remember(candidate({ hostId, credential: 'aaaa.1111', name: 'Old name' }))
    store.remember(candidate({ hostId, credential: 'bbbb.2222', name: 'New name' }))

    expect(store.list()).toHaveLength(1)
    expect(store.list()[0].name).toBe('New name')
    expect(store.secrets(hostId)?.credential).toBe('bbbb.2222')
  })

  it('refuses something that is not a host id', () => {
    const store = new MachineStore(tempDir())
    expect(() => store.remember(candidate({ hostId: 'not-a-host-id' }))).toThrow(/host id/)
  })

  it('strips control characters out of a name the far machine chose', () => {
    // The name is rendered next to terminal output, so an escape sequence in it
    // is an injection rather than a label.
    const store = new MachineStore(tempDir())
    const machine = store.remember(candidate({ name: "  \u001b[31mAsad's PC\u0007  " }))
    expect(machine.name).toBe("[31mAsad's PC")
  })
})

describe('the file', () => {
  /*
   * POSIX only, and the reason is a security fact rather than a test detail.
   *
   * Windows has no POSIX permission bits. `fs` synthesises a mode — a
   * read-write file reports 0666 — and honouring 0600 there is simply not
   * something the filesystem does. Asserting 0600 on Windows would therefore be
   * asserting something false, and asserting 0666 would quietly enshrine
   * "unprotected" as the expected answer. Discovered when the Windows CI release
   * build failed on this line: `expected 438 to be 384`.
   *
   * This file holds a plaintext bearer credential per paired machine, so what
   * happens on Windows is not a footnote. It used to be nothing at all — the
   * file was left under whatever ACL `%APPDATA%` handed down, which on a shared
   * PC is routinely readable by the other accounts on it. It is now written
   * under an ACL that names this account and removes the inherited entries, on
   * the folder as well as the file, and the store refuses to write rather than
   * leave a credential it could not lock down. None of that can be exercised
   * from a Mac through a real `icacls`, so it is pinned with an injected runner
   * in `remote/secret-file.test.ts`, where the writer lives; here the check that
   * is real on this platform stays exactly as it was.
   */
  it.skipIf(process.platform === 'win32')('is written 0600, because it holds bearer credentials', () => {
    const dir = tempDir()
    const store = new MachineStore(dir)
    store.remember(candidate())
    expect(statSync(store.file).mode & 0o777).toBe(0o600)
    expect(readFileSync(join(dir, MACHINES_FILE), 'utf8')).toContain('"version": 1')
  })

  it('writes the file wherever it runs, whatever the mode means there', () => {
    const dir = tempDir()
    const store = new MachineStore(dir)
    store.remember(candidate())
    expect(readFileSync(join(dir, MACHINES_FILE), 'utf8')).toContain('"version": 1')
  })

  it('is read back across a restart', () => {
    const dir = tempDir()
    const input = candidate()
    new MachineStore(dir).remember(input)

    const reopened = new MachineStore(dir)
    expect(reopened.list()).toHaveLength(1)
    expect(reopened.secrets(input.hostId)?.credential).toBe(input.credential)
  })

  it('drops a row that is missing any of the four things a dial needs', () => {
    const dir = tempDir()
    const store = new MachineStore(dir)
    const good = candidate()
    store.remember(good)

    // The second row has everything except the private key. It cannot
    // authenticate, and repairing it by guessing is not a thing that exists —
    // so it is dropped and the good one is kept. Written out by hand rather
    // than by editing what the store wrote, because a `delete` on a parsed blob
    // needs a cast to compile and a cast here would be asserting the shape this
    // test exists to damage.
    const otherHostId = hostIdFor(Buffer.alloc(32, 9))
    const row = (id: string, withKey: boolean): Record<string, unknown> => ({
      id,
      name: 'Studio PC',
      hostId: id,
      hostPublicKey: good.hostPublicKey.toString('base64'),
      relayUrl: good.relayUrl,
      credential: good.credential,
      guestPublicKey: good.guestKeys.publicKey.toString('base64'),
      ...(withKey ? { guestPrivateKey: good.guestKeys.privateKey.toString('base64') } : {}),
      platform: 'win32',
      pairedAt: 1,
      lastConnectedAt: null,
    })
    writeFileSync(
      store.file,
      JSON.stringify({ version: 1, machines: [row(good.hostId, true), row(otherHostId, false)] }),
    )

    expect(new MachineStore(dir).list()).toHaveLength(1)
  })

  it('moves a damaged file aside rather than writing over it', () => {
    const dir = tempDir()
    writeFileSync(join(dir, MACHINES_FILE), 'not json at all')
    const store = new MachineStore(dir)
    expect(store.list()).toEqual([])
    expect(readdirSync(dir).some((name) => name.includes('.corrupt-'))).toBe(true)
  })

  it('keeps the first of two rows claiming one machine', () => {
    const dir = tempDir()
    const store = new MachineStore(dir)
    store.remember(candidate())
    const parsed: { machines: unknown[] } = JSON.parse(readFileSync(store.file, 'utf8'))
    parsed.machines.push(parsed.machines[0])
    writeFileSync(store.file, JSON.stringify(parsed))

    expect(new MachineStore(dir).list()).toHaveLength(1)
  })
})

describe('the rest of the list', () => {
  it('forgets one, and says whether there was one to forget', () => {
    const store = new MachineStore(tempDir())
    const machine = store.remember(candidate())
    expect(store.forget(machine.id)).toBe(true)
    expect(store.forget(machine.id)).toBe(false)
    expect(store.list()).toEqual([])
    expect(store.secrets(machine.id)).toBeNull()
  })

  it('renames one, and refuses a name that is nothing', () => {
    const store = new MachineStore(tempDir())
    const machine = store.remember(candidate())
    expect(store.rename(machine.id, 'The loud one')).toBe(true)
    expect(store.list()[0].name).toBe('The loud one')
    expect(store.rename(machine.id, '   ')).toBe(false)
    expect(store.rename(machine.id, 42)).toBe(false)
    expect(store.list()[0].name).toBe('The loud one')
  })

  it('records a connection and the kind of machine it turned out to be', () => {
    let clock = 1_000
    const store = new MachineStore(tempDir(), { now: () => clock })
    const machine = store.remember(candidate({ platform: '' }))
    expect(store.list()[0].lastConnectedAt).toBeNull()

    clock = 5_000
    store.sawWelcome(machine.id, 'darwin')
    expect(store.list()[0].lastConnectedAt).toBe(5_000)
    expect(store.list()[0].platform).toBe('darwin')

    // A machine that says nothing does not un-say what it said before.
    store.sawWelcome(machine.id, '')
    expect(store.list()[0].platform).toBe('darwin')
  })

  it('lets a machine the person paired act on browser windows here, until somebody says no', () => {
    /*
     * T30: the connection IS the authorization. Every row in this store is a
     * machine the person paired with their own hands — they read the code off
     * its screen and typed it here — so pairing it is the allowing, and the
     * switch on the card is the way to say no about one machine. The closed
     * default lives on in `window-grants.ts`, for a device approved as a guest.
     */
    const dir = tempDir()
    const store = new MachineStore(dir)
    const machine = store.remember(candidate())
    expect(store.list()[0].drivesWindows).toBe(true)
    expect(store.drivesWindows(machine.id)).toBe(true)
    // But an id nobody has ever heard of is not a machine that may drive.
    expect(store.drivesWindows('someone-else')).toBe(false)

    expect(store.setDrivesWindows(machine.id, false)).toBe(false)
    expect(store.drivesWindows(machine.id)).toBe(false)
    // It outlives the process, because it is a decision rather than a session.
    expect(new MachineStore(dir).drivesWindows(machine.id)).toBe(false)

    expect(store.setDrivesWindows(machine.id, true)).toBe(true)
    expect(new MachineStore(dir).drivesWindows(machine.id)).toBe(true)
    // A machine that is not there cannot be granted anything, and says so
    // rather than answering with the value it was handed.
    expect(store.setDrivesWindows('someone-else', true)).toBe(false)
  })

  it('reads a row written before the field existed as allowed — his own machines.json', () => {
    /*
     * DESKTOP-DDGMNCV in his real file has no `drivesWindows` key, because the
     * release that paired it predates the field. Reading absent as closed is
     * how every forwarded cross-machine window verb came back refused on the
     * machine he tests against. Absent is the default, and the default is on.
     */
    const dir = tempDir()
    const store = new MachineStore(dir)
    const machine = store.remember(candidate())
    const parsed = JSON.parse(readFileSync(store.file, 'utf8')) as {
      machines: Record<string, unknown>[]
    }
    delete parsed.machines[0].drivesWindows
    writeFileSync(store.file, JSON.stringify(parsed))
    expect(new MachineStore(dir).drivesWindows(machine.id)).toBe(true)
  })

  it('closes on the literal false and on nothing else', () => {
    // The app only writes booleans, so a truthy string in a hand-edited list is
    // not an answer a person gave through a control — it reads as the default
    // rather than being parsed by truthiness, the same refusal to guess that
    // `credential.answer`'s `remember` makes.
    const dir = tempDir()
    const store = new MachineStore(dir)
    const machine = store.remember(candidate())
    const parsed = JSON.parse(readFileSync(store.file, 'utf8')) as {
      machines: Record<string, unknown>[]
    }
    parsed.machines[0].drivesWindows = false
    writeFileSync(store.file, JSON.stringify(parsed))
    expect(new MachineStore(dir).drivesWindows(machine.id)).toBe(false)
  })

  it('mints a fresh guest identity per machine', () => {
    const store = new MachineStore(tempDir())
    const first = store.mintGuestKeys()
    const second = store.mintGuestKeys()
    expect(first.privateKey.equals(second.privateKey)).toBe(false)
  })
})
