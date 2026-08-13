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
    const { stdout } = await run(binary, [
      'serve',
      '--bg',
      `--https=${httpsPort}`,
      `http://127.0.0.1:${localPort}`,
    ])
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
    const said = error instanceof Error ? error.message : String(error)
    return { ok: false, message: describe(said), detail: said.slice(0, 400) }
  }
}

/** Idempotent: clearing a port that is not served is not an error worth raising. */
export async function serveOff(httpsPort: number): Promise<void> {
  const binary = await findTailscale()
  if (!binary) return
  await run(binary, ['serve', `--https=${httpsPort}`, 'off']).catch(() => {})
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
