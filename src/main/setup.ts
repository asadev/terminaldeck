/**
 * One answer to "is my machine ready?".
 *
 * The Setup panel asks two questions that already have owners, and this module
 * is only the join between them:
 *
 *   - which coding tools are installed → `prerequisites.ts`, plus `copilot.ts`
 *     for the one that is not a session provider and so is not in that table
 *   - whether our session hooks are in each CLI's own settings file → `hooks.ts`
 *     and the endpoint they report to, `hook-server.ts`
 *
 * Nothing is re-detected here. What this adds is what a panel needs and a
 * checker does not:
 *
 *  - the literal probe (`copilot not found`) for anything reported missing, so
 *    the user is told what we ran rather than only what we concluded
 *  - each provider's event list *in lifecycle order*, which the hook status
 *    cannot carry: it reports installed/stale/missing as three separate arrays,
 *    and a panel that concatenated them would print SessionEnd before
 *    SessionStart whenever one of them was missing
 *  - one round trip, because three separate calls paint the panel three times
 *
 * The endpoint's token never leaves this module. `hook-server.ts` makes the
 * same point where it refuses to put the token on `hooks:server`: the renderer
 * never needs it, and a secret that reaches page code is one XSS from leaving.
 */

import type { IpcMain } from 'electron'
import { checkPrerequisites, type Prerequisites, type ToolStatus } from './prerequisites'
import { loginPath, PROVIDERS } from './providers'
import {
  defaultContext,
  readAllStatus,
  HOOK_PROVIDERS,
  type HookInstallState,
  type HookProviderStatus,
} from './hooks'
import { currentHookEndpoint } from './hook-server'
import {
  copilotToolStatus,
  detectCopilot,
  COPILOT_ID,
  COPILOT_LABEL,
  type CopilotDetection,
} from './copilot'
import { probeBinary, type ProbeResult } from './tool-probe'

/* ------------------------------------------------------------------ types -- */

/** The tools this panel answers for, in the order it lists them. */
export const SETUP_TOOL_IDS = ['claude', 'codex', 'gemini', COPILOT_ID] as const

export interface SetupProbe {
  command: string
  line: string
}

export interface SetupTool extends ToolStatus {
  /** The literal probe, present only for a tool we could not find. */
  probe: SetupProbe | null
  /** A caveat that is not a remedy — something true even when all is well. */
  note: string | null
}

/** `unsupported` is a tool with no hook configuration this app can write. */
export type SetupHookState = HookInstallState | 'unsupported'

export interface SetupHookBlock {
  id: string
  label: string
  state: SetupHookState
  /** Why there is nothing to install, when there is nothing to install. */
  unsupportedReason: string | null
  /** The provider's own event names, in the order it fires them. */
  events: string[]
  installedEvents: string[]
  staleEvents: string[]
  missingEvents: string[]
  /** The CLI's settings file, or null when the tool has none we write to. */
  file: string | null
  fileExists: boolean
  foreignHooks: number
  foreignOwners: string[]
  message: string
  /** Something the CLI needs beyond the file — Codex's feature flag. */
  requirement: string | null
}

export interface SetupEndpoint {
  running: boolean
  /** Null when it is not listening. The token is never included. */
  port: number | null
}

export interface SetupSnapshot {
  tools: SetupTool[]
  /** True when at least one agent CLI is installed and authenticated. */
  canRunSessions: boolean
  /** A CLI exists but none are signed in — a different sentence entirely. */
  needsLogin: boolean
  hooks: SetupHookBlock[]
  endpoint: SetupEndpoint
  checkedAt: number
}

/**
 * Copilot is detected but not spawned: `providers.ts` has no entry for it, so a
 * session cannot run it in this build. Saying that on the row is the difference
 * between a check that informs and a check that implies something untrue.
 */
const COPILOT_NOTE = 'Detected only — this build does not start Copilot sessions yet.'

const COPILOT_HOOK_REASON =
  'Copilot CLI has no session-hook configuration this app can write, so there is nothing to install.'

/* -------------------------------------------------------------- composing -- */

export interface SetupInput {
  prerequisites: Prerequisites
  copilot: CopilotDetection
  /** Probes by tool id. Only the missing ones are probed. */
  probes: Readonly<Record<string, ProbeResult>>
  hooks: HookProviderStatus[]
  /** The live endpoint, or null. Only its port is ever read. */
  endpoint: { port: number } | null
  now?: number
}

