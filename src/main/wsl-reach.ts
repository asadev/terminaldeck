/**
 * Whether this app's tool endpoint can be reached from **inside** a WSL
 * distribution, and where the config file naming it lives over there.
 *
 * ## The report
 *
 * Asad, 2026-08-21, on a Windows machine whose work is all in Ubuntu:
 *
 * > *"if the app is inside my windows and i am running session in linux and if
 * > i ask it to open browser it wont work; if both are in windows app and
 * > session then it works fine."*
 *
 * Two separate mechanisms were withholding it, and only one of them had to be.
 *
 *  1. **The `open` shim, correctly.** `open-shim.ts` writes a script that asks
 *     this app over `hook-server.ts`, and on Windows that endpoint is a **named
 *     pipe**. A Linux process inside the distribution cannot open a Windows
 *     named pipe, so a shim there would be a script that always falls through.
 *     `host-core.ts` withholds it for that reason and the reason still holds.
 *  2. **The browser verbs, wrongly.** They do not go through the pipe. They go
 *     through `deck-control/server.ts`, which is plain **HTTP on 127.0.0.1** —
 *     a socket, not a pipe, and a socket is a thing the distribution can be
 *     given an address for. The gate withheld them anyway, on the same
 *     `target === null` test the shim uses, so a session in a Linux folder was
 *     launched with no `--mcp-config` and therefore none of the six verbs.
 *
 * And the half that makes "both in Windows works fine" misleading: there is no
 * shim on Windows either — `writeOpenShim` answers null there and says why. What
 * happens instead is `cmd`'s built-in `start`, which no PATH entry can shadow.
 * A browser opens; it is the **system** browser, outside this app, which is not
 * the feature. The tools route is the one that lands a page in a window here,
 * and it is the route this file opens for WSL.
 *
 * ## The one thing that decides it, and why it is measured rather than assumed
 *
 * `127.0.0.1` inside a distribution is not the same address as `127.0.0.1` on
 * the Windows host, except when it is:
 *
 *  - **Mirrored networking** (`networkingMode=mirrored` in `.wslconfig`, Windows
 *    11 22H2 and WSL 2.0.0 or newer) mirrors the host's interfaces into the
 *    distribution, and a connection to `127.0.0.1` from Linux lands on the
 *    host's loopback listener. This endpoint is then reachable exactly as it is
 *    from a Windows session, and the peer address the server sees is a loopback
 *    literal — so nothing about `server.ts`'s guards has to change. This is the
 *    configuration the feature works in.
 *  - **NAT** (the default) gives the distribution a private address on a
 *    Hyper-V switch. `127.0.0.1` there is the distribution's own loopback, and
 *    the Windows host is only reachable at the default gateway — an address
 *    this server does not listen on at all, because it binds `127.0.0.1` and
 *    nothing else. The connection is refused by the operating system before any
 *    rule of ours is consulted.
 *
 * Neither of those can be read off a Mac, and neither is safe to *infer* on the
 * machine either: `.wslconfig` can say `mirrored` on a WSL too old to honour it,
 * and reading a file to decide whether a socket answers is a guess wearing a
 * measurement's clothes. So this asks the only question that matters, of the
 * only party that can answer it — it runs one command **inside the
 * distribution** that fetches this endpoint's own URL and looks at what comes
 * back. A session is handed the verbs when that answered, and told plainly why
 * not when it did not (`session-verbs.ts`).
 *
 * ## Why the answer has to be a fingerprint and not "something answered"
 *
 * WSL forwards Windows' `localhost` **into** the distribution for services
 * running there (`localhostForwarding`, on by default), and mirrored mode shares
 * the port space in both directions. So `127.0.0.1:<port>` seen from inside the
 * distribution can perfectly well be *a different server* — something in Linux
 * that happens to have bound the same number this app's endpoint took. Treating
 * a bare TCP connect as proof would mean writing a config file that points a
 * Claude CLI, **with this app's bearer token in it**, at whatever that is.
 *
 * So the probe fetches the URL and requires the answer this server gives an
 * unauthenticated caller: `{"error":"refused"}`, from `deny()` in `server.ts`.
 * That single string proves four things at once — the port is reachable, it is
 * *us*, the `Host` header a caller at that address sends is one `hostIsLocal`
 * accepts, and the peer address is one `isLoopback` accepts. It is the whole of
 * "reachable **and** acceptable", asked from the place that has to do it.
 * `wsl-reach.test.ts` pins the string against the real server rather than
 * against a copy of it here.
 *
 * ## The security argument: nothing was widened
 *
 * `server.ts` refuses any peer that is not a loopback literal, and that rule is
 * untouched. It did not need touching, because in the configuration that works
 * the distribution's connection **is** loopback — there is no non-loopback peer
 * to allow.
 *
 * The NAT case would need an allowance, and it is deliberately not built. To
 * make it true this app would have to bind a second listener on the host's
 * address on the WSL virtual switch, which is a listening socket on a
 * non-loopback interface, and then persuade Windows Defender Firewall to let
 * inbound connections through on that interface — which needs elevation, once,
 * from the person. A feature that silently depends on an admin action nobody
 * took is the dead control this app keeps being about, so it is reported
 * instead: the sentence in `session-verbs.ts` names `networkingMode=mirrored`
 * and `wsl --shutdown`, which the person can do without elevation at all.
 *
 * If it is ever built, the shape is already decided and it is **not** a wider
 * `isLoopback`: an allow-set holding the single address the distribution itself
 * reported, *and* a grant flag on the token saying it was minted for a session
 * in that distribution, both required together. A loopback rule loosened for
 * everyone would hand every process on every interface of the machine the
 * chance to guess a port; an address the distro named, plus a token only that
 * session holds, hands it to the one place that already has both.
 *
 * ## What handing a distribution the token is worth, said plainly
 *
 * The config file stays on the Windows side, under `<userData>`, written by
 * `remote/secret-file.ts` with an ACL naming this account alone. A process
 * inside the distribution reads it over DrvFs, which accesses Windows files as
 * the same Windows user — so the ACL is satisfied for exactly the reason it
 * should be, and no reader is added that could not already read it. Anything
 * running in that distribution as that user could have read `<userData>` all
 * along; it is the same sentence `server.ts` writes about another process
 * running as this user on Windows itself.
 */

