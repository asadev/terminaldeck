/**
 * "Which ports on this machine are being listened on, and by what?" — asked of
 * two operating systems that answer with completely different commands.
 *
 * `dev-ports.ts` owns the policy (which processes are worth offering, how they
 * are ranked, the cache). This file owns only the platform difference: the
 * commands to run and how to read what they print. Splitting it that way is what
 * makes the Windows half testable on a Mac — the parsers are pure functions over
 * captured output, so both platforms are pinned in the same test run.
 *
 * ## macOS / Linux: `lsof`
 *
 * Verified against real output on the machine this was written on. One row per
 * socket, IPv4 and IPv6 listed separately for the same server:
 *
 *     COMMAND     PID  USER   FD   TYPE  DEVICE  SIZE/OFF NODE NAME
 *     node      92487 apple   16u  IPv6  0x7f3d       0t0  TCP [::1]:5199 (LISTEN)
 *     Python    15193 apple    3u  IPv4  0x824d       0t0  TCP 127.0.0.1:8931 (LISTEN)
 *     ControlCe   745 apple   11u  IPv4  0xbde4       0t0  TCP *:5000 (LISTEN)
 *
 * ## Windows: `netstat -ano` plus `tasklist`
 *
 * `lsof` does not exist there. `netstat` knows the ports and the owning PID but
 * not the process name; `tasklist` knows PID-to-name. Two spawns, joined here.
 *
 *     Proto  Local Address      Foreign Address    State       PID
 *     TCP    127.0.0.1:3000     0.0.0.0:0          LISTENING   12044
 *
 * The protocol column is filtered here rather than by `netstat -p`, so that an
 * IPv6-only dev server survives however this machine's `netstat` labels and
 * selects the v6 table — see `NETSTAT` below for why that is not a detail.
 *
 * PowerShell's `Get-NetTCPConnection` would answer both halves in one call and
 * was rejected: starting PowerShell costs several hundred milliseconds against
 * `netstat`'s few, this runs while someone is looking at a start page, and the
 * cmdlet needs a module that `netstat.exe` — present on every Windows since XP —
 * does not.
 *
 * **Two decoding details that are not cosmetic**, both of which come from the
 * same fact: `netstat`'s human-readable parts are localised.
 *
 *  - The header (`Active Connections`, the column names) is translated, so the
 *    row that starts the data cannot be found by counting lines. Rows are
 *    recognised by *shape* instead — protocol token, two host:port columns.
 *  - `LISTENING` is translated too (`ABHÖREN` on a German install). Matching it
 *    would return nothing at all outside English Windows, which is a silent,
 *    total failure on a machine where everything looks fine. So the listening
 *    test is the foreign address: only a listening socket has `0.0.0.0:0` or
 *    `[::]:0` on the far side, and those are numeric on every locale. The state
 *    column still has to be *present* — that is what separates a five-column TCP
 *    row from a four-column UDP one, which carries no state at all.
 *
 * This half was written from documented and widely-known output formats. One
 * line of it has since been checked against a real Windows machine
 * (`desktop-ddgmncv`, 2026-08-14): an IPv6-only dev server really is printed as
 *
 *     TCP    [::1]:5199             [::]:0                 LISTENING       22200
 *
 * — protocol token `TCP`, not `TCPv6`, and the address bracketed. Both of those
 * were guesses before and both are now measurements, which is what
 * {@link loopbackFamily} relies on. The rest of the parsers stay pinned against
 * captured samples, which proves the decoding and not the capture.
 */

import { isWindows, type Platform } from './host'
import type { CommandSpec } from './lookup'

/**
 * Which loopback a listener answers on. 4 is `127.0.0.1`, 6 is `::1`.
 *
 * Carried out of the scan because it is the only place that knows it, and
 * because a tunnel that dials the wrong one gets `ECONNREFUSED` on a port the
 * same scan just said was live. Measured on `desktop-ddgmncv` rather than
 * assumed: `node --host localhost` on Windows binds **`::1` only**
 * (`{"address":"::1","family":"IPv6"}`), `netstat -ano` prints it as
 * `TCP  [::1]:5199  [::]:0  LISTENING`, and dialling `127.0.0.1:5199` from the
 * same machine answers `ECONNREFUSED` while `::1` connects. macOS never shows
 * this because the same servers bind `127.0.0.1` first there.
 */
export type LoopbackFamily = 4 | 6

