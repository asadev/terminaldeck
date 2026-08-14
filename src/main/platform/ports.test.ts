import { describe, expect, it } from 'vitest'
import {
  LSOF,
  NETSTAT,
  TASKLIST,
  isLocallyReachable,
  loopbackFamily,
  parseLsof,
  parseNetstat,
  parseTasklist,
  portScanKind,
  splitHostPort,
  windowsOwners,
} from './ports'

/**
 * ## Where these fixtures came from
 *
 * `LSOF_OUTPUT` is a real `lsof -nP -iTCP -sTCP:LISTEN` capture from the machine
 * this was written on, trimmed and with the device ids left as they came. It
 * carries the cases that matter: the same server listed twice for IPv4 and IPv6,
 * a bare `*:port` wildcard, a `127.0.0.1` bind, and two rows bound to real
 * network addresses that a browser on another machine could reach and that this
 * app must therefore not offer.
 *
 * `TASKLIST_OUTPUT` is **not** a capture — it is written from the documented
 * output format. What it proves is that the decoding is right *if* the capture
 * is right, which is worth having and is not the same thing as being verified.
 *
 * `NETSTAT_OUTPUT` was in the same position until 2026-08-14, when the one row
 * that matters was captured from a real Windows machine (`desktop-ddgmncv`)
 * running a real IPv6-only dev server:
 *
 *     TCP    [::1]:5199             [::]:0                 LISTENING       22200
 *
 * The rest of the block is still written from the documented format; that row
 * is real, and it settles the two things that were guesses — that a v6 listener
 * is labelled `TCP` and that its address is bracketed.
 */

const LSOF_OUTPUT = `COMMAND     PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
rapportd    713 apple   13u  IPv4 0xf2f295526132df51      0t0  TCP *:53397 (LISTEN)
rapportd    713 apple   14u  IPv6  0x17db11441368b6b      0t0  TCP *:53397 (LISTEN)
Macky       738 apple   29u  IPv4 0xb610e039e25a1641      0t0  TCP 192.168.101.223:60293 (LISTEN)
Macky       738 apple   33u  IPv4 0x98d34c40d068135d      0t0  TCP 100.86.107.119:60296 (LISTEN)
ControlCe   745 apple   11u  IPv4 0xbde47004fa22dcfb      0t0  TCP *:5000 (LISTEN)
Python    15193 apple    3u  IPv4 0x824d8e1ea27154f5      0t0  TCP 127.0.0.1:8931 (LISTEN)
node      92487 apple   16u  IPv6 0x7f3d3a1318a297ed      0t0  TCP [::1]:5199 (LISTEN)
node      99468 apple   33u  IPv6 0x5aba6d7d820af189      0t0  TCP *:8081 (LISTEN)
`

const NETSTAT_OUTPUT = [
  '',
  'Active Connections',
  '',
  '  Proto  Local Address          Foreign Address        State           PID',
  '  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       968',
  '  TCP    0.0.0.0:445            0.0.0.0:0              LISTENING       4',
  '  TCP    127.0.0.1:3000         0.0.0.0:0              LISTENING       12044',
  '  TCP    192.168.1.20:139       0.0.0.0:0              LISTENING       4',
  '  TCP    127.0.0.1:3000         127.0.0.1:52001        ESTABLISHED     12044',
  '  TCP    [::]:135               [::]:0                 LISTENING       968',
  '  TCP    [::1]:5199             [::]:0                 LISTENING       7788',
  '  UDP    0.0.0.0:5353           *:*                                    3120',
  '',
].join('\r\n')

const TASKLIST_OUTPUT = [
  '"System Idle Process","0","Services","0","8 K"',
  '"System","4","Services","0","2,748 K"',
  '"svchost.exe","968","Services","0","12,704 K"',
  '"node.exe","12044","Console","1","98,304 K"',
  '',
].join('\r\n')

describe('splitting host from port', () => {
  it('handles the four spellings the two tools use between them', () => {
    expect(splitHostPort('*:53397')).toEqual({ host: '*', port: 53397 })
    expect(splitHostPort('127.0.0.1:8931')).toEqual({ host: '127.0.0.1', port: 8931 })
    expect(splitHostPort('0.0.0.0:135')).toEqual({ host: '0.0.0.0', port: 135 })
    // Four colons, and only the last one separates the port.
    expect(splitHostPort('[::1]:5199')).toEqual({ host: '[::1]', port: 5199 })
  })

  it('refuses anything that is not a port', () => {
    expect(splitHostPort('NAME')).toBeNull()
    expect(splitHostPort('127.0.0.1:0')).toBeNull()
    expect(splitHostPort('127.0.0.1:70000')).toBeNull()
  })

  it('knows which hosts a browser on this machine can reach', () => {
    for (const host of ['', '*', '0.0.0.0', '127.0.0.1', '[::]', '[::1]']) {
      expect(isLocallyReachable(host), host).toBe(true)
    }
    // A LAN or tailnet bind belongs to another machine's browser, not this one.
    expect(isLocallyReachable('192.168.101.223')).toBe(false)
    expect(isLocallyReachable('100.86.107.119')).toBe(false)
  })
})