import {
  decodeWslOutput,
  execWsl,
  isLinuxPath,
  type WslExec,
  type WslTarget,
} from './wsl'

/* --------------------------------------------------------------- constants -- */

/**
 * Where `/mnt/c` lives when nobody has said otherwise.
 *
 * A distribution can move it — `[automount] root` in `/etc/wsl.conf` — which is
 * why this is a fallback rather than the answer. The probe asks `wslpath`, which
 * is WSL's own translator and honours whatever that file says; this is what is
 * used when the answer was unreadable, and it is right on every default install.
 */
export const DEFAULT_AUTOMOUNT_ROOT = '/mnt/'

/**
 * What an unauthenticated caller is told by `deck-control/server.ts`.
 *
 * The fingerprint the probe requires. Written out here rather than imported so
 * that `wsl-reach.ts` does not drag the MCP server into every file that wants a
 * path translated — and pinned against the real server in the test, which is the
 * half that stops the two drifting apart.
 */
export const REFUSAL_FINGERPRINT = '"refused"'

/**
 * Generous, because the first thing a cold WSL2 distribution does is boot a
 * virtual machine.
 *
 * In practice this runs after `detectProviders` has already been inside the same
 * distribution, so it is warm — but a launch restored at startup can reach here
 * first, and a timeout there would report "not reachable" about a machine that
 * simply had not finished starting.
 */
export const REACH_TIMEOUT_MS = 20_000

/**
 * How long a *failed* reading is kept before the question is asked again.
 *
 * A success is kept for the life of the run: the endpoint's port does not move
 * and the distribution's networking mode does not change under a running app.
 * A failure is not, and the asymmetry is the point — this file's own warning
 * about transient failures becoming permanent is the trap `host-core.ts`
 * documents twice, where a probe that timed out once turned into an agent that
 * was gone for good. Re-asking costs a connection refused, which is instant.
 */
export const RETRY_AFTER_MS = 30_000

/**
 * The script, run inside the distribution, that answers both questions at once.
 *
 * Two answers because it is one crossing. `wslpath` is WSL's own path
 * translator and is in every distribution WSL installs, so it is the
 * authoritative reading of where `C:` is mounted — better than this side
 * guessing `/mnt/c` at the exact moment it is about to name a file a CLI has to
 * be able to open.
 *
 * `curl` first and `wget` second because between them they cover every
 * distribution anybody works in; a distro with neither answers nothing, is read
 * as not reachable, and gets the honest sentence rather than a config file
 * pointing somewhere unproven. `--content-on-error` is what makes `wget` print
 * the body of a 403 instead of swallowing it, which is the whole of the
 * fingerprint.
 *
 * The URL arrives as `$1` rather than being interpolated into this text, for the
 * reason `LOGIN_SHELL_SCRIPT` gives in `wsl.ts`: this script is a constant with
 * no caller data in it, and the data is a separate argument that `wsl.exe` hands
 * across whole.
 */
export const REACH_SCRIPT =
  "r=$(wslpath -u 'C:\\' 2>/dev/null); " +
  'printf \'mount=%s\\n\' "$r"; ' +
  'if command -v curl >/dev/null 2>&1; then curl -s --max-time 4 "$1"; exit 0; fi; ' +
  'if command -v wget >/dev/null 2>&1; then ' +
  'wget -q -O - --content-on-error --timeout=4 "$1"; exit 0; fi; ' +
  "printf 'no-http-client\\n'"

/** `$0` for the script above. Only ever seen in an error message from `sh`. */
const REACH_SCRIPT_NAME = 'wsl-reach'

/* ------------------------------------------------------------------- paths -- */

/**
 * The path a process **inside** the distribution can open, for a file this app
 * wrote on Windows.
 *
 * Null rather than a guess when the path is not one that crosses. A caller that
 * is handed null must not launch: a `--mcp-config` naming a file the CLI cannot
 * read is six verbs that answer nothing, which is worse than no verbs and a
 * sentence.
 *
 * A path that is already a Linux one is returned unchanged — that is not a
 * decoration, it is the shape a host running *inside* the distribution would
 * hand this function, and answering null there would be this file refusing a
 * file that needs no translation at all.
 */