/**
 * One listening port and, when the OS would say, what holds it.
 *
 * `process: null` means the port genuinely answers but could not be named — the
 * honest input to `DevPort.guessed`. It is a real Windows case: `netstat` lists
 * a PID that `tasklist` will not describe (a protected process, or one that
 * exited between the two calls).
 *
 * One row is one *socket*, so a dual-stack server appears twice with a
 * different `family` each time. Collapsing those into one port is
 * `dev-ports.ts`'s job, because it is the thing that also has to decide which
 * of the two processes gets the credit.
 */
export interface PortOwner {
  port: number
  process: string | null
  family: LoopbackFamily
}

/** Addresses a browser on this machine can actually reach. */
const LOCAL_HOSTS = new Set(['', '*', '0.0.0.0', '127.0.0.1', '::', '::1', '[::]', '[::1]'])

/** The IPv6 spellings both tools use, wildcard and loopback, with and without brackets. */
const IPV6_HOSTS = new Set(['::', '::1', '[::]', '[::1]'])

/**
 * Which loopback family a row describes.
 *
 * Two sources, in the order they can be trusted. `lsof` prints a decisive
 * `IPv4`/`IPv6` in its TYPE column, and it needs to: its wildcard rows are
 * written `*:5000` with nothing in the address to tell the families apart.
 * `netstat` has no such column — it labels IPv6 rows `TCP` as often as `TCPv6`,
 * which is why a `TCP` hint must fall through rather than decide — but it
 * always brackets an IPv6 address, so the address itself answers.
 *
 * Anything else is IPv4. That is the safe direction: it is what this module
 * assumed everywhere before today, so an unrecognised spelling behaves exactly
 * as it did rather than newly dialling somewhere it has never dialled.
 */
export function loopbackFamily(host: string, typeHint = ''): LoopbackFamily {
  const hint = typeHint.toUpperCase()
  if (hint === 'IPV6' || hint === 'TCPV6') return 6
  if (hint === 'IPV4') return 4
  return IPV6_HOSTS.has(host) ? 6 : 4
}

/**
 * Split a `host:port` as either tool writes it, including bracketed IPv6.
 *
 * The port is the tail after the last colon, which is why the brackets matter:
 * `[::1]:5199` has four of them and only the last one separates the port.
 */
export function splitHostPort(address: string): { host: string; port: number } | null {
  const match = /(?:^|:)(\d+)$/.exec(address)
  if (!match) return null
  const port = Number(match[1])
  if (!Number.isInteger(port) || port <= 0 || port > 65535) return null
  return { host: address.slice(0, address.lastIndexOf(':')), port }
}

/** Loopback or any-address — the wildcard spellings differ between the tools. */
export function isLocallyReachable(host: string): boolean {
  return LOCAL_HOSTS.has(host)
}

/* ------------------------------------------------------------ macOS / Unix -- */

export const LSOF: CommandSpec = { command: 'lsof', args: ['-nP', '-iTCP', '-sTCP:LISTEN'] }

/**
 * The same question in `lsof`'s machine-readable field mode.
 *
 * `-F` prints one value per line, each prefixed by a single letter naming the
 * field, and it answers two things the column output above cannot. Both were
 * measured on this machine rather than read off a manual page:
 *
 *  - **The command is not truncated.** Column mode pads COMMAND to nine
 *    characters, so `ControlCenter` prints as `ControlCe`, `Google Chrome` as
 *    `Google`, and — the one that started this — every port `Terminal Deck`
 *    holds prints as `Terminal`. Field mode prints `cControlCenter`,
 *    `cGoogle Chrome`, `cTerminal Deck`. A start page listing eight rows all
 *    called "Terminal" is a direct consequence of the nine-character clamp.
 *  - **`R` is the parent PID**, which is what makes "is this port one of ours?"
 *    answerable. Electron's helper processes are direct children of the main
 *    process, so a row is this app's when its pid or its ppid is our own — no
 *    guessing from a name, and no second `ps`.
 *
 * The fields asked for are `p` (pid), `c` (command), `R` (ppid), `t` (type,
 * IPv4/IPv6) and `n` (the address). `f` (the descriptor) is printed whether or
 * not it is asked for; it is what separates one socket from the next.
 */
export const LSOF_FIELDS: CommandSpec = {
  command: 'lsof',
  args: ['-nP', '-iTCP', '-sTCP:LISTEN', '-FpcRtn'],
}

