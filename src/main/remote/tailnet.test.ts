import { describe, expect, it, vi } from 'vitest'
import {
  BLOCKED_REASONS,
  ensureCert,
  isTailnetAddress,
  isTailnetAddress6,
  parseTailnetStatus,
  tailnetStatus,
  toCertResult,
  toTailnetStatus,
  type CommandResult,
} from './tailnet'

/**
 * The one impure test in this file needs to count process spawns, so
 * `execFile` is replaced wholesale. `promisify` prefers a function's custom
 * promisified form, so the mock carries one — without it `promisify` wraps the
 * mock callback-style and resolves with stdout alone, and every `{ stdout,
 * stderr }` destructure in the module under test throws.
 */
const spawns = vi.hoisted(() => ({ status: 0 }))

vi.mock('node:child_process', () => {
  const execFile = ((): unknown => undefined) as unknown as Record<symbol, unknown>
  execFile[Symbol.for('nodejs.util.promisify.custom')] = async (
    file: string,
    args: string[],
  ): Promise<{ stdout: string; stderr: string }> => {
    // `which tailscale`, answered with a path that is executable everywhere
    // POSIX, so the lookup does not depend on this machine having Tailscale.
    if (file === 'which') return { stdout: '/bin/sh\n', stderr: '' }
    if (args?.[0] === 'status') {
      spawns.status += 1
      return { stdout: RUNNING, stderr: VERSION_WARNING }
    }
    return { stdout: '', stderr: '' }
  }
  return { execFile }
})

/**
 * ## Where these fixtures came from
 *
 * `RUNNING` is a real `tailscale status --json` capture from this machine
 * (client 1.94.2, tailscaled 1.98.9), trimmed to one peer and with the identity
 * fields replaced — the live output carries an account email, a home public IP
 * and node keys, none of which belong in a repo. Everything this module reads is
 * verbatim, including the parts that look like mistakes and are not: the
 * trailing dot on `Self.DNSName`, `CertDomains: null` on a tailnet with HTTPS
 * certificates switched off, the IPv6 address sharing `TailscaleIPs`, and a peer
 * whose suffix is *not* this tailnet's because it is shared in from another one.
 *
 * `LOGGED_OUT` and `STOPPED` are that same capture edited into those states,
 * because producing them for real means running `tailscale logout` or
 * `tailscale down` on a live tailnet other machines depend on. Their shapes
 * follow tailscaled's own behaviour: it keeps the last network map, so a stopped
 * node still reports a full `Self` with addresses. That is exactly the trap this
 * module exists to avoid, and it is the case tested hardest below.
 *
 * The stderr strings are real and were captured on this machine — including the
 * version-skew warning that rides along on every healthy call.
 */

const VERSION_WARNING =
  'Warning: client version "1.94.2-t2de4d317a" != tailscaled server version "1.98.9-t4fb758c39-g200941d74"\n'

const BIN = '/opt/homebrew/bin/tailscale'

const RUNNING = `{
  "Version": "1.98.9-t4fb758c39-g200941d74",
  "TUN": true,
  "BackendState": "Running",
  "HaveNodeKey": true,
  "AuthURL": "",
  "TailscaleIPs": [
    "100.86.107.119",
    "fd7a:115c:a1e0::fd39:6b77"
  ],
  "Self": {
    "ID": "nSr1hSiyP811CNTRL",
    "HostName": "deck-mac",
    "DNSName": "deck-mac.taild0abcd.ts.net.",
    "OS": "macOS",
    "TailscaleIPs": [
      "100.86.107.119",
      "fd7a:115c:a1e0::fd39:6b77"
    ],
    "Online": true,
    "InNetworkMap": true
  },
  "Health": [],
  "MagicDNSSuffix": "taild0abcd.ts.net",
  "CurrentTailnet": {
    "Name": "owner@example.com",
    "MagicDNSSuffix": "taild0abcd.ts.net",
    "MagicDNSEnabled": true
  },
  "CertDomains": null,
  "Peer": {
    "nodekey:3748e97a0046c25ed481dc7930e44abd9a450ada4e78fb859bfbb641ada56d11": {
      "ID": "nL3GN8Ypuc11CNTRL",
      "HostName": "DESKTOP-DDGMNCV",
      "DNSName": "desktop-ddgmncv.taile59277.ts.net.",
      "OS": "windows",
      "TailscaleIPs": [
        "100.101.109.17",
        "fd7a:115c:a1e0::ad37:6d12"
      ],
      "Online": true,
      "Active": true
    }
  }
}
`