describe('which loopback a row is on', () => {
  it('trusts lsof’s TYPE column, which is the only thing that reads a wildcard', () => {
    expect(loopbackFamily('*', 'IPv6')).toBe(6)
    expect(loopbackFamily('*', 'IPv4')).toBe(4)
  })

  it('reads the address when netstat calls a v6 row TCP, as a real Windows does', () => {
    // Captured on desktop-ddgmncv: `TCP    [::1]:5199 ...`. A hint of `TCP`
    // must not be taken to mean IPv4, or every IPv6-only Windows dev server is
    // dialled at 127.0.0.1 and refused.
    expect(loopbackFamily('[::1]', 'TCP')).toBe(6)
    expect(loopbackFamily('[::]', 'TCP')).toBe(6)
    expect(loopbackFamily('127.0.0.1', 'TCP')).toBe(4)
    expect(loopbackFamily('0.0.0.0', 'TCP')).toBe(4)
  })

  it('takes TCPv6 as decisive, for the installs that label them that way', () => {
    expect(loopbackFamily('[::1]', 'TCPv6')).toBe(6)
  })

  it('answers IPv4 for anything it does not recognise, which is how it behaved before', () => {
    expect(loopbackFamily('')).toBe(4)
    expect(loopbackFamily('*')).toBe(4)
  })
})

describe('reading lsof (macOS, from a real capture)', () => {
  const owners = parseLsof(LSOF_OUTPUT)

  it('finds every locally reachable listener, and which loopback each is on', () => {
    expect(owners).toEqual([
      { port: 53397, process: 'rapportd', family: 4 },
      { port: 53397, process: 'rapportd', family: 6 },
      { port: 5000, process: 'ControlCe', family: 4 },
      { port: 8931, process: 'Python', family: 4 },
      { port: 5199, process: 'node', family: 6 },
      { port: 8081, process: 'node', family: 6 },
    ])
  })

  it('reads a wildcard row’s family off the TYPE column, since the address cannot say', () => {
    // `*:53397` twice and `*:8081` once. The address is identical either way,
    // so a parser that only looked at the address would call all three IPv4 —
    // and the tunnel would then never try `::1` for a server that is only there.
    const wildcards = owners.filter((owner) => owner.port === 53397 || owner.port === 8081)
    expect(wildcards.map((owner) => owner.family)).toEqual([4, 6, 6])
  })

  it('drops the header rather than reading NAME as an address', () => {
    expect(owners.some((owner) => owner.process === 'COMMAND')).toBe(false)
  })

  it('leaves de-duplication to the caller', () => {
    // Both rows for 53397 survive. `dev-ports.ts` filters first and de-dupes
    // second, and doing either of those here would change which process gets
    // credited for a port that two of them touch.
    expect(owners.filter((owner) => owner.port === 53397)).toHaveLength(2)
  })

  it('never offers a port bound to a real network address', () => {
    expect(owners.map((owner) => owner.port)).not.toContain(60293)
    expect(owners.map((owner) => owner.port)).not.toContain(60296)
  })
})