/**
 * A {@link PortOwner} that also knows which process, exactly, is holding it.
 *
 * `process` is narrowed to a plain string because field mode always prints the
 * command — the `null` case in `PortOwner` is the Windows one, where `netstat`
 * names a PID that `tasklist` will not describe.
 *
 * `ppid` is -1 when `lsof` printed no `R` field for the process set. That is not
 * expected on any platform this runs on, and it fails towards "not one of ours",
 * which leaves a port listed rather than hiding somebody's dev server.
 */
export interface PortProcess extends PortOwner {
  process: string
  pid: number
  ppid: number
}

/**
 * Parse `lsof -F` output.
 *
 * The format is a stream, not a table: a `p` line opens a *process set* and
 * everything after it — the command, the parent pid, then one `f` block per
 * open file — belongs to that process until the next `p`. So the parser is a
 * small state machine rather than a line-per-row loop.
 *
 * `t` is reset by every `f` rather than only by `p`. TYPE belongs to the file,
 * not to the process, and a socket that printed no type would otherwise inherit
 * the family of the one before it — which is precisely the IPv4/IPv6 confusion
 * that left a dev server listed and unreachable.
 */
export function parseLsofFields(stdout: string): PortProcess[] {
  const owners: PortProcess[] = []
  let pid = -1
  let ppid = -1
  let command = ''
  let type = ''

  for (const line of stdout.split('\n')) {
    if (line === '') continue
    const tag = line[0]
    const value = line.slice(1)
    if (tag === 'p') {
      pid = Number(value)
      // A new process set inherits nothing from the last one.
      ppid = -1
      command = ''
      type = ''
    } else if (tag === 'R') {
      ppid = Number(value)
    } else if (tag === 'c') {
      command = value
    } else if (tag === 'f') {
      type = ''
    } else if (tag === 't') {
      type = value
    } else if (tag === 'n') {
      if (!Number.isInteger(pid) || pid < 0 || command === '') continue
      const split = splitHostPort(value)
      if (!split || !isLocallyReachable(split.host)) continue
      owners.push({
        port: split.port,
        process: command,
        pid,
        ppid: Number.isInteger(ppid) ? ppid : -1,
        family: loopbackFamily(split.host, type),
      })
    }
  }

  return owners
}

/**
 * Every local listening row `lsof` printed, in the order it printed them.
 *
 * Deliberately does no filtering and no de-duplication: both are policy that
 * belongs to `dev-ports.ts`, and doing them here in a different order than it
 * does changes which process gets credited for a port that two of them touch.
 *
 * A command name containing a space would shift the columns and the row falls
 * out at the address test. That has been true since this code was written; it
 * fails towards showing one port less rather than towards naming it wrongly.
 */
export function parseLsof(stdout: string): PortOwner[] {
  const owners: PortOwner[] = []
  // The header is a fixed English string from a tool that does not localise it,
  // so dropping the first line is safe here in a way it is not for netstat.
  for (const line of stdout.split('\n').slice(1)) {
    const columns = line.split(/\s+/)
    const command = columns[0]
    // Column 4 is TYPE — `IPv4` or `IPv6`. It is the only thing that separates
    // the families on a wildcard row, which lsof writes as a bare `*:5000`.
    const type = columns[4]
    const address = columns[8]
    if (!command || !address) continue
    const split = splitHostPort(address)
    if (!split || !isLocallyReachable(split.host)) continue
    owners.push({ port: split.port, process: command, family: loopbackFamily(split.host, type) })
  }
  return owners
}

/* ---------------------------------------------------------------- Windows -- */

/**
 * `-a` all connections, `-n` numeric (no DNS or service-name lookups, which is
 * also what keeps this fast), `-o` the owning PID.
 *
 * Deliberately **without** `-p TCP`. `netstat`'s own help lists the protocol
 * selectors as `TCP, UDP, TCPv6, UDPv6` — four families, not two — so `-p TCP`
 * may well mean "the IPv4 TCP table" and nothing else. Neither reading can be
 * checked from here, and one of them loses every IPv6-only listener: a dev
 * server on `[::1]:5173` would simply not exist on the start page, which looks
 * from the outside exactly like a machine with nothing running.
 *
 * Dropping the selector costs nothing, because the filtering it would have done
 * is already done below by name: `parseNetstat` keeps only rows whose protocol
 * token is TCP or TCPv6, and a UDP row is four tokens wide and falls out at the
 * shape test regardless. So the parser is correct under either reading of `-p`,
 * which is the most that can honestly be arranged without a Windows machine.
 */
