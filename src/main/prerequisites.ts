import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import type { IpcMain } from 'electron'
import { loginPath, PROVIDERS } from './providers'
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

async function which(bin: string, PATH: string): Promise<string | null> {
  try {
    const { stdout } = await run('which', [bin], { env: { ...process.env, PATH }, timeout: 4000 })
    return stdout.trim() || null
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
async function version(bin: string, PATH: string): Promise<string | undefined> {
  try {
    const { stdout } = await run(bin, ['--version'], {
      env: { ...process.env, PATH },
      timeout: 4000,
      encoding: 'utf8',
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
async function agentAuth(id: ProviderId, PATH: string): Promise<ToolState> {
  if (id === 'claude') {
    // `claude auth status`-style probes differ across versions; the credential
    // file is the stable signal and reading it costs nothing.
    try {
      const { stdout } = await run(
        '/bin/sh',
        ['-c', 'test -s "$HOME/.claude/.credentials.json" && echo yes || echo no'],
        { env: { ...process.env, PATH }, timeout: 3000 },
      )
      if (stdout.trim() === 'yes') return 'ready'
      // Claude can also authenticate via the login keychain.
      const { stdout: kc } = await run(
        '/bin/sh',
        ['-c', 'security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 && echo yes || echo no'],
        { timeout: 3000 },
      )
      return kc.trim() === 'yes' ? 'ready' : 'installed-not-authed'
    } catch {
      return 'unknown'
    }
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
      version: await version(spec.bin, PATH),
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
      version: found ? await version(bin, PATH) : undefined,
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
