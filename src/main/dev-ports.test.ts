import { beforeEach, describe, expect, it, vi } from 'vitest'
import { resetDevPortsCache, scanDevPorts, scanDevPortsDetailed } from './dev-ports'

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
  /** `lsof -F` output — the form the scan actually asks for first. */
  lsofFields: '' as string | Error,
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
    args: readonly string[],
  ): Promise<{ stdout: string; stderr: string }> => {
    state.ran.push(file)
    // Both `lsof` calls are the same binary and differ only in their flags, so
    // the fake has to read the flags too — otherwise the field-mode call is
    // handed column output, parses to nothing, and every case here silently
    // exercises the fallback instead of the path that ships.
    if (file === 'lsof') {
      return answer(args.includes('-FpcRtn') ? state.lsofFields : state.lsof)
    }
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

/**
 * The same machine as {@link LSOF}, in `lsof -F` field mode.
 *
 * One value per line behind a single-letter tag: `p` opens a process set, `R`
 * is its parent, `c` its untruncated command, then one `f`/`t`/`n` block per
 * socket. Shaped after real output from `lsof -nP -iTCP -sTCP:LISTEN -FpcRtn`
 * on the machine this was written on.
 */
const LSOF_FIELDS = [
  'p1',
  'R0',
  'claunchd',
  'f10',
  'tIPv4',
  'n*:445',
  'p12044',
  'R1',
  'cnode',
  'f16',
  'tIPv4',
  'n127.0.0.1:5173',
  'f17',
  'tIPv6',
  'n[::1]:5173',
  'p6001',
  'R1',
  'cPython',
  'f4',
  'tIPv4',
  'n127.0.0.1:9333',
  '',
].join('\n')

beforeEach(() => {
  state.ran = []
  state.lsof = LSOF
  state.lsofFields = LSOF_FIELDS
  state.netstat = NETSTAT
  state.tasklist = TASKLIST
  resetDevPortsCache()
})

describe('scanning on macOS', () => {
  it('asks lsof, once', async () => {
    const ports = await scanDevPorts(true, 'darwin')
    expect(state.ran).toEqual(['lsof'])
    expect(ports).toEqual([
      { port: 5173, process: 'node', guessed: false, ours: false },
      { port: 9333, process: 'Python', guessed: false, ours: false },
    ])
  })
})

describe('scanning on Windows', () => {
  it('asks netstat and tasklist together, and joins them', async () => {
    const ports = await scanDevPorts(true, 'win32')
    expect(state.ran.sort()).toEqual(['netstat.exe', 'tasklist.exe'])
    expect(ports).toEqual([
      { port: 5173, process: 'node', guessed: false, ours: false },
      // Nothing named 6001, so the port is offered as a guess rather than
      // dropped or given an invented owner.
      { port: 9333, process: 'unknown', guessed: true, ours: false },
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
      { port: 445, process: 'unknown', guessed: true, ours: false },
      { port: 5173, process: 'unknown', guessed: true, ours: false },
      { port: 9333, process: 'unknown', guessed: true, ours: false },
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

  it('answers the detailed and the wire caller off one scan', async () => {
    // Two scans would mean the list a phone was shown and the list a
    // `tunnel.open` is checked against could disagree about the same machine.
    await scanDevPortsDetailed(true, 'darwin')
    await scanDevPorts(false, 'darwin')
    expect(state.ran).toEqual(['lsof'])
  })
})

describe('which loopbacks a port answers on', () => {
  it('unions both rows of a dual-stack server rather than keeping the first', async () => {
    // 5173 is listed twice, IPv4 and IPv6. The *name* has to come from one row
    // — there is only one honest answer to "what holds this port" — but there
    // are two honest answers to "where does it answer", and dropping the second
    // is what left an IPv6-only dev server listed and unreachable on Windows.
    const ports = await scanDevPortsDetailed(true, 'darwin')
    expect(ports.find((port) => port.port === 5173)?.families).toEqual({ v4: true, v6: true })
    expect(ports.find((port) => port.port === 9333)?.families).toEqual({ v4: true, v6: false })
  })

  it('reports an IPv6-only Windows dev server as IPv6-only', async () => {
    // The whole bug: `node --host localhost` on Windows binds `::1` and nothing
    // else, so this is the row the tunnel has to dial `::1` for.
    state.netstat = [
      '  Proto  Local Address          Foreign Address        State           PID',
      '  TCP    [::1]:5173             [::]:0                 LISTENING       12044',
    ].join('\r\n')
    const ports = await scanDevPortsDetailed(true, 'win32')
    expect(ports).toEqual([
      { port: 5173, process: 'node', guessed: false, ours: false, families: { v4: false, v6: true } },
    ])
  })

  it('keeps the families out of the answer the renderer and the phone get', async () => {
    const ports = await scanDevPorts(true, 'darwin')
    expect(ports.every((port) => !('families' in port))).toBe(true)
  })
})

/**
 * The recording of 2026-08-16, at the exact frame the browser's start page came
 * up: nine ports offered as pages, eight of them Terminal Deck's own, all eight
 * labelled `Terminal`. Clicking one loaded a black page reading "that is not how
 * to ask" — the pairing server refusing a plain GET.
 *
 * Two separate faults, and these hold both down: `lsof`'s column output clamps
 * COMMAND to nine characters (so `Terminal Deck` prints as `Terminal`, and eight
 * different listeners look like one thing), and nothing anywhere knew that those
 * listeners were ours.
 */
describe('this app’s own ports', () => {
  /** A field-mode scan owned by three processes: ours, our child, and a stranger. */
  const withOurs = (): string =>
    [
      `p${process.pid}`,
      'R1',
      'cElectron',
      'f34',
      'tIPv4',
      'n127.0.0.1:9444',
      // A helper process: a different pid, but our own as its parent. This is
      // the row a pid-only test with no parent would miss.
      'p99001',
      `R${process.pid}`,
      'cElectron Helper (Renderer)',
      'f12',
      'tIPv4',
      'n127.0.0.1:54292',
      // A second copy of the packaged app. Nothing links it to this process, so
      // only the product name can catch it — and it produces the identical dead
      // click, because it is the same refusal from the same server.
      'p78868',
      'R1',
      'cTerminal Deck',
      'f38',
      'tIPv4',
      'n127.0.0.1:8443',
      'p12044',
      'R1',
      'cnode',
      'f16',
      'tIPv4',
      'n127.0.0.1:5173',
      '',
    ].join('\n')

  it('marks the ports this very process is holding', async () => {
    state.lsofFields = withOurs()
    const ports = await scanDevPorts(true, 'darwin')
    expect(ports.find((port) => port.port === 9444)?.ours).toBe(true)
  })

  it('marks a helper process’s port, by its parent', async () => {
    state.lsofFields = withOurs()
    const ports = await scanDevPorts(true, 'darwin')
    expect(ports.find((port) => port.port === 54292)?.ours).toBe(true)
  })

  it('marks a second copy of the app, by name', async () => {
    state.lsofFields = withOurs()
    const ports = await scanDevPorts(true, 'darwin')
    expect(ports.find((port) => port.port === 8443)?.ours).toBe(true)
  })

  it('leaves somebody else’s dev server alone', async () => {
    state.lsofFields = withOurs()
    const ports = await scanDevPorts(true, 'darwin')
    expect(ports.find((port) => port.port === 5173)?.ours).toBe(false)
  })

  it('sorts our own ports below every port that is a real page', async () => {
    state.lsofFields = withOurs()
    const ports = await scanDevPorts(true, 'darwin')
    expect(ports[0]).toMatchObject({ port: 5173, ours: false })
    expect(ports.slice(1).every((port) => port.ours)).toBe(true)
  })
})

describe('the untruncated process name', () => {
  it('reads the command field, not the nine characters the columns allow', async () => {
    // `lsof` pads COMMAND to nine characters in its column output. That is the
    // whole reason eight different listeners read as one word on his screen.
    state.lsofFields = [
      'p751',
      'R1',
      'cControlCenter',
      'f12',
      'tIPv4',
      'n*:5000',
      'p96534',
      'R1',
      'cGoogle Chrome',
      'f48',
      'tIPv4',
      'n127.0.0.1:9333',
      'p12044',
      'R1',
      'cnode',
      'f16',
      'tIPv4',
      'n127.0.0.1:5173',
      '',
    ].join('\n')
    const ports = await scanDevPorts(true, 'darwin')
    // Both of those are on the exclusion list under their *truncated* spellings
    // — `ControlCe` and `Google` — because the list was written against column
    // output. Un-truncating the names must not quietly un-exclude them: Chrome's
    // debugging port reappearing as a suggested dev server is what happened on
    // the first attempt at this change.
    expect(ports.map((port) => port.port)).toEqual([5173])
  })

  it('falls back to the column scan when field mode gives nothing', async () => {
    // `-F` is old and universal, but this spawns somebody else's binary. A build
    // that refuses these fields should cost the names, not the list.
    state.lsofFields = new Error('lsof: unsupported field')
    const ports = await scanDevPorts(true, 'darwin')
    expect(state.ran).toEqual(['lsof', 'lsof'])
    expect(ports.map((port) => port.port)).toEqual([5173, 9333])
  })
})