export const NETSTAT: CommandSpec = { command: 'netstat.exe', args: ['-ano'] }

/** `/NH` drops the (localised) header row; `/FO CSV` quotes names with spaces. */
export const TASKLIST: CommandSpec = { command: 'tasklist.exe', args: ['/FO', 'CSV', '/NH'] }

/** A listening socket's far side, on every locale and both address families. */
const UNBOUND_PEER = new Set(['0.0.0.0:0', '[::]:0', '*:*'])

export interface NetstatRow {
  port: number
  pid: number
  family: LoopbackFamily
}

/**
 * Local listening TCP ports and their owning PIDs.
 *
 * Rows are found by shape rather than by position, and "listening" is decided
 * by the foreign address rather than by the state word — see the module header
 * for why both of those are load-bearing outside English Windows.
 */
export function parseNetstat(stdout: string): NetstatRow[] {
  const rows: NetstatRow[] = []
  for (const line of stdout.split(/\r?\n/)) {
    const columns = line.trim().split(/\s+/)
    // Proto, local, foreign, state, pid. A UDP row has four and no state, which
    // is exactly why the length is checked rather than the state's contents.
    if (columns.length !== 5) continue
    // Both spellings: `netstat -an` labels IPv6 rows `TCP` on the installs this
    // was written from, and `-p` documents a separate `TCPv6` family. Accepting
    // both means the IPv6 half survives whichever label the machine uses.
    const proto = columns[0].toUpperCase()
    if (proto !== 'TCP' && proto !== 'TCPV6') continue
    if (!UNBOUND_PEER.has(columns[2])) continue

    const pid = Number(columns[4])
    if (!Number.isInteger(pid) || pid < 0) continue

    const split = splitHostPort(columns[1])
    if (!split || !isLocallyReachable(split.host)) continue
    rows.push({ port: split.port, pid, family: loopbackFamily(split.host, proto) })
  }
  return rows
}

/**
 * One CSV record's fields, honouring quotes.
 *
 * Hand-rolled rather than split on commas because both fields that matter can
 * contain one: `tasklist` prints memory as `98,304 K`, and an image name may
 * carry a comma of its own. Windows quotes every field in `/FO CSV`, so the
 * only escape that needs handling is the doubled quote inside a quoted field.
 */
function csvFields(line: string): string[] {
  const fields: string[] = []
  let field = ''
  let quoted = false
  for (let i = 0; i < line.length; i++) {
    const char = line[i]
    if (quoted) {
      if (char !== '"') field += char
      else if (line[i + 1] === '"') {
        field += '"'
        i++
      } else quoted = false
    } else if (char === '"') quoted = true
    else if (char === ',') {
      fields.push(field)
      field = ''
    } else field += char
  }
  fields.push(field)
  return fields
}

/**
 * PID to process name, with the `.exe` taken off.
 *
 * The suffix is dropped so a Windows row reads the way a macOS one does —
 * `node`, not `node.exe`. That is not cosmetic: `dev-ports.ts` matches process
 * names against an exact-match exclusion set, and `Docker Desktop.exe` would
 * miss an entry written as `Docker`.
 */
export function parseTasklist(stdout: string): Map<number, string> {
  const names = new Map<number, string>()
  for (const line of stdout.split(/\r?\n/)) {
    if (line.trim() === '') continue
    const fields = csvFields(line)
    if (fields.length < 2) continue
    const pid = Number(fields[1].trim())
    const name = fields[0].trim().replace(/\.exe$/i, '')
    if (!Number.isInteger(pid) || name === '') continue
    names.set(pid, name)
  }
  return names
}

/**
 * Join the two Windows calls into the same shape the `lsof` path produces.
 *
 * A PID with no name still yields a row: the port is answering either way, and
 * dropping it would hide a dev server behind a `tasklist` that refused to
 * describe its owner. `null` there becomes `guessed: true` on screen.
 */
export function windowsOwners(rows: NetstatRow[], names: Map<number, string>): PortOwner[] {
  return rows.map((row) => ({ port: row.port, process: names.get(row.pid) ?? null, family: row.family }))
}

/* ------------------------------------------------------------------ choice -- */

/**
 * Whether this platform is scanned with the two-command Windows path or the
 * single `lsof` call. Exported so the choice itself can be pinned by a test
 * rather than inferred from which command happened to be spawned.
 */
export function portScanKind(platform: Platform): 'netstat+tasklist' | 'lsof' {
  return isWindows(platform) ? 'netstat+tasklist' : 'lsof'
}
