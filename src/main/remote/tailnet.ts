/**
 * Where the remote server is allowed to listen, and whether it can listen now.
 *
 * ## The one-sentence security model
 *
 * The socket exists only on the tailnet. Not `0.0.0.0`, not the LAN address — a
 * coffee-shop network would otherwise get a terminal on this machine. So the
 * address is not configurable and is never guessed: it is read from the running
 * Tailscale daemon, it must be inside `100.64.0.0/10`, and when the daemon
 * cannot answer, nothing starts.
 *
 * ## Why the DNS name matters more than the IP
 *
 * A phone can reach `http://100.86.107.119:port` the moment both devices are on
 * the tailnet, and that address is useless for anything past a plain page: a
 * bare IP over http is never a *secure context*, so no service worker, no
 * clipboard, no camera, no notifications, no install-to-home-screen. The
 * MagicDNS name with a real Let's Encrypt certificate is the same machine at a
 * name browsers will trust, and `ensureCert` is what turns that on.
 *
 * ## What was checked against the real CLI on this machine
 *
 * `tailscale` 1.94.2 talking to `tailscaled` 1.98.9. The shapes below are
 * transcribed from real output rather than from the docs:
 *
 *   BackendState    "Running"
 *   TailscaleIPs    ["100.86.107.119", "fd7a:115c:a1e0::fd39:6b77"]
 *   Self.DNSName    "asads-macbook-pro-1.taild11505.ts.net."   ← trailing dot
 *   MagicDNSSuffix  "taild11505.ts.net"
 *   CertDomains     null                                       ← HTTPS is off
 *
 * Five of those details are load-bearing:
 *
 *  - `status --json` writes clean JSON to **stdout** and the client/server
 *    version-skew warning to **stderr**. Parsing the two streams together — the
 *    habit of every other probe in this codebase — produces invalid JSON on a
 *    perfectly healthy machine, and treating a non-empty stderr as failure
 *    refuses to start on one.
 *  - `Self.DNSName` is fully qualified with a **trailing dot**. That is not a
 *    valid URL host and not what a certificate is issued for, so it is stripped
 *    once here rather than at every call site.
 *  - The suffix in a peer row is **not** this tailnet's suffix. One peer here is
 *    shared in from another tailnet and reports `…taile59277.ts.net.` while this
 *    node is on `taild11505.ts.net`. The name therefore comes from `Self.DNSName`
 *    only, never assembled from `HostName` plus a suffix seen elsewhere.
 *  - With the daemon unreachable (`--socket` pointed at nothing): exit 1, empty
 *    stdout, stderr `failed to connect to local Tailscale service; is Tailscale
 *    running?`. No JSON at all, so "no JSON" has to be an answer rather than a
 *    parse crash.
 *  - `CertDomains: null` is this tailnet's real answer with HTTPS certificates
 *    off in the admin console. It is the difference between "this will work" and
 *    "this fails at cert time", visible before anything is requested.
 *
 * ## Why the backend state is read before the address
 *
 * The address list survives the switch being off; reachability does not. A
 * backend that is `Stopped` or `NeedsLogin` can still report a full `Self` with
 * IPs, because tailscaled keeps the last network map. Deciding "ready" from the
 * presence of an address would hand out a reachable-looking address for a
 * machine that is not on the network — the one wrong answer this module must
 * never give, since its whole job is telling someone where to point a phone.
 */

import { execFile } from 'node:child_process'
import { accessSync, chmodSync, constants, mkdirSync } from 'node:fs'
import { BlockList, isIPv4, isIPv6 } from 'node:net'
import { join } from 'node:path'
import { promisify } from 'node:util'
import type { IpcMain } from 'electron'
import { loginPath } from '../providers'

const run = promisify(execFile)

/** Serving is possible: this is the machine's address on the tailnet. */
export interface TailnetReady {
  ready: true
  /** Tailnet IPv4 in 100.64.0.0/10. What the server binds to, and never a secure context. */
  address: string
  /** Tailnet IPv6, when the node has one. Bound as well when present. */
  address6: string | null
  /** MagicDNS name without the trailing dot, or '' when MagicDNS is off. */
  dnsName: string
  /** Short node name, e.g. `asads-macbook-pro-1`. */
  hostName: string
  /** The tailnet's own name — an email for a personal tailnet, a domain for an org. */
  tailnetName: string
  /** e.g. `taild11505.ts.net`. */
  magicDnsSuffix: string
  /**
   * False when the MagicDNS name will not resolve. Serving still works on `ip`,
   * so this is a flag rather than a refusal — but there is then no name to put a
   * certificate on, and the phone stays outside a secure context.
   */
  magicDns: boolean
  /** True once the tailnet has HTTPS certificates enabled; see `ensureCert`. */
  certsAvailable: boolean
  /** Absolute path of the CLI that answered, for whoever needs to run it next. */
  binary: string
}

