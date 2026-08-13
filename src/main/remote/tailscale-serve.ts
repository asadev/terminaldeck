import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { findTailscale } from './tailnet'

const run = promisify(execFile)

/**
 * Puts Tailscale's own proxy in front of a loopback HTTP server.
 *
 * The first design served HTTPS directly from the main process, and it does not
 * work: Electron builds Node against BoringSSL, and `https.createServer` there
 * accepts the TCP connection and then never completes the TLS handshake — no
 * error, no `tlsClientError`, just a socket that hangs until the client gives
 * up. Measured side by side on this machine with the same certificate and the
 * same address: plain Node answered 200, Electron's Node answered nothing.
 *
 * `tailscale serve` terminates TLS outside the app, with the certificate
 * Tailscale already manages, and forwards to `127.0.0.1`. That removes the
 * whole certificate path — no issuance, no renewal, no private key on our
 * disk — and it makes the app's own listener loopback-only, which is a smaller
 * surface than binding a tailnet address ourselves.
 *
 * The proxy is reachable only from the tailnet. `serve` is not `funnel`:
 * nothing here publishes to the internet, and this module never calls funnel.
 */

export type ServeResult =
  | { ok: true; url: string }
  | { ok: false; message: string; detail?: string }

/**
 * How long `tailscale serve` gets before the tailnet is written off for this
 * attempt.
 *
 * Both calls below used to pass no timeout at all, and on macOS that never
 * showed: `serve` answers in well under a second there. On Windows 11 it does
 * not answer at all — measured on `desktop-ddgmncv`, Tailscale 1.102.1, backend
 * Running: `serve --bg --https=8443 http://127.0.0.1:8443` was still alive
 * after 30 seconds and had to be killed, while `serve … off` returned in 28ms.
 *
 * `execFile` with no timeout turns that into a promise that never settles, and
 * the damage is out of all proportion to the cause. `server.ts` awaits this
 * inside `open()`, so `remote:start` never replied, the IPC trace showed a `→`
 * with no `←` for the rest of the process's life, the panel span forever, and
 * nothing was logged anywhere. **The relay does not need Tailscale for
 * anything** — it is an outbound dial — so a tailnet that could not answer was
 * taking down the one path that would have worked regardless. That is the whole
 * bug: not that the fast path failed, but that failing took the slow path with
 * it.
 *
 * So the wait is bounded and a timeout is an answer. `open()` reads a failed
 * serve as `directReason` — a note that the faster route is unavailable — and
 * carries on to start the relay, which is what the split between `reason` and
 * `directReason` exists for.
 *
 * Generous rather than tight: a first `serve` on a tailnet that has just had
 * HTTPS certificates switched on has real work to do, and cutting that short
 * would swap a hang for a spurious failure. Nothing waits on this but a
 * spinner, and the relay is already dialling.
 */
const SERVE_TIMEOUT_MS = 15_000

/** Clearing a port is a local config edit; it answered in 28ms even on Windows. */
const SERVE_OFF_TIMEOUT_MS = 10_000

/**
 * Tailscale's serve config is stored by tailscaled and survives our process.
 * A crash would otherwise leave a proxy pointing at a port nothing is on, so
 * the port is always cleared before it is claimed.
 */
export async function serveOn(httpsPort: number, localPort: number): Promise<ServeResult> {
  const binary = await findTailscale()
  if (!binary) {
    return { ok: false, message: 'The tailscale command could not be found on this Mac.' }
  }
  await serveOff(httpsPort).catch(() => {})
  try {
    const { stdout } = await run(
      binary,
      ['serve', '--bg', `--https=${httpsPort}`, `http://127.0.0.1:${localPort}`],
      // `windowsHide` so a console does not flash over whatever the user is
      // doing; the timeout is the point — see SERVE_TIMEOUT_MS.
      { timeout: SERVE_TIMEOUT_MS, windowsHide: true },
    )
    // The command prints the public URL; taking it from the output rather than
    // rebuilding it means the name always matches what Tailscale actually
    // serves, including the port it chose to display.
    const url = /https:\/\/\S+/.exec(stdout)?.[0] ?? null
    if (!url) {
      return {
        ok: false,
        message: 'Tailscale accepted the proxy but did not report a URL for it.',
        detail: stdout.trim().slice(0, 400),
      }
    }
    return { ok: true, url: url.replace(/\/+$/, '/') }
  } catch (error) {
    // A timeout arrives here as a killed child, and `execFile` reports that as
    // a signal rather than as anything mentioning time. Told apart explicitly,
    // because "tailscale never answered" and "tailscale said no" ask the reader
    // to do completely different things — and the first one is not their fault.
    const killed = (error as { killed?: boolean }).killed === true
    const said = error instanceof Error ? error.message : String(error)
    if (killed) {
      return {
        ok: false,
        // Just the cause. The panel that renders this already follows it with
        // "Remote access is still up — everything below is going through the
        // relay", and saying it twice in two sentences reads like a stutter —
        // which is only visible by looking at the rendered panel, not the diff.
        message:
          `Tailscale did not answer within ${Math.round(SERVE_TIMEOUT_MS / 1000)} seconds, so the ` +
          'direct tailnet address is not available.',
        detail: said.slice(0, 400),
      }
    }
    return { ok: false, message: describe(said), detail: said.slice(0, 400) }
  }
}

/**
 * Idempotent: clearing a port that is not served is not an error worth raising.
 *
 * Bounded for the same reason as `serveOn` — `stop()` awaits this one, so an
 * unbounded call here would make turning remote access *off* hang just as
 * turning it on did.
 */
export async function serveOff(httpsPort: number): Promise<void> {
  const binary = await findTailscale()
  if (!binary) return
  await run(binary, ['serve', `--https=${httpsPort}`, 'off'], {
    timeout: SERVE_OFF_TIMEOUT_MS,
    windowsHide: true,
  }).catch(() => {})
}

/** Turns tailscale's own wording into something that names the fix. */
function describe(said: string): string {
  const lower = said.toLowerCase()
  if (lower.includes('funnel') && lower.includes('not')) {
    return 'Tailscale refused to serve this port. Check that HTTPS Certificates are enabled for this tailnet.'
  }
  if (lower.includes('tls') || lower.includes('cert')) {
    return (
      'Tailscale cannot get a certificate for this Mac. Open https://login.tailscale.com/admin/dns ' +
      'and turn on HTTPS Certificates, then try again.'
    )
  }
  if (lower.includes('failed to connect') || lower.includes('is tailscale running')) {
    return 'Tailscale is not running on this Mac. Start it, then try again.'
  }
  if (lower.includes('permission') || lower.includes('access denied')) {
    return 'Tailscale refused the request. Serving may be disabled for this tailnet in the admin console.'
  }
  return `Tailscale could not put a proxy in front of this app: ${said.split('\n')[0]}`
}
