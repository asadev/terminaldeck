import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { shell, type IpcMain } from 'electron'
import { currentPlatform, withPath } from './platform/host'
import { loginPath } from './providers'

const run = promisify(execFile)

/**
 * Sign-ins that do not work, said out loud instead of failing quietly.
 *
 * ## The four he hit, and what each one actually is
 *
 * From the recorded review of 2026-08-17, of the in-app browser:
 *
 *   > *"Claude's QR appeared then stopped; the flow pushed him to an external
 *   > browser; the verification link **gets stuck**; Google sign-in refuses.
 *   > Gemini reports 'authentication successful' while the app shows nothing,
 *   > then fails with 'this client is no longer supported to Gemini Code
 *   > Assist… migrate to the Gravity suite.'"*
 *
 * They are three separate faults wearing one complaint, and each was reproduced
 * on this machine on 2026-08-18 rather than reasoned about:
 *
 *  1. **The QR, the external browser and the stuck link are one bug**, and it is
 *     not in this file. Every `window.open` from a guest page was answered
 *     `deny`, so the page's own handle came back `null` and it waited forever
 *     for a message from a window it never got. `browser-popup.ts` is the fix
 *     and carries the measurements.
 *  2. **Google routes an embedded browser down a different flow.** Measured:
 *     the same authorisation URL loaded with Electron's default user agent gets
 *     `flowName=GeneralOAuthLite` and a `/signin/oauth/legacy/consent`
 *     continuation; with the shell's token removed it gets `GeneralOAuthFlow`
 *     and the ordinary consent page. `browser-user-agent.ts` removes the token,
 *     which is honest — the engine really is that Chromium — and this file
 *     handles what happens when it is not enough.
 *  3. **The Gemini message is not about the browser at all.** See
 *     {@link staleAgentCli}: it is a server-side refusal of an out-of-date CLI,
 *     and no browser can fix it.
 *
 * ## Why the handover is deliberate rather than a fallback
 *
 * His instruction, in as many words: if it cannot be fixed from inside, the app
 * must *"hand the sign-in to the system browser deliberately and come back with
 * the token, rather than appearing to try and dying silently."*
 *
 * Coming back with the token is real here, and it is worth saying how, because
 * it is not obvious that it could be. This app already ships `cookie-import.ts`,
 * which reads a Chromium profile's cookie database — decrypting it through the
 * OS keychain — and writes the cookies into the guest session, filtered to named
 * domains. So the round trip is: open the sign-in in the browser the person
 * already uses, let them finish it there where nothing is refused, then bring
 * *that site's* cookies back. The session that returns is the real one; nothing
 * is simulated and no password passes through this app.
 *
 * {@link handoverFor} works out which domains to ask for. Getting that set right
 * is the whole difference between a working handover and an import that brings
 * back the identity provider's cookies but not the site's.
 */

/* ------------------------------------------------------------ diagnosis -- */

export type SignInTroubleKind = 'refused' | 'restricted'

export interface SignInTrouble {
  kind: SignInTroubleKind
  /** One line, in the app's voice, naming what happened. */
  headline: string
  /** Two sentences at most: what it is, and what pressing the button will do. */
  detail: string
  /** The domains a handover should bring back. Never empty. */
  domains: string[]
}

/** Hosts whose sign-in behaviour this module knows something specific about. */
const GOOGLE_HOSTS = /(^|\.)(accounts\.google\.com|accounts\.youtube\.com)$/i

/**
 * What is wrong with this page, when something is.
 *
 * URL-only, and deliberately so. The alternative is reading the page's text and
 * matching English sentences, which breaks the first time somebody's browser is
 * in French and cries wolf the first time a site quotes the phrase in its own
 * help centre. Every signal below is a value Google itself puts in the address:
 *
 *  - `/signin/rejected` — the refusal page, reached after the password step.
 *  - `error=disallowed_useragent` — the OAuth error code for the same refusal.
 *  - `flowName=GeneralOAuthLite`, or a `/legacy/consent` continuation — the
 *    restricted path an embedded browser is put on *before* it is refused.
 *    Measured on this machine; see the table in `browser-user-agent.ts`.
 *
 * The third is a warning rather than a failure on purpose. It is where the
 * sign-in is going to fail, shown while there is still time to move it
 * somewhere it will not — which is worth more than an accurate obituary.
 */
