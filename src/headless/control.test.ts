import { mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import {
  callControl,
  clearDaemonRecord,
  controlPaths,
  encodeRequest,
  parseDaemonRecord,
  parseRequest,
  parseResponse,
  processAlive,
  readDaemonRecord,
  serveControl,
  tokenMatches,
  writeDaemonRecord,
  type ControlServer,
} from './control'

const made: string[] = []
const servers: ControlServer[] = []

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'td-control-'))
  made.push(dir)
  return dir
}

afterEach(async () => {
  for (const server of servers.splice(0)) await server.close()
  for (const dir of made.splice(0)) rmSync(dir, { recursive: true, force: true })
})

describe('controlPaths', () => {
  it('keeps the socket beside the state rather than in /tmp', () => {
    // /tmp is shared and world-writable, and a control socket a stranger can
    // pre-create is a control socket a stranger can answer.
    const { socket, record } = controlPaths('/home/asad/.local/share/terminaldeck', 'linux')
    expect(socket).toBe('/home/asad/.local/share/terminaldeck/host.sock')
    expect(record).toBe('/home/asad/.local/share/terminaldeck/host.json')
  })

  it('uses a named pipe on Windows, unique to the install', () => {
    const one = controlPaths('C:\\Users\\Asad\\AppData\\Roaming\\terminaldeck', 'win32').socket
    const two = controlPaths('D:\\other\\terminaldeck', 'win32').socket
    expect(one.startsWith('\\\\.\\pipe\\terminaldeck-')).toBe(true)
    expect(one).not.toBe(two)
  })
})

describe('the daemon record', () => {
  it('round-trips, and is written 0600', () => {
    // It holds a bearer token. It does not get a weaker file than the relay
    // identity beside it.
    const dir = tempDir()
    writeDaemonRecord(dir, {
      pid: 4242,
      socket: join(dir, 'host.sock'),
      token: 'abc',
      startedAt: 7,
      version: '0.1.8',
    })
    const read = readDaemonRecord(dir)
    expect(read?.pid).toBe(4242)
    expect(read?.token).toBe('abc')
    // Checked where the check means something. Windows has no POSIX permission
    // bits — `fs` reports 0666 for any read-write file — so this record, which
    // holds the daemon's control TOKEN, is NOT mode-protected there; what
    // protects it is the NTFS ACL of the directory it sits in, which nothing
    // here sets. Asserting 0600 on Windows would assert a falsehood.
    if (process.platform !== 'win32') {
      expect(statSync(join(dir, 'host.json')).mode & 0o777).toBe(0o600)
    }
  })

  it('reads a missing record as "no host has run here"', () => {
    expect(readDaemonRecord(tempDir())).toBeNull()
  })

  it('reads a corrupt record the same way rather than throwing', () => {
    // Reporting "not running" for an unreadable record is both true and
    // actionable; throwing on it would make `status` fail on a file nobody can
    // see.
    const dir = tempDir()
    writeDaemonRecord(dir, { pid: 1, socket: 's', token: 't', startedAt: 0, version: 'v' })
    rmSync(join(dir, 'host.json'))
    expect(readDaemonRecord(dir)).toBeNull()
  })

  it('refuses a record missing any field it will be trusted for', () => {
    expect(parseDaemonRecord({ pid: 1, socket: 's', token: 't', startedAt: 0 })).toBeNull()
    expect(parseDaemonRecord({ pid: 0, socket: 's', token: 't', startedAt: 0, version: 'v' })).toBeNull()
    expect(parseDaemonRecord({ pid: 1, socket: '', token: 't', startedAt: 0, version: 'v' })).toBeNull()
    expect(parseDaemonRecord(null)).toBeNull()
  })

  it('clears the record and the socket file together', () => {
    const dir = tempDir()
    writeDaemonRecord(dir, { pid: 1, socket: join(dir, 'host.sock'), token: 't', startedAt: 0, version: 'v' })
    clearDaemonRecord(dir, 'linux')
    expect(readDaemonRecord(dir)).toBeNull()
  })
})

describe('processAlive', () => {
  it('says yes about this process and no about one that cannot exist', () => {
    // Telling "the daemon is running" from "the daemon died and left its record
    // behind" is the difference between `status` reporting not-running and
    // `status` hanging on a socket nobody is listening to.
    expect(processAlive(process.pid)).toBe(true)
    expect(processAlive(0x7ffffff0)).toBe(false)
  })
})

describe('the token', () => {
  it('matches only itself, and does not throw on a different length', () => {
    expect(tokenMatches('abcdef', 'abcdef')).toBe(true)
    expect(tokenMatches('abcdef', 'abcdeg')).toBe(false)
    expect(tokenMatches('abcdef', 'abc')).toBe(false)
    expect(tokenMatches('', '')).toBe(true)
  })
})

describe('framing', () => {
  it('round-trips a request', () => {
    const line = encodeRequest({ token: 't', cmd: 'status', args: [] })
    expect(line.endsWith('\n')).toBe(true)
    expect(parseRequest(line.trim())).toEqual({ token: 't', cmd: 'status', args: [] })
  })

  it('refuses anything that is not a request', () => {
    expect(parseRequest('not json')).toBeNull()
    expect(parseRequest('[]')).toBeNull()
    expect(parseRequest('{"cmd":"status"}')).toBeNull()
    expect(parseRequest('{"token":"t","cmd":"status","args":[1]}')).toBeNull()
  })

  it('turns anything unreadable from the host into a sentence', () => {
    expect(parseResponse('garbage')).toEqual({
      ok: false,
      error: 'The host answered with something that is not a message.',
    })
    expect(parseResponse('{"ok":false}').ok).toBe(false)
  })
})

