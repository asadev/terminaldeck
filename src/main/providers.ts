import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import type { ProviderId } from '../shared/types'

const run = promisify(execFile)

export interface ProviderSpec {
  id: ProviderId
  label: string
  /** Binary to look for on PATH. */
  bin: string
  /** Args used when starting a fresh session. */
  args: string[]
  /** Args used when continuing the most recent session in a folder. */
  resumeArgs: string[]
}

export const PROVIDERS: Record<ProviderId, ProviderSpec> = {
  claude: { id: 'claude', label: 'Claude Code', bin: 'claude', args: [], resumeArgs: ['--continue'] },
  codex: { id: 'codex', label: 'Codex CLI', bin: 'codex', args: [], resumeArgs: ['resume', '--last'] },
  gemini: { id: 'gemini', label: 'Gemini CLI', bin: 'gemini', args: [], resumeArgs: [] },
  shell: { id: 'shell', label: 'Shell', bin: process.env.SHELL || '/bin/zsh', args: ['-l'], resumeArgs: [] },
}

/**
 * GUI apps on macOS inherit a minimal PATH, so a CLI installed via nvm,
 * Homebrew or ~/.local/bin is frequently invisible. Ask the user's login
 * shell for its real PATH once and reuse it for every spawn.
 */
let cachedPath: string | null = null

export async function loginPath(): Promise<string> {
  if (cachedPath) return cachedPath
  const shell = process.env.SHELL || '/bin/zsh'
  try {
    const { stdout } = await run(shell, ['-lic', 'echo -n "$PATH"'], { timeout: 5000 })
    cachedPath = stdout.trim() || process.env.PATH || ''
  } catch {
    cachedPath = process.env.PATH || ''
  }
  return cachedPath
}

/** Which provider CLIs are actually installed, so the UI can grey out the rest. */
export async function detectProviders(): Promise<Record<ProviderId, boolean>> {
  const PATH = await loginPath()
  const found = {} as Record<ProviderId, boolean>
  await Promise.all(
    (Object.keys(PROVIDERS) as ProviderId[]).map(async (id) => {
      if (id === 'shell') {
        found[id] = true
        return
      }
      try {
        await run('which', [PROVIDERS[id].bin], { env: { ...process.env, PATH } })
        found[id] = true
      } catch {
        found[id] = false
      }
    }),
  )
  return found
}