/**
 * Everything the panel renders, assembled from answers already gathered.
 *
 * Pure on purpose: this is where the ordering, the "probe only when missing"
 * rule and the endpoint's token boundary live, and all three are worth a test
 * that does not need a machine with — or without — Copilot on it.
 */
export function composeSetup(input: SetupInput): SetupSnapshot {
  const byId = new Map(input.prerequisites.tools.map((tool) => [tool.id, tool]))
  const copilotStatus = copilotToolStatus(input.copilot)

  const tools: SetupTool[] = SETUP_TOOL_IDS.map((id) => {
    const status: ToolStatus =
      id === COPILOT_ID
        ? copilotStatus
        : (byId.get(id) ?? {
            id,
            label: id,
            state: 'unknown',
            purpose: '',
            required: false,
          })
    const probe = id === COPILOT_ID ? input.copilot.probe : input.probes[id]
    return {
      ...status,
      // A probe next to "Installed" reads as a contradiction — and for Copilot
      // found through `gh` it literally is one, since `which copilot` fails on a
      // machine that has the extension.
      probe:
        status.state === 'missing' && probe ? { command: probe.command, line: probe.line } : null,
      note: id === COPILOT_ID ? COPILOT_NOTE : null,
    }
  })

  const hooks: SetupHookBlock[] = input.hooks.map((status) => ({
    id: status.id,
    label: status.label,
    state: status.state,
    unsupportedReason: null,
    events: HOOK_PROVIDERS[status.id].events,
    installedEvents: status.installedEvents,
    staleEvents: status.staleEvents,
    missingEvents: status.missingEvents,
    file: status.file,
    fileExists: status.fileExists,
    foreignHooks: status.foreignHooks,
    foreignOwners: status.foreignOwners,
    message: status.message,
    requirement: HOOK_PROVIDERS[status.id].requirement,
  }))

  hooks.push({
    id: COPILOT_ID,
    label: COPILOT_LABEL,
    state: 'unsupported',
    unsupportedReason: COPILOT_HOOK_REASON,
    events: [],
    installedEvents: [],
    staleEvents: [],
    missingEvents: [],
    file: null,
    fileExists: false,
    foreignHooks: 0,
    foreignOwners: [],
    message: COPILOT_HOOK_REASON,
    requirement: null,
  })

  return {
    tools,
    // Copilot cannot start a session here, so it does not get a vote on either
    // of these; they stay exactly what `prerequisites.ts` decided.
    canRunSessions: input.prerequisites.canRunSessions,
    needsLogin: input.prerequisites.needsLogin,
    hooks,
    endpoint: { running: input.endpoint !== null, port: input.endpoint?.port ?? null },
    checkedAt: input.now ?? Date.now(),
  }
}

/* ----------------------------------------------------------------- gather -- */

/** The binary each tool is looked for under. Copilot brings its own. */
function binFor(id: string): string | null {
  return id === 'claude' || id === 'codex' || id === 'gemini' ? PROVIDERS[id].bin : null
}

export async function readSetup(): Promise<SetupSnapshot> {
  const PATH = await loginPath()
  const prerequisites = await checkPrerequisites()

  // Copilot and the probes are independent of each other, and each is a spawn
  // that waits on a shell — serialising them would add seconds to a panel that
  // has nothing else to do.
  const missing = prerequisites.tools
    .filter((tool) => tool.state === 'missing' && binFor(tool.id) !== null)
    .map((tool) => tool.id)

  const [copilot, probed] = await Promise.all([
    detectCopilot(PATH),
    Promise.all(
      missing.map(async (id): Promise<[string, ProbeResult]> => {
        const bin = binFor(id)
        // Narrowed above; `binFor` is the same filter this list was built from.
        return [id, await probeBinary(bin ?? id, PATH)]
      }),
    ),
  ])

  return composeSetup({
    prerequisites,
    copilot,
    probes: Object.fromEntries(probed),
    hooks: readAllStatus(defaultContext()),
    endpoint: currentHookEndpoint(),
  })
}

/* -------------------------------------------------------------------- ipc -- */

/**
 * Wire the setup channel. One call from the main process:
 *
 *     import { registerSetupIpc } from './setup'
 *     registerSetupIpc(ipcMain)
 *
 * Channels:
 *  - `setup:status` (invoke) → SetupSnapshot
 *
 * Read-only. Installing and removing hooks stays on `hooks:install` and
 * `hooks:remove`, which already validate the provider id against a closed set —
 * this module deliberately adds no second way to write to a config file.
 */
export function registerSetupIpc(ipcMain: IpcMain): void {
  ipcMain.handle('setup:status', () => readSetup())
}