export function wslMountPath(windowsPath: string, root: string = DEFAULT_AUTOMOUNT_ROOT): string | null {
  if (windowsPath === '') return null
  if (isLinuxPath(windowsPath)) return windowsPath
  const drive = /^([A-Za-z]):[\\/](.*)$/.exec(windowsPath)
  if (drive === null) return null
  const base = root.endsWith('/') ? root : `${root}/`
  return `${base}${drive[1].toLowerCase()}/${drive[2].replace(/\\/g, '/')}`
}

/**
 * `/mnt/` out of `wslpath`'s answer for `C:\`.
 *
 * The drive letter is dropped rather than kept because the *root* is what any
 * other drive is mounted under too, and this app's data directory is not
 * guaranteed to be on `C:`.
 */
export function automountRoot(answer: string): string {
  const match = /^(\/(?:.*\/)?)[A-Za-z]\/?$/.exec(answer.trim())
  return match === null ? DEFAULT_AUTOMOUNT_ROOT : match[1]
}

/* ------------------------------------------------------------------- reach -- */

/** What a session inside a distribution needs, once the endpoint has answered it. */
export interface WslPlacement {
  /** Where `C:` is mounted in that distribution, as `wslpath` reported it. */
  readonly mount: string
  /** The path to give `--mcp-config`, or null for a file that cannot be named there. */
  argPath(file: string): string | null
}

interface Reading {
  at: number
  placement: WslPlacement | null
}

/** distro+url → what the last probe found. See {@link RETRY_AFTER_MS}. */
const readings = new Map<string, Reading>()
/** The same key → a probe already out, so two launches at once make one crossing. */
const inFlight = new Map<string, Promise<WslPlacement | null>>()

function keyFor(target: WslTarget, endpointUrl: string): string {
  // JSON rather than a joined string: a distribution's name is user data and a
  // separator character is a thing user data can contain.
  return JSON.stringify([target.distro ?? '', endpointUrl])
}

export interface DistroReachOptions {
  exec?: WslExec
  now?: () => number
}

/**
 * Can a Claude CLI inside this distribution reach this endpoint, and where does
 * its config file live over there?
 *
 * Null means *do not hand this session the verbs* — and `host-core.ts` turns
 * that into the one sentence the session is told instead. There is deliberately
 * no third answer distinguishing "no endpoint yet" from "not reachable": the
 * remedy the person is given starts with starting the session again, which is
 * the whole of the fix for the first and the first step of the fix for the
 * second.
 */
export async function distroPlacement(
  target: WslTarget,
  endpointUrl: string,
  options: DistroReachOptions = {},
): Promise<WslPlacement | null> {
  // Nothing to point a distribution at. Not remembered, because it is a fact
  // about this second rather than about the machine.
  if (endpointUrl === '') return null

  const now = options.now ?? Date.now
  const key = keyFor(target, endpointUrl)

  const known = readings.get(key)
  if (known !== undefined) {
    if (known.placement !== null) return known.placement
    if (now() - known.at < RETRY_AFTER_MS) return null
  }

  const already = inFlight.get(key)
  if (already !== undefined) return already

  const run = probe(target, endpointUrl, options.exec ?? execWsl)
    .then((placement) => {
      readings.set(key, { at: now(), placement })
      return placement
    })
    .catch((error: unknown) => {
      // A probe that threw must not be the reason a session fails to start. It
      // is read as "not reachable", which is the conservative direction and the
      // one with a sentence attached.
      console.error('[wsl] could not ask the distribution about the tool endpoint:', error)
      readings.set(key, { at: now(), placement: null })
      return null
    })
    .finally(() => {
      inFlight.delete(key)
    })

  inFlight.set(key, run)
  return run
}

async function probe(
  target: WslTarget,
  endpointUrl: string,
  exec: WslExec,
): Promise<WslPlacement | null> {
  const args = [
    ...(target.distro !== null && target.distro !== '' ? ['-d', target.distro] : []),
    // `-e`, not `--`, for the reason `wslLaunch` gives at length: `--` hands the
    // remaining command line to a shell we did not choose, which would parse
    // `$(wslpath …)` on the way past.
    '-e',
    'sh',
    '-c',
    REACH_SCRIPT,
    REACH_SCRIPT_NAME,
    endpointUrl,
  ]
  const answer = await exec(args, REACH_TIMEOUT_MS)
  const text = decodeWslOutput(answer.stdout)
  if (!text.includes(REFUSAL_FINGERPRINT)) return null
  const mount = automountRoot(/^mount=(.*)$/m.exec(text)?.[1] ?? '')
  return { mount, argPath: (file: string) => wslMountPath(file, mount) }
}

/**
 * Forget every reading.
 *
 * A test seam. Nothing in the app calls it: a run's readings are about a port
 * that does not move and a machine that does not change under it.
 */
export function resetDistroReachForTests(): void {
  readings.clear()
  inFlight.clear()
}