/** Every way this can be unavailable, each with a different thing to do about it. */
export type TailnetBlockedState =
  | 'not-installed'
  | 'not-running'
  | 'logged-out'
  | 'stopped'
  | 'needs-approval'
  | 'starting'
  | 'no-address'
  | 'unreadable'

export interface TailnetNotReady {
  ready: false
  /** Machine-readable, for callers that branch. */
  state: TailnetBlockedState
  /** One sentence, written to be shown to a person, not logged. Rendered verbatim. */
  reason: string
  /** What the CLI itself said, when it said anything worth repeating. */
  detail?: string
}

export type TailnetStatus = TailnetReady | TailnetNotReady

/**
 * The user-facing half of this module.
 *
 * Kept in one table rather than inline at each branch so "every reason is
 * actionable" is a property a test can check across all of them at once, and so
 * a new state cannot be added with an apology in place of an instruction. Each
 * names where to click, because "Tailscale is not running" on its own sends
 * people to a search engine, and because Tailscale installs three different ways
 * on macOS — the menu bar is the only place all three agree on.
 */
export const BLOCKED_REASONS: Record<TailnetBlockedState, string> = {
  'not-installed':
    'Tailscale is not installed on this Mac. Your phone connects over the tailnet, so there is no address to listen on without it — install it from https://tailscale.com/download, sign in, then try again.',
  'not-running':
    'Tailscale is installed but its background service is not answering. Open Tailscale from your Applications folder to start it, then try again.',
  'logged-out':
    'Tailscale is installed but signed out on this Mac. Click the Tailscale icon in the menu bar, choose Log in, then try again.',
  stopped:
    'Tailscale is signed in but switched off on this Mac. Click the Tailscale icon in the menu bar, choose Connect, then try again.',
  'needs-approval':
    'This Mac is signed in but still waiting to join the tailnet. Approve it at https://login.tailscale.com/admin/machines, then try again.',
  starting:
    'Tailscale is still starting up on this Mac. Give it a few seconds, watch the Tailscale icon in the menu bar, then try again.',
  'no-address':
    'Tailscale is running but has not given this Mac a tailnet address yet. Click the Tailscale icon in the menu bar, switch it off and on again, then try again.',
  unreadable:
    'Could not read Tailscale’s status on this Mac. Run `tailscale status` in a terminal to see what it says, then try again.',
}

function notReady(state: TailnetBlockedState, detail?: string): TailnetNotReady {
  const trimmed = detail?.trim()
  const base: TailnetNotReady = { ready: false, state, reason: BLOCKED_REASONS[state] }
  return trimmed ? { ...base, detail: trimmed } : base
}