describe('reading netstat (Windows, from the documented format)', () => {
  it('finds local listening ports, their PIDs and their loopback family', () => {
    expect(parseNetstat(NETSTAT_OUTPUT)).toEqual([
      { port: 135, pid: 968, family: 4 },
      { port: 445, pid: 4, family: 4 },
      { port: 3000, pid: 12044, family: 4 },
      { port: 135, pid: 968, family: 6 },
      { port: 5199, pid: 7788, family: 6 },
    ])
  })

  it('skips a connection that is merely established', () => {
    // Same port, same PID, and not a listener. Counting it would put an
    // outbound socket on the start page as if it were a dev server.
    const established = parseNetstat(
      '  TCP    127.0.0.1:3000         127.0.0.1:52001        ESTABLISHED     12044',
    )
    expect(established).toEqual([])
  })

  it('skips UDP, which has no state column at all', () => {
    expect(parseNetstat('  UDP    0.0.0.0:5353           *:*                     3120')).toEqual([])
  })

  it('skips a listener bound to the LAN address', () => {
    expect(parseNetstat(NETSTAT_OUTPUT).map((row) => row.port)).not.toContain(139)
  })

  it('works on a Windows that is not in English', () => {
    // The header and the state word are both translated. Recognising rows by
    // shape and listening-ness by the foreign address is what keeps this from
    // returning nothing at all on a German install — a total failure that would
    // look, from here, exactly like a machine with no dev servers running.
    const german = [
      '',
      'Aktive Verbindungen',
      '',
      '  Proto  Lokale Adresse         Remoteadresse          Status          PID',
      '  TCP    127.0.0.1:5173         0.0.0.0:0              ABHÖREN         4242',
      '',
    ].join('\r\n')
    expect(parseNetstat(german)).toEqual([{ port: 5173, pid: 4242, family: 4 }])
  })

  it('keeps IPv6 rows under either label netstat uses for them', () => {
    // `netstat -an` prints v6 rows as `TCP`; `netstat -p` documents `TCPv6` as
    // a family of its own. Which one a given install prints cannot be settled
    // from a Mac, and getting it wrong loses every IPv6-only dev server —
    // `next dev` binding `[::1]` would just not appear on the start page.
    const labelled = [
      '  TCP      [::1]:5173             [::]:0                 LISTENING       4242',
      '  TCPv6    [::1]:5174             [::]:0                 LISTENING       4243',
    ].join('\r\n')
    expect(parseNetstat(labelled)).toEqual([
      { port: 5173, pid: 4242, family: 6 },
      { port: 5174, pid: 4243, family: 6 },
    ])
  })

  it('still refuses a protocol it does not understand', () => {
    expect(parseNetstat('  SCTP   127.0.0.1:5173   0.0.0.0:0   LISTENING   4242')).toEqual([])
  })

  it('reads nothing out of an empty answer', () => {
    expect(parseNetstat('')).toEqual([])
  })
})

describe('reading tasklist', () => {
  it('maps PIDs to names with the .exe taken off', () => {
    const names = parseTasklist(TASKLIST_OUTPUT)
    expect(names.get(12044)).toBe('node')
    expect(names.get(968)).toBe('svchost')
    // No extension to strip on this one, and it must survive intact.
    expect(names.get(4)).toBe('System')
  })

  it('does not split a name or a memory figure on its own comma', () => {
    // `98,304 K` is one field. A naive split on commas shifts every column and
    // turns the PID into "304 K".
    expect(parseTasklist('"Some, App.exe","31","Console","1","1,024 K"').get(31)).toBe('Some, App')
  })

  it('survives an empty answer, which is what a refused tasklist looks like', () => {
    expect(parseTasklist('').size).toBe(0)
  })
})

describe('joining the two Windows calls', () => {
  it('names what it can', () => {
    expect(windowsOwners(parseNetstat(NETSTAT_OUTPUT), parseTasklist(TASKLIST_OUTPUT))).toEqual([
      { port: 135, process: 'svchost', family: 4 },
      { port: 445, process: 'System', family: 4 },
      { port: 3000, process: 'node', family: 4 },
      { port: 135, process: 'svchost', family: 6 },
      { port: 5199, process: null, family: 6 },
    ])
  })

  it('keeps a port whose owner tasklist would not describe', () => {
    // The port is answering either way. Dropping it would hide a dev server
    // behind a protected process or one that exited between the two calls.
    const owners = windowsOwners([{ port: 5173, pid: 9, family: 6 }], new Map())
    expect(owners).toEqual([{ port: 5173, process: null, family: 6 }])
  })
})

describe('which conversation each platform gets', () => {
  it('is netstat plus tasklist on Windows and lsof everywhere else', () => {
    expect(portScanKind('win32')).toBe('netstat+tasklist')
    expect(portScanKind('darwin')).toBe('lsof')
    expect(portScanKind('linux')).toBe('lsof')
  })

  it('spells the commands the way each platform ships them', () => {
    expect(LSOF).toEqual({ command: 'lsof', args: ['-nP', '-iTCP', '-sTCP:LISTEN'] })
    expect(NETSTAT).toEqual({ command: 'netstat.exe', args: ['-ano'] })
    // `-n` is not only about speed: without it netstat resolves names, and a
    // slow reverse DNS lookup turns a 40ms scan into a visible stall.
    expect(NETSTAT.args).toContain('-ano')
    // And no `-p TCP`: netstat documents TCPv6 as a *separate* family, so the
    // selector may drop every IPv6 listener. The parser filters by protocol
    // name instead, which is right whichever way `-p` behaves.
    expect(NETSTAT.args).not.toContain('-p')
    expect(TASKLIST).toEqual({ command: 'tasklist.exe', args: ['/FO', 'CSV', '/NH'] })
  })
})