/** `tailscale down`: signed in, switched off, still holding the last netmap. */
const STOPPED = RUNNING.replace('"BackendState": "Running"', '"BackendState": "Stopped"')

/** Logged out: no identity, so tailscaled has no map and no addresses to report. */
const LOGGED_OUT = `{
  "Version": "1.98.9-t4fb758c39-g200941d74",
  "TUN": true,
  "BackendState": "NeedsLogin",
  "HaveNodeKey": false,
  "AuthURL": "",
  "TailscaleIPs": null,
  "Self": null,
  "Health": [],
  "MagicDNSSuffix": "",
  "CurrentTailnet": null,
  "CertDomains": null,
  "Peer": null
}
`

function ran(stdout: string, stderr = VERSION_WARNING, code = 0): CommandResult {
  return { stdout, stderr, code }
}

describe('reading tailscale status', () => {
  it('reports the address to point a phone at', () => {
    expect(toTailnetStatus(ran(RUNNING), BIN)).toEqual({
      ready: true,
      address: '100.86.107.119',
      address6: 'fd7a:115c:a1e0::fd39:6b77',
      dnsName: 'deck-mac.taild0abcd.ts.net',
      hostName: 'deck-mac',
      tailnetName: 'owner@example.com',
      magicDnsSuffix: 'taild0abcd.ts.net',
      magicDns: true,
      certsAvailable: false,
      binary: BIN,
    })
  })

  it('strips the trailing dot the CLI puts on DNSName', () => {
    // Left on, the name still resolves and then fails certificate matching,
    // which is the confusing half of the bug rather than the loud half.
    const status = toTailnetStatus(ran(RUNNING), BIN)
    expect(status.ready && status.dnsName.endsWith('.')).toBe(false)
  })

  it('takes the name from this node, not from a peer on another tailnet', () => {
    // The one peer in this fixture is shared in and carries taile59277.ts.net.
    // Assembling HostName + "a suffix seen in the output" gets this wrong.
    const status = toTailnetStatus(ran(RUNNING), BIN)
    expect(status.ready && status.dnsName).toBe('deck-mac.taild0abcd.ts.net')
    expect(JSON.stringify(status)).not.toContain('taile59277')
  })

  it('picks the tailnet IPv4 out of a list that also holds IPv6', () => {
    const v6First = RUNNING.replace(
      '"100.86.107.119",\n      "fd7a:115c:a1e0::fd39:6b77"',
      '"fd7a:115c:a1e0::fd39:6b77",\n      "100.86.107.119"',
    )
    const status = toTailnetStatus(ran(v6First), BIN)
    expect(status.ready && status.address).toBe('100.86.107.119')
  })

  it('will not bind to an address outside the tailnet range', () => {
    // The security claim in one assertion: a LAN or public address in that list
    // is not a tailnet address, whatever position it is in.
    expect(isTailnetAddress('100.86.107.119')).toBe(true)
    expect(isTailnetAddress('100.64.0.1')).toBe(true)
    expect(isTailnetAddress('100.127.255.254')).toBe(true)
    expect(isTailnetAddress('192.168.1.5')).toBe(false)
    expect(isTailnetAddress('100.128.0.1')).toBe(false)
    expect(isTailnetAddress('100.63.255.255')).toBe(false)
    expect(isTailnetAddress('10.0.0.1')).toBe(false)

    const lanFirst = RUNNING.replace('"100.86.107.119",', '"192.168.1.5",\n    "100.86.107.119",')
    const status = toTailnetStatus(ran(lanFirst), BIN)
    expect(status.ready && status.address).toBe('100.86.107.119')
  })

  it('rejects addresses that only look numeric to Number()', () => {
    // `Number('')` is 0, `Number('0x1')` is 1, `Number('1e2')` is 100, and
    // `Number(' 1')` is 1. A split-and-Number check calls every one of these a
    // tailnet address; none of them is an address at all. It matters because
    // `server.listen(port, host)` resolves a non-address host as a *name*, so a
    // string that passed the CGNAT check can still send the listener elsewhere.
    expect(isTailnetAddress('100.64.0.')).toBe(false)
    expect(isTailnetAddress('100.64.0.0x1')).toBe(false)
    expect(isTailnetAddress('100.64.0.1e2')).toBe(false)
    expect(isTailnetAddress('100.64.0. 1')).toBe(false)
    expect(isTailnetAddress('100.64.0.1\n')).toBe(false)
    expect(isTailnetAddress('100.064.0.1')).toBe(false)
    expect(isTailnetAddress('')).toBe(false)
    // Still an address when it is one.
    expect(isTailnetAddress('100.64.0.1')).toBe(true)
  })

  it('holds the IPv6 address to the same rule as the IPv4 one', () => {
    // fd7a:115c:a1e0::/48 is what Tailscale hands out. Anything else in that
    // list is not a tailnet address, and `server.ts` opens a second listener on
    // whatever this field says.
    expect(isTailnetAddress6('fd7a:115c:a1e0::fd39:6b77')).toBe(true)
    expect(isTailnetAddress6('FD7A:115C:A1E0:0:0:0:FD39:6B77')).toBe(true)
    expect(isTailnetAddress6('2a01:4f8:c17:beef::1')).toBe(false)
    expect(isTailnetAddress6('fd7a:115c:a1e1::1')).toBe(false)
    expect(isTailnetAddress6('::1')).toBe(false)
    expect(isTailnetAddress6('fd00::1')).toBe(false)
    expect(isTailnetAddress6('not-an-address')).toBe(false)
  })

  it('will not hand back a globally routable IPv6 to bind to', () => {
    // A `.includes(':')` test accepts this, and the second listener is then a
    // terminal on a public address — the one thing this module exists to stop.
    // Both copies: the address appears at the top level and again under Self,
    // and the parser reads Self.
    const routable = RUNNING.replaceAll('"fd7a:115c:a1e0::fd39:6b77"', '"2a01:4f8:c17:beef::1"')
    const status = toTailnetStatus(ran(routable), BIN)
    expect(status.ready && status.address).toBe('100.86.107.119')
    expect(status.ready && status.address6).toBeNull()
    expect(JSON.stringify(status)).not.toContain('2a01')
  })

  it('knows the tailnet has no certificates before anything is requested', () => {
    // CertDomains: null is this tailnet's real answer with HTTPS off.
    const off = toTailnetStatus(ran(RUNNING), BIN)
    const on = toTailnetStatus(
      ran(RUNNING.replace('"CertDomains": null', '"CertDomains": ["deck-mac.taild0abcd.ts.net"]')),
      BIN,
    )
    expect(off.ready && off.certsAvailable).toBe(false)
    expect(on.ready && on.certsAvailable).toBe(true)
  })

  it('does not offer a MagicDNS name the tailnet will not resolve', () => {
    const noMagic = RUNNING.replace('"MagicDNSEnabled": true', '"MagicDNSEnabled": false')
    const status = toTailnetStatus(ran(noMagic), BIN)
    // Still serveable on the IP — just never as a secure context.
    expect(status).toMatchObject({ ready: true, address: '100.86.107.119', dnsName: '', magicDns: false })
  })

  it('parses a decoded payload directly, for callers that already have one', () => {
    const status = parseTailnetStatus(JSON.parse(RUNNING), BIN)
    expect(status.ready && status.hostName).toBe('deck-mac')
  })
})