/*
 * POSIX hosts only, and not because the feature is POSIX-only — it is not.
 *
 * These cases pass `platform: 'linux'` and then genuinely BIND, which is the
 * point: they are the ones that prove framing, tokens and refusals against a
 * real socket rather than a fake. A Unix domain socket needs a POSIX host to
 * bind on, so on Windows the whole block fails with
 * `listen EACCES … \td-control-…\host.sock` — the runner faithfully doing what
 * it was told, in a place Windows has no such thing.
 *
 * Windows is not left unproven by this. It has its own transport — a named pipe,
 * `\\.\pipe\<brand>-<tag>` — and `controlPaths` above pins that name, its
 * uniqueness per install, and the fact that it is not a filesystem path at all.
 * What is genuinely NOT covered anywhere is a live named pipe end to end, and
 * that needs a Windows runner deliberately exercising the win32 branch rather
 * than this block pretending to.
 */
describe.skipIf(process.platform === 'win32')('a live control socket', () => {
  it('carries a command and its answer', async () => {
    const dir = tempDir()
    const socket = join(dir, 'host.sock')
    servers.push(
      await serveControl({
        socket,
        token: 'secret',
        platform: 'linux',
        handle: async (cmd, args) => ({ cmd, args }),
      }),
    )

    const answer = await callControl({ socket, token: 'secret', cmd: 'status', args: ['"x"'] })
    expect(answer).toEqual({ ok: true, value: { cmd: 'status', args: ['"x"'] } })
  })

  it('refuses a caller with the wrong token, in the same words as a missing one', async () => {
    const dir = tempDir()
    const socket = join(dir, 'host.sock')
    servers.push(
      await serveControl({ socket, token: 'secret', platform: 'linux', handle: async () => 'no' }),
    )

    const wrong = await callControl({ socket, token: 'guess', cmd: 'stop' })
    const empty = await callControl({ socket, token: '', cmd: 'stop' })
    expect(wrong).toEqual({ ok: false, error: 'This host did not recognise that caller.' })
    expect(empty).toEqual(wrong)
  })

  it('sends a thrown message back rather than dropping the connection', async () => {
    const dir = tempDir()
    const socket = join(dir, 'host.sock')
    servers.push(
      await serveControl({
        socket,
        token: 't',
        platform: 'linux',
        handle: async () => {
          throw new Error('no such folder')
        },
      }),
    )
    expect(await callControl({ socket, token: 't', cmd: 'folders' })).toEqual({
      ok: false,
      error: 'no such folder',
    })
  })

  /*
   * The sentence is for a person; the `reason` is for `main.ts`.
   *
   * Both are asserted here because the CLI turns exactly this answer into "not
   * running" — deleting the stale record and, for `pair`, starting a host. It
   * can only do that if the failure is told apart by its code rather than by
   * matching on prose, so a `reason` quietly dropped from this response would
   * bring back the bug it was added for: on a WSL distribution that has
   * restarted, a record naming a reused pid made `status` exit 1 and made `pair`
   * refuse to start anything.
   */
  it('says "no host is listening" rather than a syscall name, and codes it', async () => {
    const dir = tempDir()
    const answer = await callControl({
      socket: join(dir, 'nothing.sock'),
      token: 't',
      cmd: 'status',
      timeoutMs: 500,
    })
    expect(answer).toEqual({
      ok: false,
      error: 'No host is listening here.',
      reason: 'no-listener',
    })
  })

  it('takes over a socket file a dead host left behind', async () => {
    // A power cut leaves the file, and `listen` then fails with EADDRINUSE
    // however dead the process behind it is. Without this a host never starts
    // again after one.
    const dir = tempDir()
    const socket = join(dir, 'host.sock')
    servers.push(
      await serveControl({ socket, token: 't', platform: 'linux', handle: async () => 'one' }),
    )
    await servers.pop()?.close()
    servers.push(
      await serveControl({ socket, token: 't', platform: 'linux', handle: async () => 'two' }),
    )
    expect(await callControl({ socket, token: 't', cmd: 'status' })).toEqual({ ok: true, value: 'two' })
  })

  it('writes the record with the socket it is actually listening on', async () => {
    const dir = tempDir()
    const { socket } = controlPaths(dir, 'linux')
    servers.push(
      await serveControl({ socket, token: 'tok', platform: 'linux', handle: async () => 'ok' }),
    )
    writeDaemonRecord(dir, { pid: process.pid, socket, token: 'tok', startedAt: 0, version: 'v' })
    const record = readDaemonRecord(dir)
    expect(record).not.toBeNull()
    if (record === null) return
    expect(JSON.parse(readFileSync(join(dir, 'host.json'), 'utf8')).socket).toBe(socket)
    expect(await callControl({ socket: record.socket, token: record.token, cmd: 'status' })).toEqual({
      ok: true,
      value: 'ok',
    })
  })
})