/** What a finished `tailscale` run leaves behind, however it ended. */
export interface CommandResult {
  stdout: string
  stderr: string
  /** Exit status, or -1 when the process was killed or never ran. */
  code: number
  /** Set when the binary could not be spawned at all, e.g. 'ENOENT'. */
  spawnError?: string
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * 100.64.0.0/10, the CGNAT range Tailscale hands out.
 *
 * Checked rather than assumed because this value decides what the server binds
 * to. "The first IPv4 in the list" would happily return a LAN address if the
 * shape of the output ever changed, and binding a terminal to the LAN is the
 * failure this whole module is arranged to prevent.
 */
export function isTailnetAddress(value: string): boolean {
  // `isIPv4` before the range check, because `Number()` is not a parser: it
  // reads '' as 0, '0x1' as 1 and '1e2' as 100, so a hand-rolled split accepts
  // '100.64.0.', '100.64.0.0x1' and '100.64.0.1e2' as tailnet addresses. None
  // of those is an address, and `server.listen` treats a non-address host as a
  // *name* to resolve — which is how a value that passed a CGNAT check ends up
  // binding somewhere no part of this module intended.
  if (!isIPv4(value)) return false
  const octets = value.split('.').map(Number)
  return octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127
}

/**
 * `fd7a:115c:a1e0::/48`, the ULA prefix Tailscale hands out.
 *
 * The IPv4 side of this module is careful and the IPv6 side used to be a
 * `.includes(':')` test, which is not a check at all: any global address in
 * `TailscaleIPs` became `address6`, and `server.ts` opens a second listener on
 * it — a terminal on a publicly routable address, the exact outcome the header
 * comment promises cannot happen. `BlockList` rather than a regex because a v6
 * address has many spellings (`FD7A:115C:A1E0:0:0:0:FD39:6B77` is inside this
 * prefix and matches no obvious pattern) and getting that wrong fails open.
 */
const TAILNET_V6 = new BlockList()
TAILNET_V6.addSubnet('fd7a:115c:a1e0::', 48, 'ipv6')

export function isTailnetAddress6(value: string): boolean {
  // `isIPv6` first for the same reason as the v4 path, and because it rejects a
  // zone id (`fe80::1%en0`) — a scoped link-local address is not a tailnet
  // address, and `check` would not be asked to decide that.
  return isIPv6(value) && TAILNET_V6.check(value, 'ipv6')
}

/**
 * `ipn.State` as tailscaled reports it, mapped to what a person has to do.
 * `NoState` is the daemon before it has decided anything, which reads to a user
 * exactly like starting up.
 */
const BACKEND_STATES: Record<string, TailnetBlockedState | 'ready'> = {
  Running: 'ready',
  NeedsLogin: 'logged-out',
  NeedsMachineAuth: 'needs-approval',
  Stopped: 'stopped',
  Starting: 'starting',
  NoState: 'starting',
}

/**
 * Turn the daemon's decoded JSON into an answer.
 *
 * Separate from the process spawn so the interesting cases — logged out, daemon
 * stopped, a node with no IPv4 — are testable without a tailnet, which matters
 * because producing them for real means taking down a tailnet other machines
 * depend on.
 */
export function parseTailnetStatus(raw: unknown, binary: string): TailnetStatus {
  if (!isRecord(raw)) return notReady('unreadable', 'Tailscale returned something that was not status JSON.')

  const backend = typeof raw.BackendState === 'string' ? raw.BackendState : ''
  const mapped = BACKEND_STATES[backend]
  // An unrecognised state is a newer Tailscale than this code, not a healthy
  // one: report it rather than guessing that unknown means running.
  if (mapped === undefined) return notReady('unreadable', `Tailscale reported backend state ${backend || '(none)'}.`)
  // No detail from here down: once the JSON parsed, stderr holds the
  // version-skew warning, which has nothing to do with being logged out and
  // would read on screen as the cause.
  if (mapped !== 'ready') return notReady(mapped)

  const self = isRecord(raw.Self) ? raw.Self : null
  const selfIps = Array.isArray(self?.TailscaleIPs) ? self.TailscaleIPs : raw.TailscaleIPs
  const ips = Array.isArray(selfIps) ? selfIps.filter((ip): ip is string => typeof ip === 'string') : []

  const address = ips.find((candidate) => isTailnetAddress(candidate))
  if (address === undefined) return notReady('no-address')

  // Trailing dot: fully qualified in DNS terms, a certificate mismatch in
  // browser terms. Stripped once, here.
  const fqdn = typeof self?.DNSName === 'string' ? self.DNSName : ''
  const dnsName = fqdn.replace(/\.$/, '')
  const tailnet = isRecord(raw.CurrentTailnet) ? raw.CurrentTailnet : null
  const magicDns = dnsName !== '' && tailnet?.MagicDNSEnabled !== false

  const magicDnsSuffix =
    typeof raw.MagicDNSSuffix === 'string' && raw.MagicDNSSuffix !== ''
      ? raw.MagicDNSSuffix
      : typeof tailnet?.MagicDNSSuffix === 'string'
        ? tailnet.MagicDNSSuffix
        : ''

  return {
    ready: true,
    address,
    // Same rule as the v4 address, not a looser one: null when the node has no
    // tailnet v6, which costs a v6-preferring phone one Happy Eyeballs fallback
    // and never binds a listener outside the tailnet.
    address6: ips.find((candidate) => isTailnetAddress6(candidate)) ?? null,
    // Empty when MagicDNS is off: a name that does not resolve is worse on
    // screen than no name, because the failure lands on the phone instead.
    dnsName: magicDns ? dnsName : '',
    hostName: typeof self?.HostName === 'string' ? self.HostName : dnsName.split('.')[0],
    tailnetName: typeof tailnet?.Name === 'string' ? tailnet.Name : magicDnsSuffix,
    magicDnsSuffix,
    magicDns,
    // Populated only once HTTPS certificates are enabled for the tailnet, so the
    // cert story can be answered honestly before anything is requested.
    certsAvailable: Array.isArray(raw.CertDomains) && raw.CertDomains.length > 0,
    binary,
  }
}

/**
 * Turn a finished `status --json` run into an answer, including the ways it can
 * fail before there is any JSON to read.
 */
export function toTailnetStatus(result: CommandResult, binary = ''): TailnetStatus {
  if (result.spawnError === 'ENOENT') return notReady('not-installed')

  const text = result.stdout.trim()
  if (text === '') {
    // The daemon-unreachable case: exit 1, nothing on stdout, one sentence on
    // stderr. Its own words become the detail; ours name the fix.
    const said = result.stderr.toLowerCase()
    const noDaemon = said.includes('failed to connect') || said.includes('is tailscale running')
    return notReady(noDaemon ? 'not-running' : 'unreadable', result.stderr)
  }

  try {
    return parseTailnetStatus(JSON.parse(text), binary)
  } catch {
    return notReady('unreadable', result.stderr || redactSecrets(text.slice(0, 200)))
  }
}

/**
 * Keep the login URL out of a message that gets shown and logged.
 *
 * `AuthURL` is the fifth key of `status --json`, roughly 130 bytes in — well
 * inside the 200-character slice above. It is empty on a healthy node and a
 * live capability URL when the node needs login: anyone who opens it can join a
 * device to this tailnet. That slice is only reached when the JSON did not
 * parse, which includes the case that produces it — output truncated at
 * `maxBuffer`, leaving a valid-looking prefix that contains the URL and nothing
 * that closes it.
 */
function redactSecrets(text: string): string {
  return text
    .replace(/("AuthURL"\s*:\s*")[^"]+/g, '$1[redacted]')
    .replace(/https:\/\/login\.tailscale\.com\/\S+/g, 'https://login.tailscale.com/[redacted]')
}

/**
 * Where the CLI lives.
 *
 * Homebrew on Apple silicon is one of four real answers, and a GUI app on macOS
 * inherits a PATH with none of them in it — `providers.ts` documents that lesson
 * first-hand. So the login shell is asked first, because it is the only source
 * that knows about a non-standard install, and the fixed list is a fallback
 * rather than the answer. `/usr/local/bin` is Homebrew on Intel; the App Store
 * build ships its CLI inside the bundle and puts nothing on PATH at all, which
 * is why the third entry looks like that.
 *
 * Executability, not existence: the App Store path is a real file for users who
 * have the app but have never opened it, and a non-executable hit there would
 * shadow a working binary further down the list.
 */
const BINARIES = [
  '/opt/homebrew/bin/tailscale',
  '/usr/local/bin/tailscale',
  '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
  '/usr/bin/tailscale',
]

function executable(path: string): boolean {
  try {
    accessSync(path, constants.X_OK)
    return true
  } catch {
    return false
  }
}

let cachedBin: string | null | undefined

export async function findTailscale(force = false): Promise<string | null> {
  if (!force && cachedBin !== undefined) return cachedBin

  try {
    const PATH = await loginPath()
    const { stdout } = await run('which', ['tailscale'], { env: { ...process.env, PATH }, timeout: 5000 })
    const found = stdout.trim().split('\n')[0]?.trim()
    if (found && executable(found)) {
      cachedBin = found
      return cachedBin
    }
  } catch {
    /* Not on the login PATH. The fixed list below is the whole point. */
  }

  cachedBin = BINARIES.find(executable) ?? null
  return cachedBin
}

/** `tailscale status` is a local socket round-trip; it should never take this long. */
const STATUS_TIMEOUT_MS = 5000

/** What a failed spawn hangs off the error. Mirrors `tool-probe.ts`. */
interface ExecFailure {
  code?: number | string
  stdout?: string
  stderr?: string
}

async function runTailscale(args: string[], timeout: number): Promise<{ result: CommandResult; binary: string }> {
  const bin = await findTailscale()
  if (bin === null) return { result: { stdout: '', stderr: '', code: -1, spawnError: 'ENOENT' }, binary: '' }

  try {
    const { stdout, stderr } = await run(bin, args, { timeout, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 })
    return { result: { stdout, stderr, code: 0 }, binary: bin }
  } catch (error) {
    const failure = error as ExecFailure
    // A binary that vanished between lookup and run invalidates the memo;
    // otherwise a Tailscale upgrade that moves the CLI stays broken until the
    // app is restarted.
    if (failure.code === 'ENOENT') cachedBin = undefined
    return {
      result: {
        stdout: failure.stdout ?? '',
        stderr: failure.stderr ?? '',
        code: typeof failure.code === 'number' ? failure.code : -1,
        ...(failure.code === 'ENOENT' ? { spawnError: 'ENOENT' } : {}),
      },
      binary: bin,
    }
  }
}

/**
 * Cached, and shared between concurrent callers — the shape `dev-ports.ts` uses.
 *
 * A status call spawns a process and wakes a daemon: cheap once, wasteful on a
 * loop. So it is never polled on a timer, it is answered from cache within
 * CACHE_MS, and any calls arriving while one is in flight wait on that same call
 * rather than spawning their own. Opening the remote panel and its QR code at
 * once costs one `tailscale status`, not two. The window is short on purpose —
 * this answers "right now", and someone who just clicked Connect in the menu bar
 * expects the panel to agree within a few seconds.
 */
const CACHE_MS = 3000
let cached: { at: number; status: TailnetStatus } | null = null
let inFlight: Promise<TailnetStatus> | null = null

export async function tailnetStatus(force = false): Promise<TailnetStatus> {
  if (!force && cached && Date.now() - cached.at < CACHE_MS) return cached.status
  if (inFlight) return inFlight

  inFlight = runTailscale(['status', '--json'], STATUS_TIMEOUT_MS)
    .then(({ result, binary }) => {
      const status = toTailnetStatus(result, binary)
      cached = { at: Date.now(), status }
      return status
    })
    .finally(() => {
      inFlight = null
    })
  return inFlight
}

export type CertFailure = 'not-installed' | 'not-running' | 'https-disabled' | 'bad-name' | 'failed'

export type CertResult =
  | { ok: true; certPath: string; keyPath: string }
  | { ok: false; reason: CertFailure; message: string; detail?: string }

/**
 * A MagicDNS name and nothing else.
 *
 * `execFile` takes no shell, so a metacharacter is not the hazard here — the
 * name is also spliced into two file paths, and `../../something` would write a
 * private key wherever it pointed.
 */
const SAFE_DNS_NAME = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/i

/**
 * Issuance goes out to Let's Encrypt the first time. Two minutes is generous for
 * a request that normally answers in seconds, and it is bounded because an
 * unbounded one hangs whatever is waiting to start serving.
 */
const CERT_TIMEOUT_MS = 120_000

/**
 * Renew rather than hand back a certificate that expires mid-session.
 *
 * Without this flag the CLI returns whatever it has cached as long as it is not
 * already expired. A week of remaining validity is well under the third-of-
 * lifetime ceiling the CA allows here, so it never trips the "min validity too
 * long" refusal.
 */
const MIN_VALIDITY = '168h'

/** Wordings that all mean the same admin toggle, across CLI versions. */
const HTTPS_DISABLED_HINTS = [
  'does not support getting tls certs', // observed on this machine, tailscaled 1.98.9
  'https must be enabled',
  'https is not enabled',
  'certificate not available',
]

/**
 * Turn a finished `tailscale cert` run into an answer.
 *
 * Pure for the same reason as the status parser: the interesting failure is a
 * tailnet-wide setting, and this tailnet only has one of the two values.
 */
export function toCertResult(
  dnsName: string,
  certPath: string,
  keyPath: string,
  result: CommandResult,
): CertResult {
  if (result.spawnError === 'ENOENT') {
    return { ok: false, reason: 'not-installed', message: BLOCKED_REASONS['not-installed'] }
  }
  if (result.code === 0) return { ok: true, certPath, keyPath }

  const said = `${result.stdout}\n${result.stderr}`.toLowerCase()
  const detail = result.stderr.trim() || result.stdout.trim() || undefined

  if (HTTPS_DISABLED_HINTS.some((hint) => said.includes(hint))) {
    return {
      ok: false,
      reason: 'https-disabled',
      // Names the page and the switch. The CLI's own answer is a bare `500
      // Internal Server Error`, which tells nobody this is a setting they own
      // and can change in about ten seconds.
      message:
        `Tailscale HTTPS certificates are turned off for this tailnet, so ${dnsName} cannot get one. ` +
        'Open https://login.tailscale.com/admin/dns, turn on HTTPS Certificates, then try again. ' +
        'Until then your phone can only reach the plain 100.x address, which browsers never treat as secure.',
      ...(detail ? { detail } : {}),
    }
  }

  if (said.includes('failed to connect') || said.includes('is tailscale running')) {
    return { ok: false, reason: 'not-running', message: BLOCKED_REASONS['not-running'], ...(detail ? { detail } : {}) }
  }

  if (result.code === -1) {
    return {
      ok: false,
      reason: 'failed',
      message:
        `Tailscale did not finish issuing a certificate for ${dnsName} within two minutes. ` +
        'Check that https://login.tailscale.com/admin/dns shows HTTPS Certificates on, then try again.',
      ...(detail ? { detail } : {}),
    }
  }

  return {
    ok: false,
    reason: 'failed',
    message:
      `Tailscale could not issue a certificate for ${dnsName}. ` +
      `Run \`tailscale cert ${dnsName}\` in a terminal to see the full answer, then try again.`,
    ...(detail ? { detail } : {}),
  }
}

/**
 * A real Let's Encrypt certificate for the MagicDNS name, on disk.
 *
 * This is the whole reason the name is worth having: it is what makes a phone on
 * the tailnet a secure context, which a `100.x` address can never be no matter
 * what is put in front of it.
 *
 * No cache of our own. tailscaled keeps one and answers from it without going
 * near the CA, so a repeat call costs a process spawn — and `--min-validity` is
 * what turns "we already have one" into "we already have a valid one", which is
 * the question a cache here would have had to answer badly.
 *
 * There is no second implementation: an earlier note here pointed at a
 * `cert.ts` that does not exist in this tree, and suggested deleting this
 * function in favour of it. Doing that would break the TLS server —
 * `loadCert` in `server.ts` calls straight into here for the bytes it hands to
 * `createHttpsServer`. This is the only `ensureCert`.
 *
 * What that note claimed the other copy did — read the PEM back and check
 * expiry and host with `X509Certificate` — is done nowhere. `--min-validity`
 * covers renewal, and `loadCert` finds out about an unreadable pair when the
 * read fails, but nothing verifies the certificate actually matches `dnsName`.
 */
export async function ensureCert(dnsName: string, dir: string): Promise<CertResult> {
  if (!SAFE_DNS_NAME.test(dnsName)) {
    return {
      ok: false,
      reason: 'bad-name',
      message:
        `“${dnsName}” is not a MagicDNS name, so no certificate can be requested for it. ` +
        'Expected something like your-mac.tailnet-name.ts.net, which the tailnet status reports.',
    }
  }

  const certPath = join(dir, `${dnsName}.crt`)
  const keyPath = join(dir, `${dnsName}.key`)

  try {
    // 0o700: a private key lands in here, and the parent is a user-data
    // directory other parts of the app read.
    mkdirSync(dir, { recursive: true, mode: 0o700 })
    // `mode` applies only to directories this call creates. A directory left
    // behind by an earlier version — or by anything else that got there first —
    // keeps whatever mode it already had, which is how the key ends up in a
    // world-readable folder despite the line above.
    chmodSync(dir, 0o700)
  } catch (error) {
    return {
      ok: false,
      reason: 'failed',
      message: `Could not create ${dir} to keep the certificate in. Check that folder’s permissions, then try again.`,
      detail: String(error),
    }
  }

  const { result } = await runTailscale(
    ['cert', '--min-validity', MIN_VALIDITY, '--cert-file', certPath, '--key-file', keyPath, dnsName],
    CERT_TIMEOUT_MS,
  )
  return toCertResult(dnsName, certPath, keyPath, result)
}

export interface TailnetDeps {
  /** Directory the certificate and key are written to; created on demand, 0700. */
  certDir: string
}

export function registerTailnetIpc(ipcMain: IpcMain, deps: TailnetDeps): void {
  // `force` is the Refresh button; everything else takes the cache.
  ipcMain.handle('tailnet:status', (_event, force?: unknown) => tailnetStatus(force === true))
  ipcMain.handle('tailnet:cert', (_event, dnsName?: unknown) =>
    ensureCert(typeof dnsName === 'string' ? dnsName : '', deps.certDir),
  )
}