describe('the states where serving will not work', () => {
  it('does not call a stopped node ready just because it still has an address', () => {
    // The whole reason BackendState is read before the address list.
    const status = toTailnetStatus(ran(STOPPED), BIN)
    expect(status.ready).toBe(false)
    expect(status).toMatchObject({ state: 'stopped' })
    expect(JSON.stringify(status)).not.toContain('100.86.107.119')
  })

  it('reports being signed out', () => {
    expect(toTailnetStatus(ran(LOGGED_OUT), BIN)).toMatchObject({ ready: false, state: 'logged-out' })
  })

  it('reports a node still waiting for tailnet approval', () => {
    const pending = LOGGED_OUT.replace('"NeedsLogin"', '"NeedsMachineAuth"')
    expect(toTailnetStatus(ran(pending), BIN)).toMatchObject({ state: 'needs-approval' })
  })

  it('reports the daemon being unreachable in its own words', () => {
    // Captured by pointing the CLI at a socket that is not there: exit 1,
    // nothing on stdout, one sentence on stderr.
    expect(
      toTailnetStatus({
        stdout: '',
        stderr: 'failed to connect to local Tailscale service; is Tailscale running?\n',
        code: 1,
      }),
    ).toMatchObject({
      ready: false,
      state: 'not-running',
      detail: 'failed to connect to local Tailscale service; is Tailscale running?',
    })
  })

  it('reports a missing binary rather than an empty answer', () => {
    expect(toTailnetStatus({ stdout: '', stderr: '', code: -1, spawnError: 'ENOENT' })).toMatchObject({
      state: 'not-installed',
    })
  })

  it('names an unfamiliar backend state instead of assuming it is fine', () => {
    // A newer Tailscale than this code is not a healthy one by default.
    expect(toTailnetStatus(ran(RUNNING.replace('"Running"', '"SomethingNew"')), BIN)).toMatchObject({
      state: 'unreadable',
      detail: 'Tailscale reported backend state SomethingNew.',
    })
  })

  it('survives output that is not JSON at all', () => {
    expect(toTailnetStatus(ran('tailscale: unknown flag --json', '', 1))).toMatchObject({ state: 'unreadable' })
  })

  it('says so when a running node has no tailnet address yet', () => {
    const noAddress = RUNNING.replace(/"TailscaleIPs": \[[^\]]*\]/g, '"TailscaleIPs": []')
    expect(toTailnetStatus(ran(noAddress), BIN)).toMatchObject({ state: 'no-address' })
  })

  it('does not put the login URL on screen when the JSON does not parse', () => {
    // AuthURL is the fifth key of the real output, ~130 bytes in, so it lands
    // inside the 200-character slice the unreadable branch shows. It is empty
    // on a healthy node and a live capability URL when the node needs login:
    // whoever opens it can join a device to this tailnet. The way to reach this
    // branch with a real prefix is truncation at maxBuffer, which is exactly
    // the case that leaves the URL in and the closing brace out.
    const truncated =
      '{\n  "Version": "1.98.9",\n  "TUN": true,\n  "BackendState": "NeedsLogin",\n  "HaveNodeKey": false,\n' +
      '  "AuthURL": "https://login.tailscale.com/a/6f21c9d4e8b7",\n  "TailscaleIPs": null,\n  "Self": {'
    const status = toTailnetStatus(ran(truncated, '', 1))
    expect(status).toMatchObject({ ready: false, state: 'unreadable' })
    expect(JSON.stringify(status)).not.toContain('6f21c9d4e8b7')
    expect(status.ready === false && status.detail).toContain('[redacted]')
  })

  it('keeps the version-skew warning off screen once the JSON parsed', () => {
    // stderr carries that warning on every healthy call. Showing it as the
    // detail under "you are signed out" invents a cause.
    expect(toTailnetStatus(ran(STOPPED), BIN)).not.toHaveProperty('detail')
  })
})