export function diagnoseSignIn(rawUrl: string): SignInTrouble | null {
  let url: URL
  try {
    url = new URL(rawUrl)
  } catch {
    return null
  }
  if (!GOOGLE_HOSTS.test(url.hostname)) return null

  const whole = `${url.pathname}${url.search}`
  const domains = ['google.com', 'accounts.google.com', 'youtube.com']

  if (/\/signin\/rejected/i.test(url.pathname) || /disallowed_useragent/i.test(url.search)) {
    return {
      kind: 'refused',
      headline: 'Google will not accept this sign-in from inside an app',
      detail:
        'Google blocks sign-ins from browsers embedded in other programs, and there is nothing this app can change to be allowed. Finish it in the browser you already use, then bring the signed-in session back here.',
      domains,
    }
  }

  if (/flowName=GeneralOAuthLite/i.test(url.search) || /\/legacy\/consent/i.test(whole)) {
    return {
      kind: 'restricted',
      headline: 'Google has put this sign-in on its restricted path',
      detail:
        'It usually still works, and it is also where Google refuses embedded browsers. If it stops after the password step, finish it in the browser you already use and bring the session back.',
      domains,
    }
  }

  return null
}

export interface Handover {
  /** The address to open outside. Always the page the person was looking at. */
  url: string
  /** Cookie domains to import once they are back. */
  domains: string[]
}

/**
 * The plan for handing one page to the system browser.
 *
 * The page's own host is always included, and it goes *first*, because that is
 * the one the import exists for. A handover that brought back only the identity
 * provider's cookies would leave somebody signed into Google and still signed
 * out of the site they were trying to reach — which looks exactly like the
 * handover not working.
 *
 * The registrable-looking parent is added too (`app.example.com` also asks for
 * `example.com`), because session cookies are routinely set one level up. That
 * is a heuristic and is stated as one: it takes the last two labels, which is
 * right for `example.com` and wrong for `example.co.uk`, where it asks for
 * `co.uk` and simply finds nothing. Asking for a domain that has no cookies
 * costs one empty query; missing the domain that has them costs the feature.
 */
export function handoverFor(rawUrl: string, extra: readonly string[] = []): Handover | null {
  let url: URL
  try {
    url = new URL(rawUrl)
  } catch {
    return null
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return null

  const host = url.hostname
  const labels = host.split('.')
  const parent = labels.length > 2 ? labels.slice(-2).join('.') : ''
  const domains: string[] = []
  for (const domain of [host, parent, ...extra]) {
    if (domain !== '' && !domains.includes(domain)) domains.push(domain)
  }
  return { url: url.toString(), domains }
}

/* ------------------------------------------------- the agent CLI finding -- */

/**
 * The Gemini message, run down to its cause.
 *
 * *"This client is no longer supported to Gemini Code Assist… migrate to the
 * Gravity suite"* is a **server-side refusal of an out-of-date client**, and it
 * is why the browser could say "authentication successful" while the session
 * showed nothing: the OAuth round trip really did succeed, and the first API
 * call afterwards was turned away. No browser change can fix that, and no amount
 * of retrying will either — which is what makes it worth naming rather than
 * leaving somebody to loop.
 *
 * Checked on this machine on 2026-08-18:
 *
 *   - installed: `gemini --version` → **0.32.1**, from Homebrew.
 *   - Homebrew's own formula: *"gemini-cli: 0.32.1 → stable 0.46.0. Deprecated
 *     because it is not supported upstream! It will be disabled on 2026-12-18.
 *     Replacement: brew install --cask antigravity-cli"*.
 *   - npm `@google/gemini-cli`: latest **0.55.1**.
 *
 * So the installed client is twenty-three minor versions behind a moving
 * server, on a packaging route its own maintainers have marked for removal, and
 * "Gravity" in the error is Antigravity — the suite Google moved the tool into.
 * The fix is an upgrade, and it is a fix a person can perform, which is the
 * whole test of whether this is worth showing at all.
 *
 * The floor is deliberately the version Homebrew *offers*, not the newest on
 * npm. Telling somebody on Homebrew to install a version their package manager
 * does not have is a dead end, and a check that fires on a machine that is as
 * current as it can be is a check people learn to ignore.
 */
export const GEMINI_SUPPORTED_FROM = '0.46.0'

export interface AgentCliVersion {
  /** The command asked, so a person can run the same thing themselves. */
  command: string
  /** What it answered, or null when it is not installed or would not say. */
  version: string | null
  /** True only when a version was read *and* it is below the floor. */
  stale: boolean
  /** What to do about it. Empty when there is nothing to do. */
  advice: string
}

/**
 * Compare two dotted versions numerically.
 *
 * String comparison gets this wrong in the direction that matters: `'0.9.0' >
 * '0.46.0'` is true alphabetically and false in fact, so a lexical check would
 * clear every version between 0.5 and 0.9 while failing 0.46 itself.
 */
export function isBelow(candidate: string, floor: string): boolean {
  const parts = (value: string): number[] =>
    value
      .replace(/^v/, '')
      .split(/[.-]/)
      .map((piece) => Number.parseInt(piece, 10))
      .map((n) => (Number.isFinite(n) ? n : 0))
  const a = parts(candidate)
  const b = parts(floor)
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const left = a[i] ?? 0
    const right = b[i] ?? 0
    if (left !== right) return left < right
  }
  return false
}

