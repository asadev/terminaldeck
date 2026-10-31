import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'
import { machineNoun } from '../platform/host'
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
 * showed: `serve` answers in well under a second there. On Windows 11 it was
 * measured still alive after 30 seconds and had to be killed, while
 * `serve … off` returned in 28ms. That was read as "Windows does not answer",
 * and it was a misreading — see `NEEDS_ENABLING` below for what it was actually
 * doing. The bound is still right; it is just no longer how the common case is
 * discovered.
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
 * The reason `serve` sits there, and the reason the timeout above was a
 * misdiagnosis.
 *
 * Measured on `desktop-ddgmncv` — Windows 11 26200, Tailscale 1.102.1, backend
 * Running, elevated — `serve --bg --https=8443 http://127.0.0.1:8443` is not
 * wedged and is not slow. It writes this, immediately, to **stdout**:
 *
 *     Serve is not enabled on your tailnet.
 *     To enable, visit:
 *
 *              https://login.tailscale.com/f/serve?node=nL3GN8Ypuc11CNTRL
 *
 * and then waits, indefinitely, for someone to go and click it. It is a prompt,
 * not a hang. Two things followed from reading it as a hang:
 *
 *  - **Every `remote:start` cost the full fifteen seconds**, on a machine where
 *    the answer was available in milliseconds and was never going to change.
 *    The panel spun for fifteen seconds on every launch, which is the whole of
 *    what "the remote thing does not work" looks like from the outside.
 *  - **The one sentence that names the fix was thrown away.** `execFile`'s
 *    timeout kills the child and hangs its output off the error object; this
 *    module read `error.message` and never `error.stdout`. So the user was told
 *    "Tailscale did not answer", which blames the wrong thing and names no next
 *    step, instead of "switch Serve on, here is the link".
 *
 * So the child is spawned rather than exec'd, and its output is read as it
 * arrives. The timeout stays for a genuine hang; it just stops being the way
 * the common case is discovered.
 */
const NEEDS_ENABLING = /\bserve is not enabled on your tailnet\b/i

/**
 * The admin link out of Tailscale's own message.
 *
 * `tailnet.ts` redacts `login.tailscale.com` URLs out of anything it shows, and
 * that is right there: the URL it is redacting is `AuthURL`, a bearer
 * capability — whoever opens it can join a machine to the tailnet without
 * further proof. This one is not that. `/f/serve?node=…` is a deep link into
 * the admin console that does nothing at all without an authenticated tailnet
 * admin session, and it is the difference between a dead end and one click. So
 * it is shown, deliberately, and the distinction is written down here rather
 * than left for someone to rediscover as an inconsistency.
 */
const ENABLE_LINK = /https:\/\/login\.tailscale\.com\/f\/serve\?\S+/


/**
 * Tailscale's serve config is stored by tailscaled and survives our process.
 * A crash would otherwise leave a proxy pointing at a port nothing is on, so
 * the port is always cleared before it is claimed.
 */
export async function serveOn(httpsPort: number, localPort: number): Promise<ServeResult> {
  const binary = await findTailscale()
  if (!binary) {
    return { ok: false, message: `The tailscale command could not be found on this ${machineNoun()}.` }
  }
  await serveOff(httpsPort).catch(() => {})
  return startServe(binary, ['serve', '--bg', `--https=${httpsPort}`, `http://127.0.0.1:${localPort}`])
}

/**
 * Run `serve` and answer the moment the answer is knowable.
 *
 * `spawn` rather than `execFile` for one reason: `execFile` buffers and hands
 * everything over at once, at exit — and the case that matters here is a child
 * that has already said everything it is going to say and is *not* going to
 * exit. Reading the pipe as it fills is what turns that from a fifteen-second
 * timeout into a sub-second answer carrying Tailscale's own words.
 *
 * Order matters in the matching below and is not incidental: the "not enabled"
 * message *contains an https URL*, so a success check that looked for a URL
 * first would report the failure as a working proxy and hand the panel a link
 * to the Tailscale admin console as if it were the address of this machine.
 */