describe('every not-ready reason is a sentence someone can act on', () => {
  it.each(Object.entries(BLOCKED_REASONS))('%s', (state, reason) => {
    expect(reason, `${state} ends as a sentence`).toMatch(/\.$/)
    expect(reason.length, `${state} says more than a label`).toBeGreaterThan(60)
    // A diagnosis is not an instruction. Each one ends in something to do.
    expect(reason, `${state} names a next step`).toMatch(/install |open |click |approve |give it |run `|switch it off/i)
    // And where to do it: "open Tailscale" is three different places depending
    // on how it was installed.
    expect(reason, `${state} names where`).toMatch(/menu bar|Applications|https:\/\/|terminal/)
  })

  it('reaches every reason through the parser, so none is written but unreachable', () => {
    const reached = new Set(
      [
        toTailnetStatus({ stdout: '', stderr: '', code: -1, spawnError: 'ENOENT' }),
        toTailnetStatus({ stdout: '', stderr: 'failed to connect', code: 1 }),
        toTailnetStatus(ran(LOGGED_OUT)),
        toTailnetStatus(ran(STOPPED)),
        toTailnetStatus(ran(LOGGED_OUT.replace('"NeedsLogin"', '"NeedsMachineAuth"'))),
        toTailnetStatus(ran(LOGGED_OUT.replace('"NeedsLogin"', '"Starting"'))),
        toTailnetStatus(ran(RUNNING.replace(/"TailscaleIPs": \[[^\]]*\]/g, '"TailscaleIPs": []'))),
        toTailnetStatus(ran('not json', '', 1)),
      ].map((status) => (status.ready ? 'ready' : status.state)),
    )
    expect([...reached].sort()).toEqual(Object.keys(BLOCKED_REASONS).sort())
  })
})

describe('asking the daemon no more often than necessary', () => {
  // Deleting the cache and the in-flight sharing entirely left every other test
  // in this file passing, so the behaviour the module documents at length was
  // asserted nowhere. It is worth a spawn count: a status call wakes a daemon,
  // and the remote panel and its QR code ask at the same moment.
  it('answers concurrent callers with one process, then from cache', async () => {
    const before = spawns.status
    const [a, b] = await Promise.all([tailnetStatus(), tailnetStatus()])
    expect(spawns.status - before, 'two concurrent callers share one spawn').toBe(1)
    expect(a).toEqual(b)
    expect(a.ready && a.address).toBe('100.86.107.119')

    await tailnetStatus()
    expect(spawns.status - before, 'a third call inside the window is cached').toBe(1)

    // The Refresh button has to actually refresh, or the panel argues with the
    // menu bar for three seconds after someone clicks Connect.
    await tailnetStatus(true)
    expect(spawns.status - before, 'force bypasses the cache').toBe(2)
  })
})

describe('getting a certificate for the MagicDNS name', () => {
  const NAME = 'deck-mac.taild0abcd.ts.net'
  const CERT = '/tmp/certs/deck-mac.taild0abcd.ts.net.crt'
  const KEY = '/tmp/certs/deck-mac.taild0abcd.ts.net.key'

  it('hands back the paths it was told to write', () => {
    expect(toCertResult(NAME, CERT, KEY, ran('', VERSION_WARNING, 0))).toEqual({
      ok: true,
      certPath: CERT,
      keyPath: KEY,
    })
  })

  it('turns the CLI’s 500 into the admin toggle that causes it', () => {
    // Real output from this machine, whose tailnet has HTTPS certificates off:
    // exit 1 and a bare 500, which tells nobody this is a setting they own.
    const result = toCertResult(NAME, CERT, KEY, {
      stdout: '',
      stderr: `${VERSION_WARNING}500 Internal Server Error: your Tailscale account does not support getting TLS certs\n`,
      code: 1,
    })
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.reason).toBe('https-disabled')
    expect(result.message).toContain('https://login.tailscale.com/admin/dns')
    expect(result.message).toContain('HTTPS Certificates')
    expect(result.message).toContain(NAME)
    // The machine's own words stay available underneath ours.
    expect(result.detail).toContain('does not support getting TLS certs')
  })

  it('recognises the older wording for the same switch', () => {
    const result = toCertResult(NAME, CERT, KEY, { stdout: '', stderr: 'HTTPS must be enabled\n', code: 1 })
    expect(result.ok === false && result.reason).toBe('https-disabled')
  })

  it('does not blame the tailnet setting when the daemon is down', () => {
    const result = toCertResult(NAME, CERT, KEY, {
      stdout: '',
      stderr: 'failed to connect to local Tailscale service; is Tailscale running?\n',
      code: 1,
    })
    expect(result.ok === false && result.reason).toBe('not-running')
  })

  it('says a timeout was a timeout', () => {
    const result = toCertResult(NAME, CERT, KEY, { stdout: '', stderr: '', code: -1 })
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.message).toContain('within two minutes')
  })

  it('keeps an unfamiliar failure readable instead of swallowing it', () => {
    const result = toCertResult(NAME, CERT, KEY, {
      stdout: '',
      stderr: 'acme: rate limit exceeded for deck-mac.taild0abcd.ts.net\n',
      code: 1,
    })
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.reason).toBe('failed')
    expect(result.detail).toContain('rate limit exceeded')
    expect(result.message).toContain('tailscale cert deck-mac.taild0abcd.ts.net')
  })

  it('reports a missing binary as a missing binary', () => {
    const result = toCertResult(NAME, CERT, KEY, { stdout: '', stderr: '', code: -1, spawnError: 'ENOENT' })
    expect(result.ok === false && result.reason).toBe('not-installed')
  })

  it('every certificate failure is also a sentence someone can act on', () => {
    const failures = [
      toCertResult(NAME, CERT, KEY, { stdout: '', stderr: 'does not support getting TLS certs', code: 1 }),
      toCertResult(NAME, CERT, KEY, { stdout: '', stderr: 'failed to connect', code: 1 }),
      toCertResult(NAME, CERT, KEY, { stdout: '', stderr: '', code: -1 }),
      toCertResult(NAME, CERT, KEY, { stdout: '', stderr: 'something else', code: 1 }),
      toCertResult(NAME, CERT, KEY, { stdout: '', stderr: '', code: -1, spawnError: 'ENOENT' }),
    ]
    for (const failure of failures) {
      expect(failure.ok).toBe(false)
      if (failure.ok) continue
      expect(failure.message).toMatch(/\.$/)
      expect(failure.message.length).toBeGreaterThan(60)
      expect(failure.message).toMatch(/try again|Install /)
    }
  })

  it('refuses a name that would write the private key somewhere else', async () => {
    // execFile takes no shell, so the hazard is not injection — it is that the
    // name is spliced into two file paths.
    const result = await ensureCert('../../../../tmp/evil', '/tmp/certs')
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.reason).toBe('bad-name')
    expect(result.message).toContain('.ts.net')
  })

  it('refuses an empty name, which is what a missing MagicDNS name looks like', async () => {
    const result = await ensureCert('', '/tmp/certs')
    expect(result.ok === false && result.reason).toBe('bad-name')
  })
})
