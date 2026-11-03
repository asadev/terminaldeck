import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { DEFAULT_PORT, ServerStore, addressProblem, normaliseAddress, readServers } from './store'

/**
 * The list of servers, which holds no secret and one thing that matters.
 *
 * The thing that matters is the host key fingerprint. It is public by
 * construction — that is the whole point of it — but it is what the identity
 * check compares against, so an account that can rewrite this file can silently
 * point somebody's server at a machine that is not theirs and the check will
 * still pass. Hence the file is written the same way the credentials are.
 */

let dir = ''
let store: ServerStore

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-server-store-'))
  store = new ServerStore(dir)
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('what may be typed into the address box', () => {
  it('accepts the four shapes a real server actually has', () => {
    for (const address of ['example.com', '203.0.113.10', 'box.local', '2001:db8::1']) {
      expect(addressProblem(address), address).toBeNull()
    }
  })

  it('catches the mistake a person actually makes, and says what to do', () => {
    // Pasting a whole connection line into the address box is the single most
    // likely first attempt. The alternative to catching it here is a
    // name-resolution failure twenty seconds later that says nothing useful.
    expect(addressProblem('root@example.com')).toMatch(/part after the @/)
    expect(addressProblem('https://example.com')).toMatch(/no web address/)
    expect(addressProblem('example .com')).toMatch(/space/)
    expect(addressProblem('')).toMatch(/An address is needed/)
  })

  it('takes the brackets off a literal address, because that is not part of it', () => {
    expect(normaliseAddress('[2001:db8::1]')).toBe('2001:db8::1')
    expect(normaliseAddress(' example.com ')).toBe('example.com')
  })
})

describe('adding one', () => {
  it('fills in the port nobody wants to be asked about', () => {
    const server = store.add({ name: 'my server', address: 'example.com', username: 'ada' })
    expect(server.port).toBe(DEFAULT_PORT)
    expect(server.credential).toBe('none')
    expect(server.hostKey).toBeNull()
  })

  it('falls back to the address when nobody typed a name', () => {
    // Better than "Untitled": the address is the one thing they definitely
    // know, and a list of "Untitled, Untitled, Untitled" is unusable.
    expect(store.add({ name: '  ', address: 'example.com', username: 'ada' }).name).toBe(
      'example.com',
    )
  })

  it('says what is missing rather than saving something that cannot connect', () => {
    expect(() => store.add({ name: 'x', address: 'example.com', username: ' ' })).toThrow(
      /A username is needed/,
    )
    expect(() => store.add({ name: 'x', address: 'a b', username: 'ada' })).toThrow(/space/)
  })

  it('survives being reopened', () => {
    const server = store.add({ name: 'my server', address: 'example.com', username: 'ada' })
    expect(new ServerStore(dir).get(server.id)).toMatchObject({ name: 'my server' })
  })
})

describe('the identity', () => {
  it('is recorded once and then never quietly replaced', () => {
    const server = store.add({ name: 'x', address: 'example.com', username: 'ada' })
    expect(store.rememberHostKey(server.id, 'ssh-ed25519', 'SHA256:first')).toBe(true)
    // The overwrite is the whole vulnerability: a check that adopts whatever it
    // is shown has checked nothing.
    expect(store.rememberHostKey(server.id, 'ssh-ed25519', 'SHA256:second')).toBe(false)
    expect(store.get(server.id)?.hostKey?.fingerprint).toBe('SHA256:first')
  })

  it('can be cleared deliberately, which is a different act with a different name', () => {
    const server = store.add({ name: 'x', address: 'example.com', username: 'ada' })
    store.rememberHostKey(server.id, 'ssh-ed25519', 'SHA256:first')
    expect(store.forgetHostKey(server.id)).toBe(true)
    expect(store.get(server.id)?.hostKey).toBeNull()
  })

  it('drops a stored fingerprint that is not one', () => {
    // A file this app did not write, or one an older version did. An entry that
    // is not a `SHA256:` string cannot be compared against anything, and
    // keeping it would mean a comparison that always fails.
    expect(readServers({ servers: [row({ hostKey: { fingerprint: 'MD5:aa' } })] })[0].hostKey).toBe(
      null,
    )
  })
})