/** The first dotted number in whatever a CLI printed for `--version`. */
export function parseVersion(output: string): string | null {
  const match = /(\d+\.\d+\.\d+)/.exec(output)
  return match ? match[1] : null
}

/**
 * Ask one CLI what version it is.
 *
 * Never throws and never reports `stale` from a check that failed: a binary that
 * is not installed, or that answered something unparseable, is `version: null`,
 * which sends a person somewhere completely different from "yours is too old".
 * The same discipline `gemini-signin.ts` applies to its keychain probe.
 */
export async function readCliVersion(
  command: string,
  floor: string,
  advice: string,
  /*
   * The login shell's PATH, not this process's — and that is not a detail.
   *
   * A GUI app launched from Finder or the Dock inherits `/usr/bin:/bin:
   * /usr/sbin:/sbin` and nothing else, so every agent CLI in `/opt/homebrew/bin`
   * or a Node version manager is simply not there. `run(command, …)` would throw
   * ENOENT, this function would answer `version: null, stale: false` — which is
   * correct for "not installed" and catastrophic here, because the whole point
   * of the check is to *warn*, and a silent no-warning is indistinguishable from
   * a clean bill of health.
   *
   * Found by looking rather than by reasoning: the Accounts pane showed the
   * installed version as current (that check goes through `loginPath`) while
   * this one, two inches above it, read a different binary. In a packaged build
   * started the ordinary way it would have read no binary at all, and the row
   * this feeds would never have appeared for anybody. `CLAUDE.md` states the
   * rule outright — "a GUI app cannot see `claude` on PATH".
   *
   * `withPath` rather than `{ ...process.env, PATH }`: on Windows the literal
   * key leaves the child holding both `Path` and `PATH`, and which one it reads
   * is undefined. See `platform/host.ts`.
   */
  exec: (cmd: string, args: string[]) => Promise<{ stdout: string }> = async (cmd, args) =>
    run(cmd, args, {
      timeout: 5000,
      windowsHide: true,
      env: withPath(process.env, await loginPath(), currentPlatform()),
    }),
): Promise<AgentCliVersion> {
  try {
    const { stdout } = await exec(command, ['--version'])
    const version = parseVersion(stdout)
    if (version === null) return { command, version: null, stale: false, advice: '' }
    const stale = isBelow(version, floor)
    return { command, version, stale, advice: stale ? advice : '' }
  } catch {
    return { command, version: null, stale: false, advice: '' }
  }
}

/**
 * Every agent CLI whose sign-in is known to fail on an old build.
 *
 * A list of one, and it stays a list. The next CLI to start refusing old clients
 * needs a row here and nothing else, and a list of one is what a second entry
 * gets appended to rather than the shape somebody has to invent under pressure.
 */
export async function staleAgentCli(): Promise<AgentCliVersion[]> {
  const gemini = await readCliVersion(
    'gemini',
    GEMINI_SUPPORTED_FROM,
    'Google turns away builds this old after you sign in — the sign-in succeeds and the first request fails. Upgrade it: `brew upgrade gemini-cli`, or `npm install -g @google/gemini-cli@latest`.',
  )
  return [gemini].filter((entry) => entry.stale)
}

/* -------------------------------------------------------------- register -- */

/**
 * Wire the sign-in helpers. Call once from `registerIpc()`:
 *
 *     import { registerBrowserSignInIpc } from './browser-signin'
 *     registerBrowserSignInIpc(ipcMain)
 *
 * Channels:
 * - `browser-signin:diagnose` (invoke, url)  → {@link SignInTrouble} | null
 * - `browser-signin:handover` (invoke, url)  → {@link Handover} | null, and opens the browser
 * - `browser-signin:agents`   (invoke)       → {@link AgentCliVersion}[], only the stale ones
 */
export function registerBrowserSignInIpc(ipcMain: IpcMain): void {
  ipcMain.handle('browser-signin:diagnose', (_event, url: unknown) =>
    typeof url === 'string' ? diagnoseSignIn(url) : null,
  )

  ipcMain.handle('browser-signin:handover', async (_event, url: unknown) => {
    if (typeof url !== 'string') return null
    const trouble = diagnoseSignIn(url)
    const plan = handoverFor(url, trouble ? trouble.domains : [])
    if (!plan) return null
    // `shell.openExternal` and not `link-open.ts`'s guard, because the scheme
    // has already been checked above: `handoverFor` returns null for anything
    // that is not http or https, which is the same gate for a narrower purpose.
    await shell.openExternal(plan.url)
    return plan
  })

  ipcMain.handle('browser-signin:agents', () => staleAgentCli())
}
