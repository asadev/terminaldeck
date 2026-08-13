import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { existsSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import type { IpcMain } from 'electron'
import { loginPath, PROVIDERS } from './providers'
import { currentPlatform, isWindows, withPath, type Platform } from './platform/host'
import { firstLookupPath, lookupSpec } from './platform/lookup'
import type { ProviderId } from '../shared/types'

const run = promisify(execFile)

export type ToolState = 'ready' | 'installed-not-authed' | 'missing' | 'unknown'

export interface ToolStatus {
  id: string
  label: string
  state: ToolState
  /** Version string when we could read one. */
  version?: string
  /** What this unlocks, in the user's terms. */
  purpose: string
  /** What to do about it, when something is wrong. */
  remedy?: string
  /** Where to get it. */
  url?: string
  /** A missing required tool blocks the app; optional ones only disable a panel. */
  required: boolean
}

export interface Prerequisites {
  tools: ToolStatus[]
  /** True when at least one agent CLI is installed AND authenticated. */
  canRunSessions: boolean
  /** True when a CLI exists but none are logged in — a very different message. */
  needsLogin: boolean
}

const AGENT_PURPOSE: Record<string, string> = {
  claude: 'Run Claude Code sessions',
  codex: 'Run OpenAI Codex sessions',
  gemini: 'Run Gemini CLI sessions',
}

const AGENT_URL: Record<string, string> = {
  claude: 'https://docs.anthropic.com/en/docs/claude-code',
  codex: 'https://github.com/openai/codex',
  gemini: 'https://github.com/google-gemini/gemini-cli',
}

/**
 * Where a binary is, or null.
 *
 * This used to spawn the literal `which` with `{ ...process.env, PATH }`, which
 * is wrong twice over on Windows and was the reason the first launch there
 * reported every tool — Git included, with Git plainly installed — as missing:
 *
 *  - `which` is not a Windows command. The spawn fails with ENOENT, the catch
 *    swallows it, and every tool comes back `null`. `platform/lookup.ts` has
 *    carried the `where.exe` spelling for this the whole time; this function
 *    simply never used it.
 *  - `{ ...process.env, PATH }` leaves Windows holding both `Path` (inherited)
 *    and `PATH` (ours), and which one the child reads is undefined. `withPath`
 *    exists precisely to collapse that, and `platform/host.ts` documents why.
 */
async function which(
  bin: string,
  PATH: string,
  platform: Platform = currentPlatform(),
): Promise<string | null> {
  const spec = lookupSpec(platform, bin)
  try {
    const { stdout } = await run(spec.command, spec.args, {
      env: withPath(process.env, PATH, platform),
      timeout: 4000,
    })
    // `where.exe` prints one CRLF-terminated line per match; `which` prints one.
    return firstLookupPath(stdout)
  } catch {
    return null
  }
}

/**
 * Read a version without ever hanging.
 *
 * Several agent CLIs open an interactive session when run with no arguments,
 * and some block on stdin even for `--help`. Everything here therefore runs
 * with a hard timeout and a closed stdin, and a timeout is reported as
 * "installed, version unknown" rather than as a failure.
 */
async function version(
  bin: string,
  PATH: string,
  resolved: string | null = null,
  platform: Platform = currentPlatform(),
): Promise<string | undefined> {
  // On Windows what satisfies the lookup for an npm-installed agent CLI is a
  // `.cmd` shim, and `CreateProcess` will not run a batch file — Node refuses
  // it outright without `shell: true`. `providers.ts` carries the same
  // distinction for the PTY path. Run the resolved shim through the command
  // processor; `resolved` is an absolute path that `where.exe` printed, never
  // anything the user typed.
  const shim = isWindows(platform) && resolved !== null && /\.(cmd|bat)$/i.test(resolved)
  try {
    const { stdout } = await run(shim ? resolved : bin, ['--version'], {
      env: withPath(process.env, PATH, platform),
      timeout: 4000,
      encoding: 'utf8',
      shell: shim,
    })
    return stdout.trim().split('\n')[0]?.slice(0, 60) || undefined
  } catch {
    return undefined
  }
}

/**
 * Whether an agent CLI is authenticated.
 *
 * There is no portable "am I logged in" command, and probing by starting a
 * session would cost the user money. So this is deliberately conservative:
 * we report 'installed-not-authed' ONLY where a cheap, side-effect-free check
 * exists, and otherwise report 'ready' and let the CLI show its own login
 * prompt inside the terminal — which is the real flow anyway.
 */
async function agentAuth(
  id: ProviderId,
  _PATH: string,
  platform: Platform = currentPlatform(),
): Promise<ToolState> {
  if (id === 'claude') {
    // `claude auth status`-style probes differ across versions; the credential
    // file is the stable signal and reading it costs nothing.
    //
    // This was `/bin/sh -c 'test -s …'`, which is a shell spawn to ask a
    // question the filesystem answers directly — and a shell that does not
    // exist on Windows, so every Windows user with Claude Code installed was
    // told they were signed out. `statSync` is the same test (`-s` is "exists
    // and non-empty") on every platform, with nothing to spawn.
    try {
      const credentials = join(homedir(), '.claude', '.credentials.json')
      if (existsSync(credentials) && statSync(credentials).size > 0) return 'ready'
    } catch {
      return 'unknown'
    }
    // Claude can also authenticate via the login keychain — which is a macOS
    // concept. `security` is not on Windows or Linux, and running it there only
    // produced an ENOENT that the catch turned into 'unknown'.
    if (platform === 'darwin') {
      try {
        await run('security', ['find-generic-password', '-s', 'Claude Code-credentials'], {
          timeout: 3000,
        })
        return 'ready'
      } catch {
        return 'installed-not-authed'
      }
    }
    return 'installed-not-authed'
  }
  // For the rest, presence is all we can honestly claim.
  return 'ready'
}

export async function checkPrerequisites(): Promise<Prerequisites> {
  const PATH = await loginPath()
  const tools: ToolStatus[] = []

  for (const id of ['claude', 'codex', 'gemini'] as ProviderId[]) {
    const spec = PROVIDERS[id]
    const found = await which(spec.bin, PATH)
    if (!found) {
      tools.push({
        id,
        label: spec.label,
        state: 'missing',
        purpose: AGENT_PURPOSE[id] ?? spec.label,
        remedy: `Install ${spec.label}, then reopen this window.`,
        url: AGENT_URL[id],
        required: false,
      })
      continue
    }
    const state = await agentAuth(id, PATH)
    tools.push({
      id,
      label: spec.label,
      state,
      version: await version(spec.bin, PATH, found),
      purpose: AGENT_PURPOSE[id] ?? spec.label,
      remedy:
        state === 'installed-not-authed'
          ? `Installed but not signed in. Start a session and run \`${spec.bin}\` — it will walk you through signing in.`
          : undefined,
      url: AGENT_URL[id],
      required: false,
    })
  }

  for (const [bin, label, purpose] of [
    ['git', 'Git', 'Branch and change tracking'],
    ['gh', 'GitHub CLI', 'Pull requests and issues'],
  ] as const) {
    const found = await which(bin, PATH)
    tools.push({
      id: bin,
      label,
      state: found ? 'ready' : 'missing',
      version: found ? await version(bin, PATH, found) : undefined,
      purpose,
      remedy: found ? undefined : `Optional. Without it, the ${label} panel stays empty.`,
      url: bin === 'gh' ? 'https://cli.github.com' : 'https://git-scm.com',
      required: false,
    })
  }

  const agents = tools.filter((t) => ['claude', 'codex', 'gemini'].includes(t.id))
  return {
    tools,
    canRunSessions: agents.some((t) => t.state === 'ready'),
    // Distinguish "you have nothing" from "you have it, just sign in" — those
    // need completely different instructions.
    needsLogin:
      !agents.some((t) => t.state === 'ready') &&
      agents.some((t) => t.state === 'installed-not-authed'),
  }
}

export function registerPrerequisitesIpc(ipcMain: IpcMain): void {
  ipcMain.handle('prereq:check', () => checkPrerequisites())
}