function startServe(binary: string, args: string[]): Promise<ServeResult> {
  return new Promise<ServeResult>((resolve) => {
    // `windowsHide` so a console does not flash over whatever the user is doing.
    const child = spawn(binary, args, { windowsHide: true })
    let out = ''
    let err = ''
    let settled = false

    const finish = (result: ServeResult): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      // The prompt case never exits on its own. Nothing else in the process is
      // holding a reference to it, so an unkilled child would sit there for the
      // life of the app with a pipe nobody reads.
      child.kill()
      resolve(result)
    }

    const timer = setTimeout(() => {
      finish({
        ok: false,
        // Just the cause, with nothing about what still works. The surfaces
        // that render this only render it when the relay is *not* carrying the
        // session — the desktop's tailnet row and `terminaldeck status` both
        // stay silent about a missing optimisation while a phone can get in
        // some other way — so it arrives beside the relay's own sentence, and a
        // reassurance here would either stutter against it or contradict it.
        message:
          `Tailscale did not answer within ${Math.round(SERVE_TIMEOUT_MS / 1000)} seconds, so the ` +
          'direct tailnet address is not available.',
        detail: (out + err).trim().slice(0, 400),
      })
    }, SERVE_TIMEOUT_MS)
    // A pending timer must not be the reason the process stays alive.
    timer.unref?.()

    const reread = (): void => {
      // The refusal is looked for across both streams, because which one
      // carries it is a detail of the Tailscale build; the URL is taken from
      // stdout alone, so a link in a warning on stderr can never be mistaken
      // for this machine's address.
      if (NEEDS_ENABLING.test(out) || NEEDS_ENABLING.test(err)) {
        const link = ENABLE_LINK.exec(out + err)?.[0]
        return finish({
          ok: false,
          message:
            'Serve is switched off for this tailnet, so Tailscale will not put a proxy in front ' +
            `of the app.${link ? ` Turn it on at ${link}` : ' Turn it on in the Tailscale admin console'}, ` +
            'then try again.',
          detail: (out + err).trim().slice(0, 400),
        })
      }
      // The command prints the public URL; taking it from the output rather
      // than rebuilding it means the name always matches what Tailscale
      // actually serves, including the port it chose to display.
      const url = /https:\/\/\S+/.exec(out)?.[0]
      if (url) finish({ ok: true, url: url.replace(/\/+$/, '/') })
    }

    child.stdout?.on('data', (chunk: unknown) => {
      out += String(chunk)
      reread()
    })
    child.stderr?.on('data', (chunk: unknown) => {
      err += String(chunk)
      reread()
    })

    child.on('error', (error: Error) => {
      finish({ ok: false, message: describe(error.message), detail: error.message.slice(0, 400) })
    })

    child.on('close', (code) => {
      if (settled) return
      const said = (err || out).trim()
      if (code === 0) {
        finish({
          ok: false,
          message: 'Tailscale accepted the proxy but did not report a URL for it.',
          detail: out.trim().slice(0, 400),
        })
        return
      }
      finish({ ok: false, message: describe(said), detail: said.slice(0, 400) })
    })
  })
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
      `Tailscale cannot get a certificate for this ${machineNoun()}. ` +
      'Open https://login.tailscale.com/admin/dns and turn on HTTPS Certificates, then try again.'
    )
  }
  if (lower.includes('failed to connect') || lower.includes('is tailscale running')) {
    return `Tailscale is not running on this ${machineNoun()}. Start it, then try again.`
  }
  if (lower.includes('permission') || lower.includes('access denied')) {
    return 'Tailscale refused the request. Serving may be disabled for this tailnet in the admin console.'
  }
  // Trimmed, because `tailscale.exe` ends its lines with CRLF and splitting on
  // `\n` alone leaves the carriage return on the end of the sentence this puts in
  // front of a person. Every other read in this file trims; this one did not.
  return `Tailscale could not put a proxy in front of this app: ${said.split('\n')[0]?.trim() ?? ''}`
}
