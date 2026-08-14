/**
 * GitHub Copilot on the command line.
 *
 * Deliberately not added to `providers.ts`: that table is what the app *spawns*
 * for a session, and nothing here spawns Copilot. This module answers one
 * question for the Setup panel — is Copilot on this machine, and could it talk
 * to GitHub — and says so in the same `ToolStatus` shape `prerequisites.ts`
 * uses so the panel renders one kind of row.
 *
 * Two different things are called "the Copilot CLI" and a machine can have
 * either, so both are looked for:
 *
 *   - the standalone `copilot` binary (npm `@github/copilot`)
 *   - the `gh copilot` extension on the GitHub CLI
 *
 * ## What could not be verified here
 *
 * Neither is installed on the machine this was written on: `which copilot` says
 * `copilot not found` and `gh extension list` is empty. So the sign-in check
 * below is deliberately conservative and is marked where it is a guess. It
 * never claims a sign-in it has not seen, and the states it can produce are the
 * same three every other tool can produce, so a wrong guess shows up as "sign
 * in needed" next to advice that is correct either way — not as a claim that
 * something works when it does not.
 */

import { execFile } from 'node:child_process'
import { readdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { currentPlatform, withPath, type Platform } from './platform/host'
import { firstLookupPath } from './platform/lookup'
import type { ToolState, ToolStatus } from './prerequisites'
import { probeBinary, readVersion, type ProbeResult } from './tool-probe'

const run = promisify(execFile)

export const COPILOT_ID = 'copilot'
export const COPILOT_BIN = 'copilot'
export const COPILOT_LABEL = 'GitHub Copilot'
/** The repo's README carries the install line for both routes. */
export const COPILOT_URL = 'https://github.com/github/copilot-cli'
export const COPILOT_PURPOSE = 'Run GitHub Copilot CLI on this machine'

/** Which install is present. Null when neither is. */
export type CopilotRoute = 'cli' | 'gh-extension'

export interface CopilotDetection {
  state: ToolState
  route: CopilotRoute | null
  version?: string
  /** The literal `which copilot`, kept for the panel whether it found it or not. */
  probe: ProbeResult
  remedy?: string
}

/** Where the standalone CLI keeps its own state. */
const COPILOT_DIR = '.copilot'

/**
 * Files that would mean somebody has signed in with `/login`.
 *
 * UNVERIFIED: the CLI is not installed here, so this is a list of the names it
 * plausibly writes rather than one read off a real install. Any of them counts;
 * none of them is required — `ghAuthenticated` and the token environment
 * variables below are the checks that are known to be right, and this only adds
 * a way to *avoid* a false "sign in needed" for somebody who used `/login`.
 *
 * `ide` is excluded on purpose: it is what the Copilot editor extensions leave
 * behind, it exists on this machine with no CLI installed, and treating it as a
 * sign-in would report an account for a tool that is not there.
 */
const CREDENTIAL_FILES = ['config.json', 'hosts.json', 'credentials.json', 'auth.json', 'apps.json']

/** Environment variables the Copilot CLI documents for non-interactive auth. */
const TOKEN_VARS = ['GH_TOKEN', 'GITHUB_TOKEN', 'COPILOT_GITHUB_TOKEN']

/** How long any Copilot probe may take. `gh auth status` makes a network call. */
const TIMEOUT_MS = 5000

/** Does this `gh extension list` output include the Copilot extension? */
export function hasCopilotExtension(listing: string): boolean {
  // `gh extension list` prints `gh copilot\tgithub/gh-copilot\tv1.1.1`. Matching
  // the repo as well as the command name means a fork installed under another
  // name still counts, and a repo merely mentioned in a description does not.
  return /(^|\s)gh-copilot(\s|$)/m.test(listing) || /github\/gh-copilot/i.test(listing)
}

/** A credential signal from anything we can see without asking the user. */
export function signedIn(input: {
  env: NodeJS.ProcessEnv
  /** Names directly inside `~/.copilot`, or an empty list when it is absent. */
  copilotDir: string[]
  ghAuthenticated: boolean
}): boolean {
  if (TOKEN_VARS.some((name) => (input.env[name] ?? '').trim() !== '')) return true
  if (input.copilotDir.some((name) => CREDENTIAL_FILES.includes(name))) return true
  return input.ghAuthenticated
}

function copilotDirEntries(home: string): string[] {
  try {
    return readdirSync(join(home, COPILOT_DIR))
  } catch {
    // Absent is the normal case, and unreadable tells us nothing either way.
    return []
  }
}

/**
 * Is the GitHub CLI signed in?
 *
 * Exit status only — `gh auth status` prints the account and the token scopes,
 * and none of that belongs in this app's memory, let alone on its way to the
 * renderer.
 */
async function ghAuthenticated(PATH: string, platform: Platform): Promise<boolean> {
  try {
    // `withPath`, not `{ ...process.env, PATH }`: the literal key leaves Windows
    // holding both `Path` and `PATH`. See `platform/host.ts`.
    await run('gh', ['auth', 'status'], {
      env: withPath(process.env, PATH, platform),
      timeout: TIMEOUT_MS,
      // `gh` is a console program, so on Windows this puts a window on screen
      // for as long as the network call takes unless it is told not to.
      windowsHide: true,
    })
    return true
  } catch {
    return false
  }
}

async function ghExtensions(PATH: string, platform: Platform): Promise<string> {
  try {
    const { stdout } = await run('gh', ['extension', 'list'], {
      env: withPath(process.env, PATH, platform),
      timeout: TIMEOUT_MS,
      encoding: 'utf8',
      // As above: the Setup panel runs this on open, and a console window that
      // steals focus mid-typing is worse than the answer is useful.
      windowsHide: true,
    })
    return stdout
  } catch {
    // No gh, or no extensions — both answer the question the same way.
    return ''
  }
}

export interface DetectCopilotOptions {
  home?: string
  env?: NodeJS.ProcessEnv
  platform?: Platform
}

export async function detectCopilot(
  PATH: string,
  options: DetectCopilotOptions = {},
): Promise<CopilotDetection> {
  const home = options.home ?? homedir()
  const env = options.env ?? process.env
  const platform = options.platform ?? currentPlatform()

  const probe = await probeBinary(COPILOT_BIN, PATH, undefined, platform)
  // The extension is only worth a spawn when the standalone binary is absent.
  const route: CopilotRoute | null = probe.found
    ? 'cli'
    : hasCopilotExtension(await ghExtensions(PATH, platform))
      ? 'gh-extension'
      : null

  if (route === null) {
    return {
      state: 'missing',
      route: null,
      probe,
      remedy: 'Install the GitHub Copilot CLI, then check again.',
    }
  }

  const dir = copilotDirEntries(home)
  const authed =
    signedIn({ env, copilotDir: dir, ghAuthenticated: false }) ||
    (await ghAuthenticated(PATH, platform))

  return {
    state: authed ? 'ready' : 'installed-not-authed',
    route,
    // The probe has already asked the platform where this is — on Windows that
    // was `where.exe`, and its answer is the `.cmd` shim that `readVersion` has
    // to route through the command processor to run at all. Handing over the
    // path we already have costs nothing and is the difference between a
    // version and a blank column on Windows.
    version:
      route === 'cli'
        ? await readVersion(COPILOT_BIN, PATH, platform, firstLookupPath(probe.output))
        : undefined,
    probe,
    remedy: authed
      ? undefined
      : route === 'gh-extension'
        ? 'Installed as a `gh` extension, but `gh` is not signed in. Run `gh auth login`.'
        : 'Installed, but no GitHub sign-in was found. Run `copilot` and use /login — it never happens in this window.',
  }
}

/** The detection as the row the panel draws, so Copilot renders like the rest. */
export function copilotToolStatus(detection: CopilotDetection): ToolStatus {
  return {
    id: COPILOT_ID,
    label: COPILOT_LABEL,
    state: detection.state,
    version: detection.version,
    purpose: COPILOT_PURPOSE,
    remedy: detection.remedy,
    url: COPILOT_URL,
    // Nothing in the app stops working without it, which is what `required`
    // means here — the same call `prerequisites.ts` makes for every agent CLI.
    required: false,
  }
}
