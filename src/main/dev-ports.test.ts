import { beforeEach, describe, expect, it, vi } from 'vitest'
import { resetDevPortsCache, scanDevPorts } from './dev-ports'

/**
 * The scan itself, with the operating system faked.
 *
 * `platform/ports.test.ts` pins the parsers against captured output; this pins
 * the layer above them — which commands get spawned on which platform, how the
 * two Windows calls are joined, and that policy (the exclusion list, the
 * ranking, the "we could not name it" flag) survives the port unchanged.
 */

const state = vi.hoisted(() => ({
  ran: [] as string[],
  lsof: '' as string | Error,
  netstat: '' as string | Error,
  tasklist: '' as string | Error,
}))

vi.mock('node:child_process', () => {
  const answer = (from: string | Error): { stdout: string; stderr: string } => {
    if (from instanceof Error) throw from
    return { stdout: from, stderr: '' }
  }
  const execFile = ((): unknown => undefined) as unknown as Record<symbol, unknown>
  execFile[Symbol.for('nodejs.util.promisify.custom')] = async (
    file: string,
  ): Promise<{ stdout: string; stderr: string }> => {
    state.ran.push(file)
    if (file === 'lsof') return answer(state.lsof)
    if (file === 'netstat.exe') return answer(state.netstat)
    if (file === 'tasklist.exe') return answer(state.tasklist)
    throw Object.assign(new Error('ENOENT'), { code: 'ENOENT' })
  }
  return { execFile }
})

const NETSTAT = [
  '  Proto  Local Address          Foreign Address        State           PID',
  '  TCP    0.0.0.0:445            0.0.0.0:0              LISTENING       4',
  '  TCP    127.0.0.1:5173         0.0.0.0:0              LISTENING       12044',
  '  TCP    [::1]:5173             [::]:0                 LISTENING       12044',
  '  TCP    127.0.0.1:9333         0.0.0.0:0              LISTENING       6001',
].join('\r\n')

const TASKLIST = [
  '"System","4","Services","0","2,748 K"',
  '"node.exe","12044","Console","1","98,304 K"',
].join('\r\n')

const LSOF = `COMMAND     PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
launchd       1 apple   10u  IPv4 0x1111111111111111      0t0  TCP *:445 (LISTEN)
node      12044 apple   16u  IPv4 0x2222222222222222      0t0  TCP 127.0.0.1:5173 (LISTEN)
node      12044 apple   17u  IPv6 0x3333333333333333      0t0  TCP [::1]:5173 (LISTEN)
Python     6001 apple    4u  IPv4 0x4444444444444444      0t0  TCP 127.0.0.1:9333 (LISTEN)
`

beforeEach(() => {
  state.ran = []
  state.lsof = LSOF
  state.netstat = NETSTAT
  state.tasklist = TASKLIST
  resetDevPortsCache()
})

describe('scanning on macOS', () => {
  it('asks lsof, once', async () => {
    const ports = await scanDevPorts(true, 'darwin')
    expect(state.ran).toEqual(['lsof'])
    expect(ports).toEqual([
      { port: 5173, process: 'node', guessed: false },
      { port: 9333, process: 'Python', guessed: false },
    ])
  })
})

describe('scanning on Windows', () => {
  it('asks netstat and tasklist together, and joins them', async () => {
    const ports = await scanDevPorts(true, 'win32')
    expect(state.ran.sort()).toEqual(['netstat.exe', 'tasklist.exe'])
    expect(ports).toEqual([
      { port: 5173, process: 'node', guessed: false },
      // Nothing named 6001, so the port is offered as a guess rather than
      // dropped or given an invented owner.
      { port: 9333, process: 'unknown', guessed: true },
    ])
  })

  it('reaches the same answer as macOS for the same machine', async () => {
    // The two platforms are being asked the same question about the same set of
    // listeners. Where both can name the owner, the answers must agree — this is
    // the check that would have caught `node.exe` never matching `node`.
    const windows = await scanDevPorts(true, 'win32')
    resetDevPortsCache()
    const mac = await scanDevPorts(true, 'darwin')
    expect(windows[0]).toEqual(mac[0])
  })

  it('excludes the Windows noise the exclusion list is for', async () => {
    // PID 4 holds 445 on a stock install. Offering it means the very first
    // launch on Windows shows a "dev server" that is the SMB service.
    const ports = await scanDevPorts(true, 'win32')
    expect(ports.map((port) => port.port)).not.toContain(445)
  })

  it('still reports ports when tasklist refuses to answer', async () => {
    // The ports are answering either way; losing the names should cost the
    // names and nothing else.
    state.tasklist = new Error('Access is denied.')
    const ports = await scanDevPorts(true, 'win32')
    expect(state.ran).toContain('netstat.exe')
    expect(ports).toEqual([
      { port: 445, process: 'unknown', guessed: true },
      { port: 5173, process: 'unknown', guessed: true },
      { port: 9333, process: 'unknown', guessed: true },
    ])
  })

  it('falls back to probing when netstat itself cannot run', async () => {
    // A locked-down Windows can refuse it. The fallback probes a fixed list of
    // conventional ports, so the answer holds none of the ports netstat named
    // and everything it does hold is flagged as a guess. Asserted that way
    // rather than as an empty list because the machine running this test may
    // genuinely have something on 3000.
    const FALLBACK = new Set([3000, 5173, 8080, 4200, 8000, 5174, 4321, 3001])
    state.netstat = Object.assign(new Error('ENOENT'), { code: 'ENOENT' })
    const ports = await scanDevPorts(true, 'win32')
    expect(state.ran).toContain('netstat.exe')
    expect(ports.map((port) => port.port)).not.toContain(9333)
    expect(ports.every((port) => port.guessed && FALLBACK.has(port.port))).toBe(true)
  })
})

describe('the cache is shared by both platforms', () => {
  it('answers a second caller without spawning again', async () => {
    await scanDevPorts(true, 'darwin')
    await scanDevPorts(false, 'darwin')
    expect(state.ran).toEqual(['lsof'])
  })
})