describe('reading a file that may not be ours', () => {
  it('drops a row that could never connect', () => {
    expect(readServers({ servers: [row({ id: '' })] })).toEqual([])
    expect(readServers({ servers: [row({ address: 'root@x' })] })).toEqual([])
  })

  it('reads nothing out of nonsense rather than throwing', () => {
    // A panel that will not open because a file it cannot parse exists is worse
    // than one that has forgotten a list somebody can retype.
    for (const nonsense of [null, 42, 'text', {}, { servers: 'no' }, { servers: [1, null] }]) {
      expect(readServers(nonsense)).toEqual([])
    }
  })

  it('opens with an empty list when the file on disk is not readable', () => {
    writeFileSync(join(dir, 'servers.json'), 'not json at all')
    expect(new ServerStore(dir).list()).toEqual([])
  })

  it('refuses a credential kind it does not know', () => {
    expect(readServers({ servers: [row({ credential: 'magic' })] })[0].credential).toBe('none')
  })
})

describe('whether its sessions may drive a browser window here', () => {
  it('is open for a server the person just added — adding it is the allowing', () => {
    // T30: the connection IS the authorization. The person typed this server's
    // address and their own sign-in; there is no second switch to find.
    const server = store.add({ name: 'x', address: 'example.com', username: 'ada' })
    expect(store.list()[0].drivesWindows).toBe(true)
    expect(store.drivesWindows(server.id)).toBe(true)
  })

  it('is closed for a server this store has never heard of', () => {
    expect(store.drivesWindows('nothing like this')).toBe(false)
  })

  it('is open for a row written before the field existed, which is his own servers.json', () => {
    /*
     * "Office PC" in his real file has no `drivesWindows` key at all — every
     * server stored before the field existed looks like this — and reading
     * that as closed is exactly how he reproduced his own filmed complaint.
     * Absent is the default, and the default is on.
     */
    expect(readServers({ servers: [row()] })[0].drivesWindows).toBe(true)
  })

  it('survives a restart, because the agent using it does', () => {
    const server = store.add({ name: 'x', address: 'example.com', username: 'ada' })
    expect(store.setDrivesWindows(server.id, false)).toBe(false)
    expect(new ServerStore(dir).drivesWindows(server.id)).toBe(false)
    expect(store.setDrivesWindows(server.id, true)).toBe(true)
    expect(new ServerStore(dir).drivesWindows(server.id)).toBe(true)
  })

  it('answers false for a server it could not store the answer against', () => {
    // A control that shows the state it was just pressed into, over a store
    // that holds nothing, is the dead control this round is about.
    expect(store.setDrivesWindows('no such server', true)).toBe(false)
  })

  it('reads only the literal false as the person having said no', () => {
    // The app only ever writes booleans, so anything else in the file is not
    // an answer a person gave through a control — it reads as the default
    // rather than being parsed by truthiness.
    expect(readServers({ servers: [row({ drivesWindows: false })] })[0].drivesWindows).toBe(false)
    expect(readServers({ servers: [row({ drivesWindows: true })] })[0].drivesWindows).toBe(true)
    expect(readServers({ servers: [row({ drivesWindows: 'yes' })] })[0].drivesWindows).toBe(true)
  })
})

describe('what reaches the disk', () => {
  it('is a list of names and addresses and nothing else', () => {
    const server = store.add({ name: 'x', address: 'example.com', username: 'ada' })
    store.setCredentialKind(server.id, 'password')
    const written = readFileSync(join(dir, 'servers.json'), 'utf8')
    // The word for the kind, never anything that could be a secret. If a
    // password ever appears in this file it is because somebody merged the two
    // stores, which is exactly what the split exists to prevent.
    expect(written).toContain('"credential":"password"')
    expect(written).not.toMatch(/passphrase|privateKey|"password":"/)
  })
})

function row(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: 'server-1',
    name: 'x',
    address: 'example.com',
    port: 22,
    username: 'ada',
    credential: 'none',
    hostKey: null,
    addedAt: 1,
    lastConnectedAt: null,
    ...over,
  }
}
